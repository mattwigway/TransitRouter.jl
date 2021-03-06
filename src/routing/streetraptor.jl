# StreetRaptor combines RAPTOR with a street search from a geographic origin to a geographic destination

using .OSRM
using ProgressBars
using Dates

struct EgressTime
    dest_idx::Int64
    time_seconds::Int32
end

struct EgressTimes
    destinations::Vector{Coordinate}
    stop_dest_time::Vector{Vector{EgressTime}}
end

struct StreetRaptorRequest
    origin::Coordinate
    departure_time::Int32
    date::Date
    max_access_distance_meters::Float64
    walk_speed_meters_per_second::Float64
    max_rides::Int64
end

struct StreetRaptorResult
    times_at_destinations::Vector{Int32}
    egress_stop_for_destination::Vector{Int64}
    raptor_result::RaptorResult
    request::StreetRaptorRequest
end

# find the egress times from all stops to all destinations, within distance_limit
function find_egress_times(net::TransitNetwork, osrm::OSRMInstance, destinations::Vector{Coordinate}, max_distance_meters::Real)::EgressTimes
    stop_dest_time = Vector{Vector{EgressTime}}()
    sizehint!(stop_dest_time, length(net.stops))
    lat_diff = meters_to_degrees_lat(max_distance_meters)
    for (i, stop) in ProgressBar(enumerate(net.stops))
        origin = Coordinate(stop.stop_lat, stop.stop_lon)
        # prefilter to just destinations that are nearby
        candidate_destinations = bbox_filter(origin, destinations, max_distance_meters)
        egress_times = Vector{EgressTime}()

        if length(candidate_destinations) > 0
            destination_coords = destinations[candidate_destinations]
            dists = distance_matrix(osrm, [origin], destination_coords)

            for candidate_dest_index in 1:length(candidate_destinations)
                time = dists.durations[1, candidate_dest_index]
                dist = dists.distances[1, candidate_dest_index]
                dest_idx = candidate_destinations[candidate_dest_index]
                if dist <= max_distance_meters
                    push!(egress_times, EgressTime(dest_idx, convert(Int32, round(time))))
                end
            end
        end

        push!(stop_dest_time, egress_times)
    end

    @assert length(stop_dest_time) == length(net.stops)

    return EgressTimes(destinations, stop_dest_time)
end

function street_raptor(net::TransitNetwork, access_router::OSRMInstance, req::StreetRaptorRequest, destinations::EgressTimes)::StreetRaptorResult
    @info "performing access search"

    # find stops near origin
    stop_coords = map(s -> Coordinate(s.stop_lat, s.stop_lon), net.stops)
    stops_near_origin = bbox_filter(req.origin, stop_coords, req.max_access_distance_meters)

    access = distance_matrix(access_router, [req.origin], stop_coords[stops_near_origin])

    accessible_stops = Vector{StopAndTime}()
    for stop_near_origin_idx in 1:length(stops_near_origin)
        stop_idx = stops_near_origin[stop_near_origin_idx]
        # this is the time the stop is reached
        time = req.departure_time + access.durations[1, stop_near_origin_idx]
        dist = access.distances[1, stop_near_origin_idx]

        if dist <= req.max_access_distance_meters
            push!(accessible_stops, StopAndTime(stop_idx, round(time)))
        end
    end

    @info "$(length(accessible_stops)) stops found near origin"
    @info "begin transit routing"

    rreq = RaptorRequest(
        accessible_stops,
        req.max_rides,
        req.date,
        req.walk_speed_meters_per_second
    )

    raptor_res = raptor(net, rreq)

    @info "transit routing complete. adding egress times."
    times_at_destinations::Vector{Int32} = fill(MAX_TIME, length(destinations.destinations))
    egress_stops::Vector{Int64} = fill(INT_MISSING, length(destinations.destinations))

    for stopidx in 1:length(net.stops)
        time_at_stop = raptor_res.times_at_stops_each_round[size(raptor_res.times_at_stops_each_round, 1), stopidx]
        if time_at_stop < MAX_TIME
            # this stop was reached
            for egress in destinations.stop_dest_time[stopidx]
                time_at_dest = time_at_stop + egress.time_seconds
                if time_at_dest < times_at_destinations[egress.dest_idx]
                    times_at_destinations[egress.dest_idx] = time_at_dest
                    egress_stops[egress.dest_idx] = stopidx
                end
            end
        end
    end

    return StreetRaptorResult(times_at_destinations, egress_stops, raptor_res, req)
end