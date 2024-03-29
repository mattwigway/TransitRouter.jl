# RAPTOR: Round-Based Public Transit Optimized Routing
# Described in Delling, D., Pajor, T., & Werneck, R. (2012). Round-Based Public Transit Routing. http://research.microsoft.com/pubs/156567/raptor_alenex.pdf

const MAX_TIME = typemax(Int32)
const INT_MISSING = -2
const BOARD_SLACK_SECONDS = convert(Int32, 60)
const OFFSETS = (yesterday=convert(Int32, -SECONDS_PER_DAY), today=zero(Int32), tomorrow=convert(Int32, SECONDS_PER_DAY))

struct StopAndTime
    stop::Int64
    time::Int32
    walk_distance_meters::Int64
end

StopAndTime(stop, time) = StopAndTime(stop, time, 0)

"""
Contains the results of a RAPTOR search.

## Fields

- `times_at_stops_each_round[i, j]` is the earliest time stop j can be reached after round i, whether
  directly via transit or via a transfer. Round 1 is only has the access stops and times, transit routing
  first appears in round 2.

  Times at stops are propagated forward, so a stop reached in round 2 will still be present with the same time
  in round 3, unless a faster way has been found.

- `non_transfer_times_at_stops_each_round[i, j]` is the earliest time stop j can be reached after round i,
  directly via transit. Round 1 will be blank, as the access leg is considered a transfer, transit routing
  first appears in round 2.

  Non-transfer times at stops are propagated forward, so a stop reached in round 2 will still be present with the same time
  in round 3, unless a faster way has been found.

- `walk_distance_meters[i, j]` is the walk distance corresponding to the route in time_at_stops_each_round. Walk distance
  is used as a tiebreaker when multiple routes get you on the same vehicle.

- `non_transfer_walk_distance_meters[i, j]` is similar for the route coresponding to the time in non_transfer_times_at_stops_each_round.

- `prev_stop[i, j]` is the stop where the passenger boarded the transit vehicle that delivered
  them to stop j in round i. This only reflects stops reached via transit; if the stop was reached via
  a transfer, the origin of the transfer will be stored in `transfer_prev_stop`. `transfer_prev_stop` and
  `prev_stop` may differ, if the stop was reached via transit, but there is a faster way to reach it via a
  transfer.

  prev_stop will contain INT_MISSING for a stop not reached in round i, even if it was previously reached.

- `transfer_prev_stop[i, j]` is the stop where the passenger alighted from transit vehicle in this round, and
  then transferred to this stop. This only reflects stops reached via transfers; if the stop was reached via
  transit directly, the origin will be stored in `rev_stop`. `transfer_prev_stop` and
  `prev_stop` may differ, if the stop was reached via transit, but there is a faster way to reach it via a
  transfer.

  transfer_prev_stop will contain INT_MISSING for a stop not reached in round i, even if it was previously reached.

-  `prev_trip[i, j]` is the trip index of the transit vehicle that delivered the passenger to stop j in round i. Like `prev_stop`,
  always refers to stops reached via transit directly, not via transfers. To find the trip that brought a user to a transfer,
  first look for the transfer origin in transfer_prev_stop, and then look at prev_trip for that stop.

  Will contain INT_MISSING if stop j not reached in round i.

- `prev_boardtime[i, j]` is the board time index of the transit vehicle that delivered the passenger to stop j in round i. Like `prev_stop`,
  always refers to stops reached via transit directly, not via transfers. To find the trip that brought a user to a transfer,
  first look for the transfer origin in transfer_prev_stop, and then look at prev_trip for that stop.

  Will contain INT_MISSING if stop j not reached in round i.

- `date` is the date of the request

"""
struct RaptorResult
    times_at_stops_each_round::Array{Int32, 2} 
    non_transfer_times_at_stops_each_round::Array{Int32, 2}
    walk_distance_meters::Matrix{Int32}
    non_transfer_walk_distance_meters::Matrix{Int32}
    prev_stop::Array{Int64, 2}
    transfer_prev_stop::Matrix{Int64}
    prev_trip::Array{Int64, 2}
    prev_boardtime::Array{Int32, 2}
    date::Date
end

# old API
#@deprecate
raptor(net, origins::Vector{StopAndTime}, date::Date; kwargs...) = raptor(origins, net, date; kwargs...)

raptor(origins::Vector{StopAndTime}, net, date::Date; kwargs...) =
    raptor((r, v) -> (isnothing(r) ? (origins, nothing) : nothing), net, date; kwargs...)

