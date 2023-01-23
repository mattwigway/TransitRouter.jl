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
    for round in size(res.times_at_stops_each_round, 1):-1:2
        if res.prev_stop[round, current_stop] == INT_MISSING
            # not updated this round
            continue
        end

        time_after_round = res.times_at_stops_each_round[round, current_stop]

        prev_stop = res.prev_stop[round, current_stop]

        # okay, something happened this round. figure out if it was a transfer.
        leg = if round % 2 == 1
            # transfer rounds are round 3, 5, etc.
            # transfers are assumed to start the instant you get off the previous vehicle
            prev_time = res.times_at_stops_each_round[round - 1, prev_stop]

            if current_stop == prev_stop
                0
            else
                xfer = net.transfers[prev_stop][findfirst(t -> t.target_stop == current_stop, net.transfers[prev_stop])]
            end

            Leg(
                seconds_since_midnight_to_datetime(res.date, prev_time),
                seconds_since_midnight_to_datetime(res.date, time_after_round),
                net.stops[prev_stop],
                net.stops[current_stop],
                transfer,
                missing,
                xfer.distance_meters,
                xfer.geometry
            )
        else
            prev_trip_idx = res.prev_trip[round, current_stop]
            prev_time = res.prev_boardtime[round, current_stop]
            prev_trip = net.trips[prev_trip_idx]
            st1 = findfirst(st -> st.stop == prev_stop && st.departure_time == prev_time, prev_trip.stop_times)
            st2 = findfirst(st -> st.stop == current_stop && st.arrival_time == time_after_round, prev_trip.stop_times)
            geom = geom_between(prev_trip, net, prev_trip.stop_times[st1], prev_trip.stop_times[st2])
            Leg(
                seconds_since_midnight_to_datetime(res.date, prev_time),
                seconds_since_midnight_to_datetime(res.date, time_after_round),
                net.stops[prev_stop],
                net.stops[current_stop],
                transit,
                net.routes[net.trips[prev_trip_idx].route],
                missing,
                geom)
        end

        push!(legs, leg)

        # prepare for previous iteration (we're going backwards)
        current_stop = prev_stop
    end

    reverse!(legs)

    return legs
end

function trace_path(net::TransitNetwork, res::StreetRaptorResult, destination::Int64)
    # get the transit path
    dest_stop = res.egress_stop_for_destination[destination]
    depart_date = Date(res.departure_date_time)

    if dest_stop == INT_MISSING
        return missing
    end

    legs = trace_path(net, res.raptor_result, dest_stop)

    # add the egress
    dest_time = res.times_at_destinations[destination]
    final_stop_arr_time = res.raptor_result.times_at_stops_each_round[size(res.raptor_result.times_at_stops_each_round, 1), dest_stop]
    egress_leg = Leg(
        seconds_since_midnight_to_datetime(depart_date, final_stop_arr_time),
        seconds_since_midnight_to_datetime(depart_date, dest_time),
        net.stops[dest_stop],
        missing,
        egress,
        missing,
        res.egress_dist_for_destination[destination],
        res.egress_geom_for_destination[destination]
    )
    push!(legs, egress_leg)

    # add the access
    initial_board_stop = findfirst(s -> s === legs[1].origin_stop, net.stops)
    # first round is access times
    arrival_time_at_initial_board_stop = seconds_since_midnight_to_datetime(
        depart_date,
        res.raptor_result.times_at_stops_each_round[1, initial_board_stop]
    )
    access_leg = Leg(
        res.departure_date_time,
        arrival_time_at_initial_board_stop,
        missing,
        net.stops[initial_board_stop],
        access,
        missing,
        res.access_dist_for_destination[destination],
        res.access_geom_for_destination[destination]
        )

    pushfirst!(legs, access_leg)

    return legs
end