# Trace a path back through the network

@enum LegType transit transfer access egress

struct Leg
    start_time::DateTime
    end_time::DateTime
    origin_stop::Union{Missing, Stop}
    destination_stop::Union{Missing, Stop}
    type::LegType
    route::Union{Missing, Route}
    distance_meters::Union{Missing, Float64}
    geometry::Vector{LatLon}
end

# trace the transit portion of the path
function trace_path(net::TransitNetwork, res::RaptorResult, stop::Int64)::Vector{Leg}
    legs = Vector{Leg}()

    current_stop = stop
    for round in size(res.times_at_stops_each_round, 1):-1:1
        if res.prev_stop[round, current_stop] == INT_MISSING
            # not updated this round
            continue
        end

        # Handle the transit trip

        time_after_round = res.non_transfer_times_at_stops_each_round[round, current_stop]
        prev_stop = res.prev_stop[round, current_stop]
        prev_trip_idx = res.prev_trip[round, current_stop]
        prev_time = res.prev_boardtime[round, current_stop]
        prev_trip = net.trips[prev_trip_idx]
        st1 = findfirst(st -> st.stop == prev_stop && st.departure_time == prev_time, prev_trip.stop_times)
        @assert !isnothing(st1)
        st2 = findfirst(st -> st.stop == current_stop && st.arrival_time == time_after_round, prev_trip.stop_times)
        @assert !isnothing(st2)
        geom = geom_between(prev_trip, net, prev_trip.stop_times[st1], prev_trip.stop_times[st2])
        transit_leg = Leg(
            seconds_since_midnight_to_datetime(res.date, prev_time),
            seconds_since_midnight_to_datetime(res.date, time_after_round),
            net.stops[prev_stop],
            net.stops[current_stop],
            transit,
            net.routes[net.trips[prev_trip_idx].route],
            missing,
            geom)

        push!(legs, transit_leg)

        # see if there was a transfer leading to this boarding
        if round > 1
            transfer_origin = res.transfer_prev_stop[round - 1, prev_stop]
            if transfer_origin != INT_MISSING
                # there was a transfer
                xfer = net.transfers[transfer_origin][findfirst(t -> t.target_stop == prev_stop, net.transfers[transfer_origin])]
                xfer_start_time = res.non_transfer_times_at_stops_each_round[round - 1, transfer_origin]
                xfer_end_time = res.times_at_stops_each_round[round - 1, prev_stop]
                xfer_leg = Leg(
                    seconds_since_midnight_to_datetime(res.date, xfer_start_time),
                    seconds_since_midnight_to_datetime(res.date, xfer_end_time),
                    net.stops[transfer_origin],
                    net.stops[prev_stop],
                    transfer,
                    missing,
                    xfer.distance_meters,
                    xfer.geometry
                )
                push!(legs, xfer_leg)
                current_stop = transfer_origin
            else
                current_stop = prev_stop
            end
        end

    end

    reverse!(legs)

    return legs
end

"""
Trace a path from a StreetRaptorResult, to a particular destination and for a particular departure time (index into range-RAPTOR array)
"""
function trace_path(net::TransitNetwork, res::StreetRaptorResult, destination::Int64, departure::Int64)
    # get the transit path
    raptor_res = res.raptor_results[departure]
    dest_stop = res.egress_stop_each_departure_time[departure, destination]
    depart_date = Date(res.departure_date_time)

    if dest_stop == INT_MISSING
        return missing
    end

    legs = trace_path(net, res.raptor_results[departure], dest_stop)

    # add the egress
    dest_time = res.times_at_destinations_each_departure_time[departure, destination]
    final_stop_arr_time = raptor_res.non_transfer_times_at_stops_each_round[end, dest_stop]
    egr = res.egress_geometries[(destination, dest_stop)]
    egress_leg = Leg(
        seconds_since_midnight_to_datetime(depart_date, final_stop_arr_time),
        seconds_since_midnight_to_datetime(depart_date, dest_time),
        net.stops[dest_stop],
        missing,
        egress,
        missing,
        egr.distance_meters,
        egr.geometry
    )
    push!(legs, egress_leg)

    # add the access
    initial_board_stop = findfirst(s -> s === legs[begin].origin_stop, net.stops)
    acc = res.access_geometries[initial_board_stop]
    # first round is access times
    arrival_time_at_initial_board_stop = legs[begin].start_time - Dates.Second(BOARD_SLACK_SECONDS)
    departure_time = arrival_time_at_initial_board_stop - Dates.Second(round(Int64, acc.duration_seconds))
    access_leg = Leg(
        departure_time,
        arrival_time_at_initial_board_stop,
        missing,
        net.stops[initial_board_stop],
        access,
        missing,
        acc.distance_meters,
        acc.geometry
        )

    pushfirst!(legs, access_leg)

    return legs
end


"""
Return all optimal paths found to get to the destination. Note that optimal in this case does not exactly
match what you would get from running raptor() and trace() repeatedly, because of the "transfer compression"
aspect of the range-RAPTOR algorithm. Suppose your trip requires connecting from an infrequent bus to a frequent
one. Running RAPTOR repeatedly result in always boarding the next available trip on the infrequent bus, even if
you could catch a later trip and still arrive at the same time due to a shorter transfer to the same second bus.

This fill find the latest-departure-time path for all optimal arrival times.
"""
function trace_all_optimal_paths(net::TransitNetwork, res::StreetRaptorResult, destination)
    result = Vector{Vector{Leg}}()

    # we loop backwards over RAPTOR results, just like in range-RAPTOR. Every time we find
    # an earlier arrival at the destination, we trace that trip. This is the latest-departure
    # trip that will get you to teh destination at the optimal time.
    last_best_time = MAX_TIME

    for departure in size(res.times_at_destinations_each_departure_time, 1):-1:1
        arr_time = res.times_at_destinations_each_departure_time[departure, destination]
        if arr_time < last_best_time
            # we have found another optimal trip
            last_best_time = arr_time
            push!(result, trace_path(net, res, destination, departure))
        end
    end

    reverse!(result)
    return result
end