# StreetRaptor combines RAPTOR with a street search from a geographic origin to a geographic destination

struct StreetRaptorResult
    times_at_destinations::Vector{Int32}
    egress_stop_for_destination::Vector{Int64}
    access_geom_for_destination::Vector{Union{Nothing, Vector{LatLon{Float64}}}}
    access_dist_for_destination::Vector{Float64}
    egress_geom_for_destination::Vector{Union{Nothing, Vector{LatLon{Float64}}}}
    egress_dist_for_destination::Vector{Float64}
    raptor_result::RaptorResult
    departure_date_time::DateTime
end

function street_raptor(
    net::TransitNetwork,
    access_router::OSRMInstance,
    egress_router::OSRMInstance,
    origin::LatLon{<:Real},
    destinations::AbstractVector{<:LatLon{<:Real}},
    departure_date_time::DateTime;
    max_access_distance_meters=1000.0,
    max_egress_distance_meters=1000.0,
    max_rides=4,
    walk_speed_meters_per_second=DEFAULT_WALK_SPEED_METERS_PER_SECOND,
    stop_to_destination_distances=nothing,
    stop_to_destination_durations=nothing
    )::StreetRaptorResult

    @debug "performing access search"

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

    @debug "$(length(accessible_stops)) stops found near origin"
    @debug "begin transit routing"

    raptor_res = raptor(net, accessible_stops, Date(departure_date_time);
        walk_speed_meters_per_second=walk_speed_meters_per_second, max_rides=max_rides)

    @debug "transit routing complete. adding egress times."
    times_at_destinations::Vector{Int32} = fill(MAX_TIME, length(destinations))
    egress_stops::Vector{Int64} = fill(INT_MISSING, length(destinations))
    egress_geoms::Vector{Union{Nothing, Vector{LatLon{Float64}}}} = fill(nothing, length(destinations))
    egress_dists::Vector{Float64} = fill(NaN, length(destinations))

    for stopidx in eachindex(net.stops)
        time_at_stop = raptor_res.non_transfer_times_at_stops_each_round[end, stopidx]
        if time_at_stop < MAX_TIME
            for destidx in eachindex(destinations)
                if !isnothing(stop_to_destination_distances) && !isnothing(stop_to_destination_durations)
                    if stop_to_destination_distances[stopidx, destidx] > 0 && stop_to_destination_distances[stopidx, destidx] < max_egress_distance_meters
                        time_at_dest = time_at_stop + round(stop_to_destination_durations[stopidx, destidx])
                        if time_at_dest < times_at_destinations[destidx]
                            times_at_destinations[destidx] = round(time_at_dest)
                            egress_stops[destidx] = stopidx
                            egress_dists[destidx] = stop_to_destination_distances[stopidx, destidx]
                        end
                    end
                else
                    # check if it's nearby
                    crow_flies_distance_to_dest = euclidean_distance(stop_coords[stopidx], destinations[destidx])
                    if crow_flies_distance_to_dest <= max_egress_distance_meters && time_at_stop < times_at_destinations[destidx]
                        # it's nearby, get network distance. TODO if multiple destinations are close by, could route to all at once
                        # other condition is optimization - if there's another way to the destination faster than the route to this
                        # stop, no way it could be optimal way to get to that destination since egress time is nonnegative
                        routes_to_dest = route(egress_router, stop_coords[stopidx], destinations[destidx])
                        # need to check this again, horse-flies distance may be longer than limit even if
                        if !isempty(routes_to_dest)
                            route_to_dest = routes_to_dest[1]
                            if route_to_dest.distance_meters < max_egress_distance_meters
                                time_at_dest = time_at_stop + route_to_dest.duration_seconds
                                if time_at_dest < times_at_destinations[destidx]
                                    times_at_destinations[destidx] = round(time_at_dest)
                                    egress_stops[destidx] = stopidx
                                    egress_geoms[destidx] = route_to_dest.geometry
                                    egress_dists[destidx] = route_to_dest.distance_meters
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    access_geoms, access_dists = find_access_geoms(net, access_router, egress_stops, raptor_res, origin)

    return StreetRaptorResult(times_at_destinations, egress_stops, access_geoms, access_dists, egress_geoms, egress_dists, raptor_res, departure_date_time)
end

# Find the geometries to access transit based on the access stops that were actually used for
# each destination
function find_access_geoms(net, osrm, egress_stops, raptor_res, origin)
    access_geom_dict = Dict{Int64, Vector{LatLon{Float64}}}()
    access_dist_dict = Dict{Int64, Float64}()

    access_geoms = Union{Nothing, Vector{LatLon{Float64}}}[]
    access_dists = Float64[]

    for egress_stop in egress_stops
        # find the access stop for this egress stop
        if egress_stop == INT_MISSING
            push!(access_geoms, nothing)
            push!(access_dists, NaN)
            continue
        end

        access_stop = egress_stop
        for idx in size(raptor_res.prev_stop, 1):-1:1
            prev = raptor_res.prev_stop[idx, access_stop]
            if prev == INT_MISSING
                continue
            else
                access_stop = prev
            end

            # handle a transfer
            if idx > 1 && raptor_res.transfer_prev_stop[idx - 1, access_stop]
                access_stop = raptor_res.transfer_prev_stop[idx - 1, access_stop]
            end
        end

        if haskey(access_geom_dict, access_stop)
            push!(access_geoms, access_geom_dict[access_stop])
            push!(access_dists, access_dist_dict[access_stop])
        else
            # compute the geometry
            access_stop_location = LatLon(net.stops[access_stop].stop_lat, net.stops[access_stop].stop_lon)
            routes = route(osrm, origin, access_stop_location)
            !isempty(routes) || error("No route found to stop $access_stop in access geometry search, but it was found in access search!")
            r = first(routes)
            access_geom_dict[access_stop] = r.geometry
            access_dist_dict[access_stop] = r.distance_meters
            push!(access_geoms, r.geometry)
            push!(access_dists, r.distance_meters)
        end
    end

    return access_geoms, access_dists
end