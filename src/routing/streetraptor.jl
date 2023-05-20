# StreetRaptor combines RAPTOR with a street search from a geographic origin to a geographic destination

# New StreetRaptor result format, for range-RAPTOR:
# access_geom_for_stop: Geoemtry to access a stop
# access_

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

function street_raptor(
    net::TransitNetwork,
    access_router::OSRMInstance,
    egress_router::OSRMInstance,
    origin::LatLon{<:Real},
    destinations::AbstractVector{<:LatLon{<:Real}},
    departure_date_time::DateTime,
    time_window_length_seconds=0;
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
    @debug "begin transit routing"

    raptor_res = range_raptor(accessible_stops, net, Date(departure_date_time), time_window_length_seconds, 60;
        walk_speed_meters_per_second=walk_speed_meters_per_second, max_rides=max_rides)

    @debug "transit routing complete. adding egress times."
    times_at_destinations::Matrix{Int32} = fill(MAX_TIME, (length(raptor_res), length(destinations)))
    egress_stops::Matrix{Int32} = fill(INT_MISSING, (length(raptor_res), length(destinations)))
    egress_geometry = Dict{NTuple{2, Int64}, AccessEgress}()

    # find stops near the destination
    # NB could use spatial index for this if needed
    for destidx in eachindex(destinations)
        stops_near_destination = bbox_filter(destinations[destidx], stop_coords, max_egress_distance_meters)

        for stop in stops_near_destination
            r = route(egress_router, stop_coords[stop], destinations[destidx])
            if !isempty(r)
                egress_geometry[(destidx, stop)] = AccessEgress(r[1].geometry, r[1].distance_meters, r[1].duration_seconds, r[1].weight)
                for depidx in eachindex(raptor_res)
                    best_time_at_stop = raptor_res[depidx].non_transfer_times_at_stops_each_round[end, stop]
                    if best_time_at_stop != MAX_TIME
                        time_at_dest_this_stop = best_time_at_stop + round(Int32, r[1].duration_seconds)
                        if time_at_dest_this_stop < times_at_destinations[depidx, destidx]
                            # we found a new optimal way to get to this stop
                            times_at_destinations[depidx, destidx] = time_at_dest_this_stop
                            egress_stops[depidx, destidx] = stop
                        end
                    end
                end
            end
        end
    end

    return StreetRaptorResult(times_at_destinations, egress_stops, raptor_res, access_geoms, egress_geometry, departure_date_time)
end