# Contains the implementation of range-RAPTOR from Delling, Pajor, and Werneck
"""
This function performs a range-RAPTOR search, as described in Delling, Pajor, and Werneck (called rRAPTOR in that paper). See also
Conway, Byrd, and van der Linden (2016) for a non-mathematical explanation (note that we do not currently implement the mini-search over
frequencies described in that paper).

Basically, range-RAPTOR involves running a RAPTOR search repeatedly at a regular interval over a time window. To make this
efficient, the first search is conducted at the end of the time window. Subsequent searches each start a fixed amount earlier
than the last, and use the already-found routes from the previous (computationally)/next (chronologically) search as an upper
bound on the routes (i.e. a dynamic programming approach). The intuition is that waiting one minute is always an option, so any
trip that would arrive later than the trip one minute later is nonoptimal by definition.

This function returns a vector of RaptorResults, one for each departure time, in chronological order (i.e. earliest departure first,
reversed from the direction they were found). Note that the results will not be identical to those that you would get by simply running
raptor() repeatedly, because the trips are found in a different order. When running a single-departure-time RAPTOR search, we board the
first vehicle that can get you to the destination, with ties broken by walking distance and then arbitrarily (technically, by the order of
patterns in the network, which is related to the order of trips in the GTFS). However, with range-RAPTOR, if there are two routes to the
destination that get you there at the same time _but that use different stops_, the one that leaves later will be found first, and will dominate
the one that leaves earlier.

For this reason, the best/most reasonable trips that people are actually likely to take are produced by a range-RAPTOR search that's run
for some time past the desired end of the time window. Suppose the end of the time window was 2pm, and there are buses at 2:10 and 2:30 that
both connect to an infrequent bus to your destination. Most people will choose to wait to take the 2:30 bus, as waiting at the origin
is likely more comfortable than waiting at the transfer point. If you ran a single iteration of RAPTOR at 2:00, you would board the 2:10 bus.
However, if you start range-RAPTOR at 3, and run back to 2, you'll find the 2:30 bus, and since it gets you to the destination at
the same time as the 2:10 bus, it will be preserved. For this reason, this function uses a "burn-in period" past the end of the requested
time period (1 hour by default).

Some post-routing filtering is still necessary even after a range-RAPTOR search. The range-RAPTOR results contain the fastest times to each stop. If
an earlier departure leads to a faster travel time to an intermediate stop, even if the travel time to the destination is the same, the earler range-RAPTOR
results will reflect that. Callers should return the route from the latest departure time that gets you to the destination at the same time as the earliest
departure.

The origins should have the time the stop is reached at the earliest departure time, the code will adjust them later as needed for later
departure times.
"""
function range_raptor(origins::Vector{StopAndTime}, net::TransitNetwork, date::Date, time_window_length_seconds::Integer, step_size_seconds=SECONDS_PER_MINUTE; kwargs...)
    results = RaptorResult[]
    # run raptor with a function that runs after each minute of the search and
    # copies the result into our RaptorResult array.
    raptor(net, date; kwargs...) do result, offset
        # save results of this departure time
        if !isnothing(result) && offset ≤ time_window_length_seconds
            push!(results, deepcopy(result))
        end

        # step backward to earlier departure time, initialize on first iteration
        offset = isnothing(offset) ? time_window_length_seconds : offset

        if offset < 0
            # end the range-raptor search
            return nothing
        end

        access_stops = map(sat -> StopAndTime(sat.stop, sat.time + offset, sat.walk_distance_meters), origins)

        offset -= step_size_seconds

        return access_stops, offset
    end

    reverse!(results)

    return results
end

"""
This is a variant of range-RAPTOR where the time window length is not prespecified. Rather, the search continues
until stopping_function(raptor_result) is true. This is used to implement reverse searches where we continue backwards until we find a
path to the destination(s) that arrives before the requested time. origins should have times set based on leaving the origin at the desired arrival
time.
"""
function range_raptor(stopping_function::Function, origins::Vector{StopAndTime}, net::TransitNetwork, date::Date, step_size_seconds=SECONDS_PER_MINUTE; kwargs...)
    results = RaptorResult[]
    # run raptor with a function that runs after each minute of the search and
    # copies the result into our RaptorResult array.
    raptor(net, date; kwargs...) do result, offset
        # save results of this departure time
        if !isnothing(result)
            push!(results, deepcopy(result))

            if stopping_function(result, offset)
                return nothing
            end
        end

        # step backward to earlier departure time, initialize on first iteration
        offset = isnothing(offset) ? 0 : offset

        access_stops = map(sat -> StopAndTime(sat.stop, sat.time + offset, sat.walk_distance_meters), origins)

        offset -= step_size_seconds

        return access_stops, offset
    end

    reverse!(results)

    return results
end