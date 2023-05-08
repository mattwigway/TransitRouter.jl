# RAPTOR: Round-Based Public Transit Optimized Routing
# Described in Delling, D., Pajor, T., & Werneck, R. (2012). Round-Based Public Transit Routing. http://research.microsoft.com/pubs/156567/raptor_alenex.pdf

const MAX_TIME = typemax(Int32)
const XFER_ROUTE = -1
const INT_MISSING = -2
const ORIGIN = -3
const BOARD_SLACK_SECONDS = 60
const EMPTY_SET = BitSet()
const OFFSETS = (yesterday=-SECONDS_PER_DAY, today=0, tomorrow=SECONDS_PER_DAY)

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
    prev_stop::Array{Int64, 2}
    transfer_prev_stop::Matrix{Int64}
    prev_trip::Array{Int64, 2}
    prev_boardtime::Array{Int32, 2}
    date::Date
end

function empty_no_resize!(s::BitSet)
    for set_bit in s
        delete!(s, set_bit)
    end
end

function raptor(
    net::TransitNetwork,
    origins::Vector{StopAndTime},
    date::Date;
    walk_speed_meters_per_second=DEFAULT_WALK_SPEED_METERS_PER_SECOND,
    max_transfer_distance_meters=DEFAULT_MAX_LEG_WALK_DISTANCE_METERS,
    max_rides=DEFAULT_MAX_RIDES
    )
    nstops = length(net.stops)
    # + 1 for access
    nrounds = max_rides + 1

    # these get allocated here, and the core RAPTOR algorithm should have 0 allocations
    # last times at stops not used, no transfer phase
    times_at_stops::Array{Int32,2} = fill(MAX_TIME, (nrounds - 1, nstops))
    non_transfer_times_at_stops::Array{Int32, 2} = fill(MAX_TIME, (nrounds, nstops))
    prev_stop::Array{Int64,2} = fill(INT_MISSING, (nrounds, nstops))
    transfer_stop::Array{Int64,2} = fill(INT_MISSING, (nrounds, nstops))
    prev_trip::Array{Int64,2} = fill(INT_MISSING, (nrounds, nstops))
    prev_boardtime::Array{Int32,2} = fill(INT_MISSING, (nrounds, nstops))
    # set bit 0 so that offset is forced to zero and there aren't allocations later
    prev_touched_stops::BitSet = BitSet([0])
    touched_stops::BitSet = BitSet([0])
    sizehint!(prev_touched_stops, nstops)
    sizehint!(touched_stops, nstops)

    # unset the 0 set bits that were to force offset
    delete!(prev_touched_stops, 0)
    delete!(touched_stops, 0)

    # initialize times at stops
    for sat in origins
        times_at_stops[1, sat.stop] = sat.time
        push!(prev_touched_stops, sat.stop)
    end

    @assert prev_touched_stops.offset == 0
    @assert touched_stops.offset == 0

    # get which service idxes are running (for yesterday today and tomorrow to account for overnight routing)
    services_running = (
        yesterday = BitSet(map(t -> t[1], filter(t -> is_service_running(t[2], date - Day(1)), collect(enumerate(net.services))))),
        today=BitSet(map(t -> t[1], filter(t -> is_service_running(t[2], date), collect(enumerate(net.services))))),
        tomorrow = BitSet(map(t -> t[1], filter(t -> is_service_running(t[2], date + Day(1)), collect(enumerate(net.services)))))
    )


    @debug "$(length(services_running)) services running on requested date"

    # ideally this would have no allocations, although it does have a few due to empty!ing and push!ing to the bitsets - would be nice to have
    # a bounded bitset implementation that did not dynamically resize.
    run_raptor!(net, times_at_stops, non_transfer_times_at_stops, prev_stop, transfer_stop, prev_trip, prev_boardtime, walk_speed_meters_per_second,
        max_transfer_distance_meters, max_rides, services_running, prev_touched_stops, touched_stops)

    return RaptorResult(
        times_at_stops,
        non_transfer_times_at_stops,
        prev_stop,
        transfer_stop,
        prev_trip,
        prev_boardtime,
        date
    )
end

