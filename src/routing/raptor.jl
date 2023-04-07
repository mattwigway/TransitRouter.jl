# RAPTOR: Round-Based Public Transit Optimized Routing
# Described in Delling, D., Pajor, T., & Werneck, R. (2012). Round-Based Public Transit Routing. http://research.microsoft.com/pubs/156567/raptor_alenex.pdf

const MAX_TIME = typemax(Int32)
const XFER_ROUTE = -1
const INT_MISSING = -2
const ORIGIN = -3
const BOARD_SLACK_SECONDS = 60
const EMPTY_SET = BitSet()

struct StopAndTime
    stop::Int64
    time::Int32
end

struct RaptorRequest
    origins::Vector{StopAndTime}
    max_rides::Int64
    date::Date
    walk_speed_meters_per_second::Float64
end

struct RaptorResult
    times_at_stops_each_round::Array{Int32, 2}
    prev_stop::Array{Int64, 2}
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
    # * 2 for transfer rounds, + 1 for origin times, -1 for skipped final transfer round
    nrounds = max_rides * 2 + 1 - 1

    # these get allocated here, and the core RAPTOR algorithm should have 0 allocations
    times_at_stops::Array{Int32,2} = fill(MAX_TIME, (nrounds, nstops))
    prev_stop::Array{Int64,2} = fill(INT_MISSING, (nrounds, nstops))
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

    # get which service idxes are running
    services_running = BitSet(map(t -> t[1], filter(t -> is_service_running(t[2], date), collect(enumerate(net.services)))))

    @debug "$(length(services_running)) services running on requested date"

    # ideally this would have no allocations, although it does have a few due to empty!ing and push!ing to the bitsets - would be nice to have
    # a bounded bitset implementation that did not dynamically resize.
    run_raptor!(net, times_at_stops, prev_stop, prev_trip, prev_boardtime, walk_speed_meters_per_second,
        max_transfer_distance_meters, max_rides, services_running, prev_touched_stops, touched_stops)

    return RaptorResult(
        times_at_stops,
        prev_stop,
        prev_trip,
        prev_boardtime,
        date
    )
end

function run_raptor!(net::TransitNetwork, times_at_stops::Array{Int32, 2}, prev_stop::Array{Int64, 2},
    prev_trip::Array{Int64, 2}, prev_boardtime::Array{Int32, 2}, walk_speed_meters_per_second, max_transfer_distance_meters, max_rides, services_running::BitSet, prev_touched_stops::BitSet, touched_stops::BitSet)
    for round in 1:max_rides
        # where the results of this round will be recorded
        target = round * 2

        # preinitialize times with times from previous round
        times_at_stops[target, :] = times_at_stops[target - 1, :]

        for stop in prev_touched_stops
            # find all patterns that touch this stop
            for patidx in net.patterns_for_stop[stop]
                tp = net.patterns[patidx]

                if !in(tp.service, services_running)
                    continue
                end

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
                earliest_departure::Int32 = times_at_stops[target - 1, stop] + BOARD_SLACK_SECONDS
                best_departure::Int32 = MAX_TIME
                best_trip_idx::Int64 = INT_MISSING

                for tripidx in net.trips_for_pattern[patidx]
                    trip = net.trips[tripidx]
                    time_at_stop = trip.stop_times[stoppos].departure_time
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
                    if stop_time.arrival_time < times_at_stops[target, stop_time.stop]
                        # we have found a new fastest way to get to this stop!
                        times_at_stops[target, stop_time.stop] = stop_time.arrival_time
                        prev_stop[target, stop_time.stop] = stop
                        prev_trip[target, stop_time.stop] = best_trip_idx
                        prev_boardtime[target, stop_time.stop] = best_trip.stop_times[stoppos].departure_time
                        push!(touched_stops, stop_time.stop)
                    end
                end
            end
        end # loop over prev_touched_stop

        @debug "round $round found $(length(touched_stops)) stops accessible by transit"

        # clear prev_touched_stops and reuse as next_touched_stops, avoid allocation
        empty!(prev_touched_stops)
        next_touched_stops = prev_touched_stops

        # do transfers, but skip after last iteration
        if round < max_rides
            times_at_stops[target + 1, :] = times_at_stops[target, :]
            # leave other things missing if there were no transfers
            for stop in touched_stops
                push!(next_touched_stops, stop)  # this stop was touched by this round

                for xfer in net.transfers[stop]
                    if xfer.distance_meters <= max_transfer_distance_meters
                        xfer_walk_time = Base.round(xfer.distance_meters / walk_speed_meters_per_second)
                        pre_xfer_time = times_at_stops[target, stop]
                        time_after_xfer = pre_xfer_time + xfer_walk_time
                        if time_after_xfer < times_at_stops[target + 1, xfer.target_stop]
                            # transferring to this stop is optimal!
                            times_at_stops[target + 1, xfer.target_stop] = time_after_xfer
                            prev_stop[target + 1, xfer.target_stop] = stop
                            prev_trip[target + 1, xfer.target_stop] = XFER_ROUTE
                            prev_boardtime[target + 1, stop] = pre_xfer_time
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

