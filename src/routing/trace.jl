# Trace a path back through the network

@enum LegType transit transfer access egress

struct Leg
    start_time::Int32
    end_time::Int32
    origin_stop::Union{Missing, Int64}
    destination_stop::Union{Missing, Int64}
    type::LegType
    trip::Union{Missing, Int64}
    distance_meters::Union{Missing, Float64}
    geometry::LineString
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
        local leg
        if round % 2 == 1
            # transfer rounds are round 3, 5, etc.
            # transfers are assumed to start the instant you get off the previous vehicle
            prev_time = res.times_at_stops_each_round[round - 1, prev_stop]

            if current_stop == prev_stop
                0
            else
                xfer = net.transfers[prev_stop][findfirst(t -> t.target_stop == current_stop, net.transfers[prev_stop])]
            end

            leg = Leg(prev_time, time_after_round, prev_stop, current_stop, transfer, missing, xfer.distance_meters, to_gdal(xfer.geometry))
        else
            prev_trip_idx = res.prev_trip[round, current_stop]
            prev_time = res.prev_boardtime[round, current_stop]
            prev_trip = net.trips[prev_trip_idx]
            st1 = findfirst(st -> st.stop == prev_stop && st.departure_time == prev_time, prev_trip.stop_times)
            st2 = findfirst(st -> st.stop == current_stop && st.arrival_time == time_after_round, prev_trip.stop_times)
            geom = geom_between(prev_trip, net, prev_trip.stop_times[st1], prev_trip.stop_times[st2])
            leg = Leg(prev_time, time_after_round, prev_stop, current_stop, transit, prev_trip_idx, missing, geom)
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

    if dest_stop == INT_MISSING
        return missing
    end

    legs = trace_path(net, res.raptor_result, dest_stop)

    # add the egress
    dest_time = res.times_at_destinations[destination]
    final_stop_arr_time = res.raptor_result.times_at_stops_each_round[size(res.raptor_result.times_at_stops_each_round, 1), dest_stop]
    egress_leg = Leg(final_stop_arr_time, dest_time, dest_stop, missing, egress, missing, res.egress_dist_for_destination[destination], res.egress_geom_for_destination[destination])
    push!(legs, egress_leg)

    # add the access
    initial_board_stop = legs[1].origin_stop
    # first round is access times
    arrival_time_at_initial_board_stop = res.raptor_result.times_at_stops_each_round[1, initial_board_stop]
    access_leg = Leg(time_to_seconds_since_midnight(res.departure_date_time), arrival_time_at_initial_board_stop, missing, initial_board_stop, access, missing, res.access_dist_for_destination[destination], res.access_geom_for_destination[destination])

    pushfirst!(legs, access_leg)

    return legs
end