function run_raptor!(net::TransitNetwork, times_at_stops::Array{Int32, 2}, non_transfer_times_at_stops::Array{Int32, 2}, prev_stop::Array{Int64, 2}, transfer_prev_stop,
    prev_trip::Array{Int64, 2}, prev_boardtime::Array{Int32, 2}, walk_speed_meters_per_second, max_transfer_distance_meters, max_rides,
    services_running, prev_touched_stops::BitSet, touched_stops::BitSet)
    for round in 1:max_rides
        # where the results of this round will be recorded
        target = round + 1

        # preinitialize times with times from previous round
        non_transfer_times_at_stops[target, :] = non_transfer_times_at_stops[target - 1, :]

        for stop in prev_touched_stops
            # find all patterns that touch this stop
            # optimization: mark patterns, then loop over patterns instead of stops
            for patidx in net.patterns_for_stop[stop]

                # explore patterns thrice, once for yesterday, today and tomorrow
                tp = net.patterns[patidx]

                for day in (:yesterday, :today, :tomorrow)
                    if tp.service ∉ services_running[day]
                        continue
                    end

                    stop_time_offset = OFFSETS[day]

                    # possible optimization: skip trip patterns that don't run after departure time
                    # (most patterns from yesterday will get skipped)

                    # TODO handle loop trips
                    stoppos = INT_MISSING

                    # not using a vectorized findfirst to avoid allocations
                    for (i, tpstop) in enumerate(tp.stops)
                        if tpstop == stop
                            stoppos = i
                            break
                        end
                    end

                    @assert stoppos != INT_MISSING

                    # find the trip that departs at or after the earliest possible departure
                    # use times_at_stops; allow transfers
                    earliest_departure::Int32 = times_at_stops[target - 1, stop] + BOARD_SLACK_SECONDS
                    best_departure::Int32 = MAX_TIME
                    best_trip_idx::Int64 = INT_MISSING

                    for tripidx in net.trips_for_pattern[patidx]
                        trip = net.trips[tripidx]
                        time_at_stop = trip.stop_times[stoppos].departure_time + stop_time_offset
                        if (time_at_stop >= earliest_departure && time_at_stop < best_departure)
                            best_trip_idx = tripidx
                            best_departure = time_at_stop
                            # pre-sorting trips by departure time would allow us to break here, but I think we found in R5 that it didn't really help
                        end
                    end

                    if best_trip_idx == INT_MISSING
                        continue  # no possible trip to board
                    end

                    best_trip = net.trips[best_trip_idx]

                    for stidx in stoppos + 1:length(best_trip.stop_times)
                        stop_time = best_trip.stop_times[stidx]
                        if stop_time.arrival_time + stop_time_offset < non_transfer_times_at_stops[target, stop_time.stop]
                            # we have found a new fastest way to get to this stop!
                            non_transfer_times_at_stops[target, stop_time.stop] = stop_time.arrival_time + stop_time_offset
                            prev_stop[target, stop_time.stop] = stop
                            prev_trip[target, stop_time.stop] = best_trip_idx
                            prev_boardtime[target, stop_time.stop] = best_trip.stop_times[stoppos].departure_time + stop_time_offset
                            push!(touched_stops, stop_time.stop)
                        end
                    end

                    # possible optimization: if we rode the pattern today, don't check for tomorrow
                    # might need to add some checks to make sure that services are non-overlapping
                    # i.e. there isn't a service from today that starts at 24:30 after the 00:10 service
                    # tomorrow starts. Checking that the hours are always >= 0 and every trip has a first
                    # departure time < 24 would be mostly sufficient - overtaking trips notwithstanding
                    # but that would cut computation roughly in half, so we might be okay with overtaking trips
                    # not working across service days.
                end # today/tomorrow loop
            end
        end # loop over prev_touched_stop

        @debug "round $round found $(length(touched_stops)) stops accessible by transit"

        # clear prev_touched_stops and reuse as next_touched_stops, avoid allocation
        empty!(prev_touched_stops)
        next_touched_stops = prev_touched_stops

        # do transfers, but skip after last iteration
        if round < max_rides
            # don't find transfers to stops that already have better transfers from previous rounds
            # this should not affect routing results, as those transfers would not be optimal in the next
            # round of transit routing, but better to stop it before it happens
            times_at_stops[target, :] = min.(times_at_stops[target - 1, :], non_transfer_times_at_stops[target, :])

            # leave other things missing if there were no transfers
            for stop in touched_stops
                push!(next_touched_stops, stop)  # this stop was touched by this round

                for xfer in net.transfers[stop]
                    if xfer.distance_meters <= max_transfer_distance_meters
                        xfer_walk_time = Base.round(xfer.distance_meters / walk_speed_meters_per_second)
                        pre_xfer_time = non_transfer_times_at_stops[target, stop]
                        time_after_xfer = pre_xfer_time + xfer_walk_time
                        if time_after_xfer < times_at_stops[target, xfer.target_stop]
                            # transferring to this stop is optimal!
                            times_at_stops[target, xfer.target_stop] = time_after_xfer
                            transfer_prev_stop[target, xfer.target_stop] = stop

                            # note that we do _not_ update prev_boardtime, etc here because
                            # those only represent stops reached via transit directly. If we did,
                            # you could run into trouble if you had a scenario where a stop was reached
                            # both via transit and quicker via a transfer, and a second transfer built
                            # on the transit route, and another ride built on the transfer - there would
                            # be no way to trace the trip back for the ride that arrived via transit.
                            push!(next_touched_stops, xfer.target_stop)
                        end
                    end
                end
            end
        end

        # prepare for next iteration
        prev_touched_stops = next_touched_stops
        empty!(touched_stops)
    end
end

