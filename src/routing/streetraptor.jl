# StreetRaptor combines RAPTOR with a street search from a geographic origin to a geographic destination

"""
Contains information about an access or egress leg.
"""
struct AccessEgress
    geometry::Vector{LatLon{Float64}}
    distance_meters::Float64
    duration_seconds::Float64
    weight::Float64
end


"""
If time_window_length_seconds is negative, will perform a range raptor search _ending_ at the requested departure time, and starting up to time_window_length_seconds
earlier, or at the first time path to all destinations is possible (whichever is later).
"""
function street_raptor(
    net::TransitNetwork,
    access_router::OSRMInstance,
    egress_router::OSRMInstance,
    origin::LatLon{<:Real},
    destinations::AbstractVector{<:LatLon{<:Real}},
    departure_date_time::DateTime,
    time_window_length_seconds::Union{Function, Int64}=0;
    max_access_distance_meters=1000.0,
    max_egress_distance_meters=1000.0,
    max_rides=4,
    stop_to_destination_distances=nothing,
    stop_to_destination_durations=nothing
    )

    @debug "performing access search"

    # find stops near origin
    stop_coords = map(s -> LatLon{Float64}(s.stop_lat, s.stop_lon), net.stops)
    stops_near_origin = bbox_filter(origin, stop_coords, max_access_distance_meters)

    access = distance_matrix(access_router, [origin], stop_coords[stops_near_origin])

    departure_time = time_to_seconds_since_midnight(departure_date_time)

    access_geoms = Dict{Int64, AccessEgress}()

    accessible_stops = Vector{StopAndTime}()
    for stop_near_origin_idx in eachindex(stops_near_origin)
        stop_idx = stops_near_origin[stop_near_origin_idx]
        # this is the time the stop is reached
        time = departure_time + access.durations[1, stop_near_origin_idx]
        dist = access.distances[1, stop_near_origin_idx]

        if dist <= max_access_distance_meters
            push!(accessible_stops, StopAndTime(stop_idx, round(time), round(dist)))
            stop = net.stops[stop_idx]
            r = route(access_router, origin, LatLon(stop.stop_lat, stop.stop_lon))
            access_geoms[stop_idx] = AccessEgress(r[1].geometry, r[1].distance_meters, r[1].duration_seconds, r[1].weight)
        end
    end

    @debug "$(length(accessible_stops)) stops found near origin"

    @debug "finding stops near destination"
    critical_times_at_stops = fill(typemin(Int32), (length(net.stops), length(destinations)))
    egress_geometry = Dict{NTuple{2, Int64}, AccessEgress}()

    # once there is at least one stop in each column that is less than the specified value,
    # we are done
    # TODO different arrival times per-destination
    for destidx in eachindex(destinations)
        stops_near_destination = bbox_filter(destinations[destidx], stop_coords, max_egress_distance_meters)

        for stop in stops_near_destination
            r = route(egress_router, stop_coords[stop], destinations[destidx])
            if !isempty(r) && r[1].distance_meters < max_egress_distance_meters
                egress_geometry[(destidx, stop)] = AccessEgress(r[1].geometry, r[1].distance_meters, r[1].duration_seconds, r[1].weight)
                critical_times_at_stops[stop, destidx] = departure_time - round(Int32, r[1].duration_seconds)
            end
        end
    end

    @debug "begin transit routing"

    paths = map(_ -> Vector{TransitRouter.Leg}[], destinations)
    times_at_destinations = fill(MAX_TIME, length(destinations))
    transfers = fill(typemax(Int64), length(destinations))

    initial_offset = max(convert(Int32, time_window_length_seconds), zero(Int32))
    offset_step = convert(Int32, -SECONDS_PER_MINUTE)

    date = Date(departure_date_time)
    raptor(net, date) do result::Union{Nothing, RaptorResult}, offset::Union{Nothing, Int32}
        if isnothing(result)
            offset = initial_offset
        else
            # figure out the time at destinations
            # for reverse search: if we found a path to all destinations within the required time, end the search.
            found_path_to_all = true
            for destidx in eachindex(destinations)
                time_at_dest_this_minute = MAX_TIME
                egress_stop = -1
                for stop in eachindex(net.stops)
                    if result.non_transfer_times_at_stops_each_round[end, stop] < MAX_TIME && haskey(egress_geometry, (destidx, stop))
                        time_at_dest_this_stop = result.non_transfer_times_at_stops_each_round[end, stop] + round(Int32, egress_geometry[(destidx, stop)].duration_seconds)
                        if time_at_dest_this_stop < time_at_dest_this_minute
                            time_at_dest_this_minute = time_at_dest_this_stop
                            egress_stop = stop
                        end 
                    end
                end

                if time_window_length_seconds < 0 && time_at_dest_this_minute > departure_time
                    # in a reverse search, see if we've found paths to everywhere within the constraint
                    found_path_to_all = false
                end

                if egress_stop > -1
                    ntransfers = get_last_round(result, egress_stop)
                    if time_at_dest_this_minute < times_at_destinations[destidx] || ntransfers < transfers[destidx]
                        path, boardstop = trace_path(net, result, egress_stop)
                        # add access and egress legs
                        egrgeom = egress_geometry[(destidx, egress_stop)]
                        push!(path, Leg(
                            seconds_since_midnight_to_datetime(date, result.non_transfer_times_at_stops_each_round[end, egress_stop]),
                            seconds_since_midnight_to_datetime(date, time_at_dest_this_minute),
                            net.stops[egress_stop],
                            missing,
                            egress,
                            missing,
                            egrgeom.distance_meters,
                            egrgeom.geometry
                        ))

                        accgeom = access_geoms[boardstop]
                        pushfirst!(path, Leg(
                            path[begin].start_time - Second(BOARD_SLACK_SECONDS) - Second(round(Int64, accgeom.duration_seconds)),
                            path[begin].start_time - Second(BOARD_SLACK_SECONDS),
                            missing,
                            path[begin].origin_stop,
                            TransitRouter.access,
                            missing,
                            accgeom.distance_meters,
                            accgeom.geometry
                        ))

                        pushfirst!(paths[destidx], path)
                        times_at_destinations[destidx] = time_at_dest_this_minute
                        transfers[destidx] = ntransfers
                    end
                end
            end

            if time_window_length_seconds < 0 && found_path_to_all
                # we've found enough paths in a reverse search
                return nothing
            end

            offset += offset_step
        end

        # works in both directions - if the offset has moved further than the time window length in either direction
        if abs(initial_offset - offset) > abs(time_window_length_seconds)
            return nothing
        else
            return map(s -> StopAndTime(s.stop, s.time + offset, s.walk_distance_meters), accessible_stops), offset
        end
    end

    return paths
end