function raptor(
    origins::Function,
    net::TransitNetwork,
    date::Date;
    max_transfer_distance_meters=nothing,
    max_rides=DEFAULT_MAX_RIDES
    )
    nstops = length(net.stops)
    # + 1 for access
    nrounds = max_rides + 1

    # these get allocated here, and the core RAPTOR algorithm should have 0 allocations
    # last times at stops not used, no transfer phase
    times_at_stops::Array{Int32,2} = fill(MAX_TIME, (nrounds - 1, nstops))
    non_transfer_times_at_stops::Array{Int32, 2} = fill(MAX_TIME, (nrounds, nstops))
    walk_distance_meters::Matrix{Int32} = fill(INT_MISSING, (nrounds - 1, nstops))
    non_transfer_walk_distance_meters::Matrix{Int32} = fill(INT_MISSING, (nrounds, nstops))
    prev_stop::Array{Int64,2} = fill(INT_MISSING, (nrounds, nstops))
    transfer_stop::Array{Int64,2} = fill(INT_MISSING, (nrounds - 1, nstops))
    prev_trip::Array{Int64,2} = fill(INT_MISSING, (nrounds, nstops))
    prev_boardtime::Array{Int32,2} = fill(INT_MISSING, (nrounds, nstops))
    prev_touched_stops = falses(nstops)::BitVector
    touched_stops = falses(nstops)::BitVector
    touched_patterns = falses(length(net.patterns))::BitVector

    # get which service idxes are running (for yesterday today and tomorrow to account for overnight routing)
    services_running = (
        yesterday = is_service_running.(net.services, date - Day(1)),
        today = is_service_running.(net.services, date),
        tomorrow = is_service_running.(net.services, date + Day(1))
    )

    @debug "$(length(services_running)) services running on requested date"

    result = RaptorResult(
        times_at_stops,
        non_transfer_times_at_stops,
        walk_distance_meters,
        non_transfer_walk_distance_meters,
        prev_stop,
        transfer_stop,
        prev_trip,
        prev_boardtime,
        date
    )

    
    # get initial times at stops
    origin_times, val = origins(nothing, nothing)
    while true
        # initialize times at stops
        for sat in origin_times
            if sat.time < times_at_stops[1, sat.stop]
                times_at_stops[1, sat.stop] = sat.time
                walk_distance_meters[1, sat.stop] = sat.walk_distance_meters
                transfer_stop[1, sat.stop] = INT_MISSING
                prev_touched_stops[sat.stop] = true
            end
        end

        run_raptor!(net, result, max_transfer_distance_meters, max_rides, services_running, prev_touched_stops, touched_stops, touched_patterns)

        fill!(prev_touched_stops, false)
        fill!(touched_stops, false)

        nextstops = origins(result, val)
        if isnothing(nextstops)
            break
        else
            origin_times, val = nextstops
        end
    end

    return result
end

