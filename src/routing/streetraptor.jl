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
    street_raptor(
        net::TransitNetwork,
        access_router::OSRMInstance,
        egress_router::OSRMInstance,
        origin::LatLon{<:Real},
        destinations::AbstractVector{<:LatLon{<:Real}},
        departure_date_time::DateTime,
        time_window_length_seconds::Union{Function, Int64}=0;
        reverse_search=false,
        max_reverse_search_duration=SECONDS_PER_DAY,
        max_access_distance_meters=1000.0,
        max_egress_distance_meters=1000.0,
        max_rides=4,
        stop_to_destination_distances=nothing,
        stop_to_destination_durations=nothing
    )

Perform street and transit routing, departing at or arriving by all of the times in the time window, and return
an array of optimal paths to each destination.

Returns a vector of vectors of paths - one vector of all optimal paths per destination.

"Optimal" means all paths that provide the latest departure given earliest arrival and minimum transfers.
This is subject to an edge effect at the end of the time window. If the latest departure given earliest
arrival for a given arrival time is after the end of the time window (i.e. the trip departing at the end
of the time window involves waiting some amount of time before boarding), it _is_ guaranteed that the returned
path will provide the minimum transfers given earliest arrival. It is _not_, however, guaranteed that the returned
path will provide the latest departure time. The "latest departure" guarantee depends on the range-RAPTOR algorithm
performing a search after the departure time of the second-latest departure. For more information, see
https://projects.indicatrix.org/range-raptor-transfer-compression/. For this reason, with forward searches it is recommended
to extend the time window somewhat past the last desired departure time, to provide a "burn-in" period and avoid
edge effects. A trivial post-processing step removes these paths.

When `reverse_search` is true, finds trips that arrive before each minute of the time window. In this case, no burn-in
period is necessary. The reverse search works by first finding a trip that _departs at_ the latest desired arrival time, and
then steps backwards with range-RAPTOR. Therefore, the latest departure will always be found.

There is no explicit maximum duration for forward searches; if a trip is possible using transit vehicles running on yesterday's,
today's, or tomorrow's schedule, they will be found. For a reverse search, a maximum duration is specified to keep the algorithm
from continuing to iterate backwards forever, in hopes there may be a trip a possible at some point in the past.

