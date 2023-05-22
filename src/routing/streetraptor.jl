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
Contains the result of a StreetRaptor search, including enough information to construct paths.
- `times_at_destinations_each_departure_time`: matrix indexed by [departure time, destination] containing the earliest arrival at
    each destination for each departure_time
- `egress_stop_each_departure_time`: matrix indexed by [departure time, destination] containing the stop ID of the egress stop
    for the destination
- `raptor_results` - Vector of RaptorResults for each departure minute
- `access_geometries` - Dict of AccessEgree entries for access, indexed by stop
- `egress_geometries` - Dict indexed by (destination ID, stop ID) of geometry to access that destination from the given stop

"""
struct StreetRaptorResult
    times_at_destinations_each_departure_time::Matrix{Int32}
    egress_stop_each_departure_time::Matrix{Int64}
    raptor_results::Vector{RaptorResult}
    access_geometries::Dict{Int64, AccessEgress}
    egress_geometries::Dict{NTuple{2, Int64}, AccessEgress}
    departure_date_time::DateTime
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
    )::StreetRaptorResult

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

    # once there is at least one stop in each column that is less than the specified value,
    # we are done
    # TODO different arrival times per-destination
    critical_times_at_stops = fill(typemin(Int32), (length(net.stops), length(destinations)))
    egress_geometry = Dict{NTuple{2, Int64}, AccessEgress}()

    for destidx in eachindex(destinations)
        stops_near_destination = bbox_filter(destinations[destidx], stop_coords, max_egress_distance_meters)

        for stop in stops_near_destination
            r = route(egress_router, stop_coords[stop], destinations[destidx])
            if !isempty(r)
                egress_geometry[(destidx, stop)] = AccessEgress(r[1].geometry, r[1].distance_meters, r[1].duration_seconds, r[1].weight)
                critical_times_at_stops[stop, destidx] = departure_time - round(Int32, r[1].duration_seconds)
            end
        end
    end

    @debug "begin transit routing"


    raptor_res = if time_window_length_seconds ≥ 0
        range_raptor(accessible_stops, net, Date(departure_date_time), time_window_length_seconds, 60;
            max_rides=max_rides)
    else
        range_raptor(accessible_stops, net, Date(departure_date_time);
            max_rides=max_rides) do result, offset

            if offset < time_window_length_seconds
                return true  # we've run out of time
            end
                
            for destidx in 1:length(destinations)
                if all(result.non_transfer_times_at_stops_each_round[end, :] .> critical_times_at_stops[:, destidx])
                    # none of the stops have been reached soon enough, routing needs to continue to an
                    # earlier minute.
                    # don't stop (me now, cause I'm havin a good time, havin a good time)
                    return false
                end
            end

            # if we got here, we've found a route to every destination - stop routing
            # stop! (in the name of love)
            return true
        end
    end     


    @debug "transit routing complete. adding egress times."
    times_at_destinations::Matrix{Int32} = fill(MAX_TIME, (length(raptor_res), length(destinations)))
    egress_stops::Matrix{Int32} = fill(INT_MISSING, (length(raptor_res), length(destinations)))

    for depidx in eachindex(raptor_res)
        for destidx in eachindex(destinations)
            # egress stop is the one that gives us the best arrival time, i.e. the largest delta between
            # the critical time and the actual time at the stop. This holds even for forward searches; the
            # critical time is the time you would have to reach each stop to get to the destination at the
            # departure time. The reached time will always be greater than the critical time in a forward search,
            # but the largest (closest to zero) delta is still the one that gives the best arrival time.
            critical_time_Δ =
                ifelse.(
                     # only use ones that were critical stops to avoid overflow when subtracting from typemin, and only use stops that were reached
                    (critical_times_at_stops[:, destidx] .> typemin(Int32)) .&& (raptor_res[depidx].non_transfer_times_at_stops_each_round[end, :] .< MAX_TIME),
                    critical_times_at_stops[:, destidx] .- raptor_res[depidx].non_transfer_times_at_stops_each_round[end, :],
                    typemin(Int32)
                )

            if all(critical_time_Δ .== typemin(Int32))
                # no stops were reached, or are available
                continue
            end

            egress_stop_this_dest = argmax(critical_time_Δ)

            time_at_stop = raptor_res[depidx].non_transfer_times_at_stops_each_round[end, egress_stop_this_dest]
            @assert time_at_stop < MAX_TIME
            time_at_dest = time_at_stop + round(Int32, egress_geometry[(destidx, egress_stop_this_dest)].duration_seconds)
            
            egress_stops[depidx, destidx] = egress_stop_this_dest
            times_at_destinations[depidx, destidx] = time_at_dest
        end
    end

    return StreetRaptorResult(times_at_destinations, egress_stops, raptor_res, access_geoms, egress_geometry, departure_date_time)
end