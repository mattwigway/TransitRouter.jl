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

# Convert a time that may be yesterday, today, or tomorrow to a time between 0:00 and 23:59:59
# so -3600 would becom 23:00, 87000 would become 00:10, etc.
function ensure_within_day(time)
    while time < 0
        time += SECONDS_PER_DAY
    end

    time % SECONDS_PER_DAY
end

# trace the transit portion of the path
function trace_path(net::TransitNetwork, res::RaptorResult, stop::Int64)
    legs = Vector{Leg}()

    current_stop = stop
    for round in get_last_round(res, stop):-1:2
        # Handle the transit trip

        time_after_round = res.non_transfer_times_at_stops_each_round[round, current_stop]
        prev_stop = res.prev_stop[round, current_stop]
        prev_trip_idx = res.prev_trip[round, current_stop]
        prev_trip_idx != INT_MISSING || error("For stop $current_stop, round $round, no previous trip")
        prev_time = res.prev_boardtime[round, current_stop]
        prev_trip = net.trips[prev_trip_idx]
        # Modulo by seconds_per_day, because of overnight routing. This is not 100% correct but it is unlikely any trip will have stops at the
        # same stop exactly 24 hours apart.
        st1 = findfirst(st -> st.stop == prev_stop && ensure_within_day(st.departure_time) == ensure_within_day(prev_time), prev_trip.stop_times)
        @assert !isnothing(st1)
        st2 = findfirst(st -> st.stop == current_stop && ensure_within_day(st.arrival_time) == ensure_within_day(time_after_round), prev_trip.stop_times)
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
        else
            current_stop = prev_stop
        end

    end

    reverse!(legs)

    return legs, current_stop
end

function get_last_round(res::RaptorResult, dest_stop)
    nrounds = size(res.non_transfer_times_at_stops_each_round, 1)
    # stop not updated, or time same with fewer transfers
    # latter case can occur in a range-RAPTOR search when leaving at (say) 8:05 you can get there at 9:00
    # with three transfers, so this is left in the results, but at 8:02 you can get there at the same time
    # with two transfers - see the many short rides problem https://projects.indicatrix.org/range-raptor-transfer-compression/
    while res.prev_stop[nrounds, dest_stop] == INT_MISSING ||
            nrounds > 1 && res.non_transfer_times_at_stops_each_round[nrounds, dest_stop] == res.non_transfer_times_at_stops_each_round[nrounds - 1, dest_stop]
        nrounds -= 1
    end

    return nrounds
end


Base.show(l::TransitRouter.Leg) = "$(l.type) leg from $(ismissing(l.origin_stop) ? "unnamed location" : l.origin_stop.stop_name) to $(ismissing(l.destination_stop) ? "unnamed location" : l.destination_stop.stop_name) at $(Time(l.start_time))–$(Time(l.end_time)) $(l.type == TransitRouter.transit ? "via route " * coalesce(l.route.route_short_name, l.route.route_long_name) : repr(round(Int64, l.distance_meters)) * " meters")"