Note that when there are multiple destinations, the results will include all optimal paths to any destination that depart at the same
time or later than the latest departure time for any destination that arrives at or before the start of the time window. So if there
are two destinations, one nearby and one far away, there may be multiple trips to the nearby destination that arrive before the start
of the time window. For instance, if the time window is 8:00-10:00, and to get the further destination by 8 requires leaving at 6:30, we
will also find all optimal trips to the nearer destination that leave at or after 6:30. This may mean, for example, that we find both 6:40-6:55
and a 7:40-7:55 trip. A simple postprocessing step can remove these trips if desired.
"""
function street_raptor(
    net::TransitNetwork,
    access_router::OSRMInstance,
    egress_router::OSRMInstance,
    origin::LatLon{<:Real},
    destinations::AbstractVector{<:LatLon{<:Real}},
    departure_date_time::DateTime,
    time_window_length_seconds::Union{Function, Int64}=0;
    reverse_search=false,
    max_reverse_search_duration=SECONDS_PER_DAY,
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

    access_times = Dict{Int64, Int32}()
    access_dists = Dict{Int64, Int32}()
    access_stop_hints = Dict{Int64, String}()
    # Where the origin got snapped
    origin_hint = first(access.origin_waypoints).hint

    for stop_near_origin_idx in eachindex(stops_near_origin)
        stop_idx = stops_near_origin[stop_near_origin_idx]
        # this is the time the stop is reached
        access_time = access.duration_seconds[1, stop_near_origin_idx]
        dist = access.distance_meters[1, stop_near_origin_idx]

        if dist <= max_access_distance_meters
            access_times[stop_idx] = round(Int32, access_time)
            access_dists[stop_idx] = round(Int32, dist)
            # where the destination got snapped
            access_stop_hints[stop_idx] = access.destination_waypoints[stop_near_origin_idx].hint
        end
    end

    @debug "$(length(accessible_stops)) stops found near origin"

    @debug "finding stops near destination"

    # once there is at least one stop in each column that is less than the specified value,
    # we are done
    # TODO different arrival times per-destination

    # indexed by destidx, stopidx
    egress_times = Dict{NTuple{2, Int64}, Int32}()
    egress_dists = Dict{NTuple{2, Int64}, Int32}()
    
    # where each destination got snapped
    destination_hints = String[]

    # where each stop got snapped for each destination
    egress_stop_hints = Dict{NTuple{2, Int64}, String}()

    for destidx in eachindex(destinations)
        stops_near_destination = bbox_filter(destinations[destidx], stop_coords, max_egress_distance_meters)
        egress = distance_matrix(egress_router, stop_coords[stops_near_destination], [destinations[destidx]])

        push!(destination_hints, first(egress.destination_waypoints).hint)

        for stop_near_dest_idx in eachindex(stops_near_destination)
            dist = egress.distance_meters[stop_near_dest_idx, 1]
            time = egress.duration_seconds[stop_near_dest_idx, 1]
            if dist < max_egress_distance_meters
                stopidx = stops_near_destination[stop_near_dest_idx]
                egress_times[(destidx, stopidx)] = round(Int32, time)
                egress_dists[(destidx, stopidx)] = round(Int32, dist)
                egress_stop_hints[(destidx, stopidx)] = egress.origin_waypoints[stop_near_dest_idx].hint
            end
        end
    end

    @debug "begin transit routing"

    paths = map(_ -> Vector{TransitRouter.Leg}[], destinations)
    times_at_destinations = fill(MAX_TIME, length(destinations))
    transfers = fill(typemax(Int64), length(destinations))

    # previously reverse searches were specified with negative time window lengths. Catch old code still
    # using that API.
    time_window_length_seconds ≥ 0 || error("Time window length must be greater than zero (specify reverse searches like forward searches, with reverse_search=true)")

    initial_offset = convert(Int32, time_window_length_seconds)
    offset_step = convert(Int32, -SECONDS_PER_MINUTE)

    # access and egress geometries filled in as needed
    access_geom = Dict{Int64, Vector{LatLon{Float64}}}()
    egress_geom = Dict{NTuple{2, Int64}, Vector{LatLon{Float64}}}()

    date = Date(departure_date_time)
    raptor(net, date; max_rides=max_rides) do result::Union{Nothing, RaptorResult}, offset::Union{Nothing, Int32}
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
                    if result.non_transfer_times_at_stops_each_round[end, stop] < MAX_TIME && haskey(egress_times, (destidx, stop))
                        time_at_dest_this_stop = result.non_transfer_times_at_stops_each_round[end, stop] + egress_times[(destidx, stop)]
                        if time_at_dest_this_stop < time_at_dest_this_minute
                            time_at_dest_this_minute = time_at_dest_this_stop
                            egress_stop = stop
                        end 
                    end
                end

                if reverse_search && time_at_dest_this_minute > departure_time
                    # in a reverse search, see if we've found paths to everywhere before the earliest
                    # requested arrival time
                    found_path_to_all = false
                end

                # don't retain reverse search trips that arrive after the end of the time window.
                if egress_stop > -1 && (!reverse_search || time_at_dest_this_minute ≤ departure_time + time_window_length_seconds)
                    ntransfers = get_last_round(result, egress_stop)
                    if time_at_dest_this_minute < times_at_destinations[destidx] || ntransfers < transfers[destidx]
                        path, boardstop = trace_path(net, result, egress_stop)
                        
                        # add access and egress legs
                        egrgeom = if haskey(egress_geom, (destidx, egress_stop))
                            egress_geom[(destidx, egress_stop)]
                        else
                            egrstop = net.stops[egress_stop]
                            r = first(route(egress_router, LatLon(egrstop.stop_lat, egrstop.stop_lon), destinations[destidx];
                                # force OSRM to snap the same way as the distance matrix
                                origin_hint=egress_stop_hints[(destidx, egress_stop)], destination_hint=destination_hints[destidx]))
                           
                            # route() does not always return routes consistent with distances/times from distance_matrix, because of snapping
                            # OSRM evidently requires that all of the points in a distance_matrix be snapped to the same strong component. When
                            # there are only two points (stop and destination), they may both be snapped to a smaller strong component close to
                            # them that connects the two of them. When used in distance_matrix, they may be snapped to a larger strong component
                            # (the network overall, rather than an island), meaning distance_matrix gives different results. The results from
                            # distance_matrix are probably what we actually want in most cases, except weird cases where you have actual disconnected
                            # strong components by foot that are served by transit (e.g. airports, MetLife Stadium, Chappaquidick Island). This is a
                            # difficult problem, because it's not clear from the data which is correct (i.e. is this actually an island, or just some
                            # bad data.) We use the times and distances from distance_matrix here, because they're the ones used in the routing and in
                            # most cases they're the ones we want. If we used the times and distances from route() we might get weird results, because
                            # the paths returned were based on different access/egress times (e.g., if the route() access time is longer than the
                            # distance_matrix() one, we might return a route that departs before the requested departure time. If the opposite were true,
                            # we might return a path that looks like it should dominate others that were also found because it leaves later and arrives
                            # earlier). We use the geometry from route() since we don't have a geometry from distance_matrix. This is relatively rare,
                            # and mostly comes up around suburban stations with disconnected pedestrian networks.
                            # https://github.com/Project-OSRM/osrm-backend/issues/6629
                            if abs(r.duration_seconds - egress_times[(destidx, egress_stop)]) > 60
                                @error "Duration returned by distance_matrix ($(egress_times[(destidx, egress_stop)])) does not match that returned by route ($(r.duration_seconds)), for egress stop $(egrstop.stop_id) to destination $(destinations[destidx])"
                            end

                            if abs(r.distance_meters - egress_dists[(destidx, egress_stop)]) > 100
                                @error "Distance returned by distance_matrix ($(egress_dists[(destidx, egress_stop)])) does not match that returned by route ($(r.distance_meters)), for egress stop $(egrstop.stop_id) to destination $(destinations[destidx])"
                            end

                            egress_geom[(destidx, egress_stop)] = r.geometry

                            r.geometry
                        end

                        push!(path, Leg(
                            seconds_since_midnight_to_datetime(date, result.non_transfer_times_at_stops_each_round[end, egress_stop]),
                            seconds_since_midnight_to_datetime(date, time_at_dest_this_minute),
                            net.stops[egress_stop],
                            missing,
                            egress,
                            missing,
                            egress_dists[(destidx, egress_stop)],
                            egrgeom
                        ))

                        accgeom = if haskey(access_geom, boardstop)
                            access_geom[boardstop]
                        else
                            accstop = net.stops[boardstop]
                            r = first(route(access_router, origin, LatLon(accstop.stop_lat, accstop.stop_lon);
                                origin_hint=origin_hint, destination_hint=access_stop_hints[boardstop]))
                           
                            # see comment above on egress geom
                            if abs(r.duration_seconds - access_times[boardstop]) > 60
                                @error "Duration returned by distance_matrix ($(access_times[boardstop])) does not match that returned by route ($(r.duration_seconds)), for access stop $(accstop.stop_id) from origin $(origin)"
                            end

                            if abs(r.distance_meters - access_dists[boardstop]) > 100
                                @error "Distance returned by distance_matrix ($(access_dists[boardstop])) does not match that returned by route ($(r.distance_meters)), for access stop $(accstop.stop_id) from origin $(origin)"
                            end

                            access_geom[boardstop] = r.geometry

                            r.geometry
                        end

                        pushfirst!(path, Leg(
                            path[begin].start_time - Second(BOARD_SLACK_SECONDS) - Second(access_times[boardstop]),
                            path[begin].start_time - Second(BOARD_SLACK_SECONDS),
                            missing,
                            path[begin].origin_stop,
                            TransitRouter.access,
                            missing,
                            access_dists[boardstop],
                            accgeom
                        ))

                        @debug "Found path at offset $offset. Best time now $(Time(TransitRouter.seconds_since_midnight_to_datetime(date, time_at_dest_this_minute))) with $(ntransfers - 2) transfers\n" *
                            join(Base.show.(path), "\n")

                        pushfirst!(paths[destidx], path)
                        times_at_destinations[destidx] = time_at_dest_this_minute
                        transfers[destidx] = ntransfers
                    end
                end
            end

            # Increment offset
            # do this here so the stopping criteria below are based on the offset that would otherwise be used in the _next_
            # step
            offset += offset_step

            # search termination for reverse search: we've found paths to all destinations that arrive before the earliest
            # requested arrival time.
            if reverse_search && found_path_to_all
                return nothing
            end

            # alternate search termination for reverse search: we've run past the maximum search window
            if reverse_search && offset < -abs(max_reverse_search_duration)
                return nothing
            end
            
            # search termination for forward search: we've searched the entire requested window
            if !reverse_search && offset < 0
                return nothing
            end
        end

        return (StopAndTime(s, departure_time + access_times[s] + offset, access_dists[s]) for s in keys(access_times)), offset
    end

    return paths
end