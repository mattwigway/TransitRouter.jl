# StreetRaptor combines RAPTOR with a street search from a geographic origin to a geographic destination

struct StreetRaptorResult
    times_at_destinations::Vector{Int32}
    egress_stop_for_destination::Vector{Int64}
    raptor_result::RaptorResult
end

function street_raptor(
    net::TransitNetwork,
    access_router::OSRMInstance,
    origin::LatLon{<:Real},
    destinations::AbstractVector{<:LatLon{<:Real}},
    departure_date_time::DateTime;
    max_access_distance_meters=1000.0,
    max_rides=4,
    walk_speed_meters_per_second=DEFAULT_WALK_SPEED_METERS_PER_SECOND
    )::StreetRaptorResult
    @info "performing access search"

    # find stops near origin
    stop_coords = map(s -> LatLon{Float64}(s.stop_lat, s.stop_lon), net.stops)
    stops_near_origin = bbox_filter(origin, stop_coords, max_access_distance_meters)

    access = distance_matrix(access_router, [origin], stop_coords[stops_near_origin])

    departure_time = time_to_seconds_since_midnight(departure_date_time)

    accessible_stops = Vector{StopAndTime}()
    for stop_near_origin_idx in eachindex(stops_near_origin)
        stop_idx = stops_near_origin[stop_near_origin_idx]
        # this is the time the stop is reached
        time = departure_time + access.durations[1, stop_near_origin_idx]
        dist = access.distances[1, stop_near_origin_idx]

        if dist <= max_access_distance_meters
            push!(accessible_stops, StopAndTime(stop_idx, round(time)))
        end
    end

    @info "$(length(accessible_stops)) stops found near origin"
    @info "begin transit routing"

    raptor_res = raptor(net, accessible_stops, Date(departure_date_time);
        walk_speed_meters_per_second=walk_speed_meters_per_second, max_rides=max_rides)

    @info "transit routing complete. adding egress times."
    times_at_destinations::Vector{Int32} = fill(MAX_TIME, length(destinations))
    egress_stops::Vector{Int64} = fill(INT_MISSING, length(destinations))

    for stopidx in eachindex(net.stops)
        time_at_stop = raptor_res.times_at_stops_each_round[end, stopidx]
        if time_at_stop < MAX_TIME
            for destidx in eachindex(destinations)
                # check if it's nearby
                crow_flies_distance_to_dest = euclidean_distance(stop_coords[stopidx], destinations[destidx])
                if crow_flies_distance_to_dest <= max_access_distance_meters && time_at_stop < times_at_destinations[destidx]
                    # it's nearby, get network distance. TODO if multiple destinations are close by, could route to all at once
                    # other condition is optimization - if there's another way to the destination faster than the route to this
                    # stop, no way it could be optimal way to get to that destination since egress time is nonnegative
                    routes_to_dest = route(access_router, stop_coords[stopidx], destinations[destidx])
                    # todo handle not found
                    # need to check this again, horse-flies distance may be longer than limit even if
                    if !isempty(routes_to_dest)
                        route_to_dest = routes_to_dest[1]
                        if route_to_dest.distance_meters < max_access_distance_meters
                            time_at_dest = time_at_stop + route_to_dest.duration_seconds / walk_speed_meters_per_second
                            if time_at_dest < times_at_destinations[destidx]
                                times_at_destinations[destidx] = round(time_at_dest)
                                egress_stops[destidx] = stopidx
                            end
                        end
                    end
                end
            end
        end
    end

    return StreetRaptorResult(times_at_destinations, egress_stops, raptor_res)
end