function run_raptor!(net::TransitNetwork, result, max_transfer_distance_meters, max_rides, services_running,
        prev_touched_stops, touched_stops, touched_patterns)

    # convenience
    times_at_stops = result.times_at_stops_each_round
    non_transfer_times_at_stops = result.non_transfer_times_at_stops_each_round
    walk_distance_meters = result.walk_distance_meters
    non_transfer_walk_distance_meters = result.non_transfer_walk_distance_meters
    prev_stop = result.prev_stop
    transfer_prev_stop = result.transfer_prev_stop
    prev_trip = result.prev_trip
    prev_boardtime = result.prev_boardtime

    for current_round in 1:max_rides
        # where the results of this round will be recorded
        target = current_round + 1

        # preinitialize times with times from previous round, or from later minute
        for stop in eachindex(net.stops)
            # skip on last round, no transfers
            if current_round != max_rides && times_at_stops[current_round, stop] < times_at_stops[target, stop]
                # copy forward times and clear transfer information
                # not clearing transit path information as that is associated with non-transfer times
                times_at_stops[target, stop] = times_at_stops[current_round, stop]
                walk_distance_meters[target, stop] = walk_distance_meters[current_round, stop]
                transfer_prev_stop[target, stop] = INT_MISSING
            end

            if non_transfer_times_at_stops[current_round, stop] < non_transfer_times_at_stops[target, stop]
                # copy forward non-transfer times and clear transit information
                non_transfer_times_at_stops[target, stop] = non_transfer_times_at_stops[current_round, stop]
                non_transfer_walk_distance_meters[target, stop] = non_transfer_walk_distance_meters[current_round, stop]
                prev_stop[target, stop] = INT_MISSING
                prev_boardtime[target, stop] = INT_MISSING
                prev_trip[target, stop] = INT_MISSING
            end
        end

        # find all patterns that were touched
        fill!(touched_patterns, false)
        for stop in eachindex(prev_touched_stops)
            if prev_touched_stops[stop]
                for pat in net.patterns_for_stop[stop]
                    touched_patterns[pat] = true
                end
            end
        end

        # find all patterns that were touched in the previous round
        for (services_running_this_day, stop_time_offset) in (
            (services_running[:yesterday], OFFSETS[:yesterday]), # all my problems seemed so far away 
            (services_running[:today], OFFSETS[:today]), # while the blossoms still cling to the vine
            (services_running[:tomorrow], OFFSETS[:tomorrow]) # tomorrow, I love you, tomorrow, you're always a day away
        )

            for patidx in eachindex(touched_patterns)
                if touched_patterns[patidx]
                    # explore patterns thrice, once for yesterday, today and tomorrow
                    tp = net.patterns[patidx]

                    if services_running_this_day[tp.service]
                        explore_pattern!(net, result, target, tp, patidx, stop_time_offset, touched_stops, prev_touched_stops)
                    end
                end

                
                # possible optimization: if we rode the pattern today, don't check for tomorrow
                # might need to add some checks to make sure that services are non-overlapping
                # i.e. there isn't a service from today that starts at 24:30 after the 00:10 service
                # tomorrow starts. Checking that the hours are always >= 0 and every trip has a first
                # departure time < 24 would be mostly sufficient - overtaking trips notwithstanding
                # but that would cut computation roughly in half, so we might be okay with overtaking trips
                # not working across service days.
            end # yesterday/today/tomorrow loop
        end

        @debug "round $current_round found $(length(touched_stops)) stops accessible by transit"

        # clear prev_touched_stops and reuse as next_touched_stops, avoid allocation
        fill!(prev_touched_stops, false)
        next_touched_stops = prev_touched_stops

        # do transfers, but skip after last iteration
        if current_round < max_rides
            # don't find transfers to stops that already have better transfers from previous rounds
            # this should not affect routing results, as those transfers would not be optimal in the next
            # round of transit routing, but better to stop it before it happens
            # ≤ means fewer transfer routes will win over more transfer routes.
            # TODO this is not happening anymore. This used to copy forward transfers from previous rounds, now it just copies non-transfer times
            # to transfer times (i.e. loop transfers)
            # preserve_old = dominates.(times_at_stops[target, :], walk_distance_meters[target, :], non_transfer_times_at_stops[target, :], non_transfer_walk_distance_meters[target, :])
            # times_at_stops[target, :] = ifelse.(preserve_old, times_at_stops[target, :], non_transfer_times_at_stops[target, :])
            # walk_distance_meters[target, :] = ifelse.(preserve_old, walk_distance_meters[target, :], non_transfer_walk_distance_meters[target, :])
            # transfer_prev_stop[target, :] = ifelse.(preserve_old, transfer_prev_stop[target, :], INT_MISSING)

            # leave other things missing if there were no transfers
            for stop in eachindex(touched_stops)
                if !touched_stops[stop]
                    continue
                end

                next_touched_stops[stop] = true  # this stop was touched by this round

                # handle the loop transfer
                if non_transfer_times_at_stops[target, stop] < times_at_stops[target, stop]
                    times_at_stops[target, stop] = non_transfer_times_at_stops[target, stop]
                    walk_distance_meters[target, stop] = non_transfer_walk_distance_meters[target, stop]
                    transfer_prev_stop[target, stop] = INT_MISSING
                end

                for xfer in net.transfers[stop]
                    if isnothing(max_transfer_distance_meters) || xfer.distance_meters <= max_transfer_distance_meters
                        pre_xfer_time = non_transfer_times_at_stops[target, stop]
                        time_after_xfer = pre_xfer_time + round(Int32, xfer.duration_seconds)
                        dist_after_xfer = non_transfer_walk_distance_meters[target, stop] + round(Int32, xfer.distance_meters)
                        if time_after_xfer < times_at_stops[target, xfer.target_stop]
                            # transferring to this stop is optimal!
                            times_at_stops[target, xfer.target_stop] = time_after_xfer
                            walk_distance_meters[target, xfer.target_stop] = dist_after_xfer
                            transfer_prev_stop[target, xfer.target_stop] = stop

                            # note that we do _not_ update prev_boardtime, etc here because
                            # those only represent stops reached via transit directly. If we did,
                            # you could run into trouble if you had a scenario where a stop was reached
                            # both via transit and quicker via a transfer, and a second transfer built
                            # on the transit route, and another ride built on the transfer - there would
                            # be no way to trace the trip back for the ride that arrived via transit.
                            next_touched_stops[xfer.target_stop] = true
                        end
                    end
                end
            end
        end

        # prepare for next iteration
        prev_touched_stops = next_touched_stops
        fill!(touched_stops, false)
    end
