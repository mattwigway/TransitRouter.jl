# Trace a path back through the network

@enum LegType transit transfer access egress

struct Leg
    start_time::Int32
    end_time::Int32
    origin_stop::Union{Missing, Int64}
    destination_stop::Union{Missing, Int64}
    type::LegType
    route::Union{Missing, Int64}
end

# trace the transit portion of the path
function trace_path(res::RaptorResult, stop::Int64)::Vector{Leg}
    legs = Vector{Leg}()

    current_stop = stop
    for round in size(res.times_at_stops_each_round, 1):-1:2
        time_after_round = res.times_at_stops_each_round[round, current_stop]
        time_before_round = res.times_at_stops_each_round[round - 1, current_stop]

        if time_after_round == time_before_round
            # not updated this round
            continue
        end

        prev_stop = res.prev_stop[round, current_stop]

        # okay, something happened this round. figure out if it was a transfer.
        local leg
        if round % 2 == 1
            # transfer rounds are round 3, 5, etc.
            # transfers are assumed to start the instant you get off the previous vehicle
            prev_time = res.times_at_stops_each_round[round - 1, prev_stop]
            leg = Leg(prev_time, time_after_round, prev_stop, current_stop, transfer, missing)
        else
            prev_route = res.prev_route[round, current_stop]
            prev_time = res.prev_boardtime[round, current_stop]
            leg = Leg(prev_time, time_after_round, prev_stop, current_stop, transit, prev_route)
        end

        push!(legs, leg)

        # prepare for previous iteration (we're going backwards)
        current_stop = prev_stop
    end

    reverse!(legs)

    return legs
end

function trace_path(res::StreetRaptorResult, destination::Int64)::Union{Missing, Vector{Leg}}
    # get the transit path
    dest_stop = res.egress_stop_for_destination[destination]

    if ismissing(dest_stop)
        return missing
    else
        legs = trace_path(res.raptor_result, dest_stop)

        # add the egress
        dest_time = res.times_at_destinations[destination]
        final_stop_arr_time = res.raptor_result.times_at_stops_each_round[size(res.raptor_result.times_at_stops_each_round, 1), dest_stop]
        egress_leg = Leg(final_stop_arr_time, dest_time, dest_stop, missing, egress, missing)
        push!(legs, egress_leg)

        # add the access
        initial_board_stop = legs[1].origin_stop
        # first round is access times
        arrival_time_at_initial_board_stop = res.raptor_result.times_at_stops_each_round[1, initial_board_stop]
        access_leg = Leg(res.request.departure_time, arrival_time_at_initial_board_stop, missing, initial_board_stop, access, missing)

        pushfirst!(legs, access_leg)

        return legs
    end
end