end

# explore a pattern to see if we can use it in this round
function explore_pattern!(net, result, target, tp, patidx, stop_time_offset, touched_stops, prev_touched_stops)
# possible optimization: skip trip patterns that don't run after departure time
    # (most patterns from yesterday will get skipped)

    # find the trip that departs at or after the earliest possible departure
    # use times_at_stops; allow transfers
    current_tripidx = -1
    current_boardstop = -1
    current_boardtime = typemin(Int32)
    
    for (stopidx, stop) in enumerate(tp.stops)
        # get the current arrival and departure times at this stop
        current_trip_arrival_time, current_trip_departure_time = if current_tripidx ≠ -1
            trip = net.trips[current_tripidx]
            trip.stop_times[stopidx].arrival_time + stop_time_offset, trip.stop_times[stopidx].departure_time + stop_time_offset
        else
            typemin(Int32), typemin(Int32)
        end

        # see if it makes sense to alight
        # do this before boarding, because you might have a situation where one path rides A->B and another rides B->C
        if current_tripidx ≠ -1 && tp.drop_off_types[stopidx] != PickupDropoffType.NotAvailable
            # see if it's (strictly) better - strict so more-transfer trips don't replace fewer-transfer trips
            if current_trip_arrival_time::Int32 < result.non_transfer_times_at_stops_each_round[target, stop]
                result.non_transfer_times_at_stops_each_round[target, stop] = current_trip_arrival_time::Int32
                result.prev_stop[target, stop] = current_boardstop::Int64
                result.prev_trip[target, stop] = current_tripidx::Int64
                result.prev_boardtime[target, stop] = current_boardtime::Int32
                result.non_transfer_walk_distance_meters[target, stop] = result.walk_distance_meters[target - 1, current_boardstop]
                touched_stops[stop] = true
            end
        end


        # see if we can board
        # if we're at a stop reached in the previous round, and we haven't boarded this pattern yet, see if we can board
        # if we're on board, try to board an earlier trip if the best time to the stop is before the current trip departure time
        if prev_touched_stops[stop] &&
                (current_tripidx == -1 || result.times_at_stops_each_round[target - 1, stop] ≤ current_trip_departure_time::Int32 - BOARD_SLACK_SECONDS) &&
                tp.pickup_types[stopidx] != PickupDropoffType.NotAvailable
            candidate_arrival_time = result.times_at_stops_each_round[target - 1, stop]
            @assert candidate_arrival_time < MAX_TIME
            earliest_board_time = candidate_arrival_time + BOARD_SLACK_SECONDS
            best_candidate = -1
            best_candidate_departure_time = zero(Int32)
            for tripidx in net.trips_for_pattern[patidx]
                candidate_trip = net.trips[tripidx]
                candidate_departure_time = candidate_trip.stop_times[stopidx].departure_time + stop_time_offset
                if earliest_board_time ≤ candidate_departure_time::Int32 && (best_candidate == -1 || candidate_departure_time::Int32 < best_candidate_departure_time::Int32)
                    best_candidate = tripidx
                    best_candidate_departure_time = candidate_departure_time
                end
            end

            # if we touched this stop and it had a time at the stop early enough to run this loop,
            # we should at least be able to board this trip
            @assert current_tripidx == -1 || best_candidate_departure_time::Int32 ≤ current_trip_departure_time::Int32

            # if we found something we can board, and we're not on a vehicle yet, or the new trip
            # is better than what we're currently on OR has a lower walk distance, board here. 
            if best_candidate > 0 && (
                current_tripidx == -1 || # not yet boarded
                best_candidate_departure_time::Int32 < current_trip_departure_time::Int32 || # board an earlier vehicle
                # found the same trip (or one that leaves at the same time - this may be important if there
                # are duplicate trips), and we have a lower walk distance (transfer preference in the RAPTOR paper)
                (best_candidate_departure_time::Int32 == current_trip_departure_time::Int32 &&
                    result.walk_distance_meters[target - 1, stop] < result.walk_distance_meters[target - 1, current_boardstop])
            )

                # hop on board
                current_tripidx = best_candidate
                current_boardstop = stop
                current_boardtime = best_candidate_departure_time
            end
        end
    end
end