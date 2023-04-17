struct TransitNetwork
    stops::Vector{Stop}
    stopidx_for_id::Dict{String,Int64}

    routes::Vector{Route}
    routeidx_for_id::Dict{String, Int64}

    services::Vector{Service}
    serviceidx_for_id::Dict{String, Int64}

    trips::Vector{Trip}
    tripidx_for_id::Dict{String, Int64}

    patterns::Vector{TripPattern}
    
    # todo could this have less indirection?
    transfers::Vector{Vector{Transfer}}

    # NB could also put this inside stop and pattern structs, but would prevent stop packing
    patterns_for_stop::Vector{Vector{Int64}}
    trips_for_pattern::Vector{Vector{Int64}}
end

TransitNetwork() = TransitNetwork(
    Vector{Stop}(),
    Dict{String,Int64}(),
    Vector{Route}(),
    Dict{String,Int64}(),
    Vector{Service}(),
    Dict{String,Int64}(),
    Vector{Trip}(),
    Dict{String,Int64}(),
    Vector{TripPattern}(),
    Vector{Vector{Transfer}}(),
    Vector{Vector{Int64}}(),
    Vector{Vector{Int64}}()
    )

# ensure that stop times are ordered by stop stop_sequence in each trip
function sort_stoptimes!(net::TransitNetwork)
    for trip in net.trips
        sort!(trip.stop_times, by=st -> st.stop_sequence)
    end
end

function hash_tp(stop_times::Vector{StopTime}, service::Int64)
    hash::Int64 = 0

    for (i, st) in enumerate(stop_times)
        hash += st.stop * primes[i % length(primes)]
    end

    hash += service * primes[length(primes)]

    return hash
end


# create trip patterns
function find_trip_patterns!(net::TransitNetwork)
    # maps from trip pattern hash to trip patterns with that hash
    tp_hashes = Dict{Int64, Vector{Tuple{Int64, TripPattern}}}()

    trips_with_patterns = Vector{Trip}()
    sizehint!(trips_with_patterns, length(net.trips))
   
    for trip in net.trips
        hash = hash_tp(trip.stop_times, trip.service)
        if !haskey(tp_hashes, hash)
            tp_hashes[hash] = Vector{Tuple{Int64, TripPattern}}()
        end

        stops::Vector{Int64} = map(st -> st.stop, trip.stop_times)

        # check for a matching trip pattern
        found_pattern = false
        for (tpidx, tp) in tp_hashes[hash]
            # short circuit and means vector equality won't be tested unless vectors are same length
            if ((tp.service == trip.service) && length(tp.stops) == length(stops) && all(tp.stops .== stops))
                @assert !found_pattern "Found multiple matching patterns (internal error)"
                found_pattern = true
                new_trip = Trip(
                    trip.stop_times,
                    trip.route,
                    trip.service,
                    tpidx,
                    trip.shape
                )
                push!(trips_with_patterns, new_trip)
            end
        end

        if !found_pattern
            # create a new trip pattern
            tp = TripPattern(stops, trip.service)
            push!(net.patterns, tp)
            tpidx = length(net.patterns)
            push!(tp_hashes[hash], (tpidx, tp))
            
            new_trip = Trip(
                trip.stop_times,
                trip.route,
                trip.service,
                tpidx,
                trip.shape
            )
            push!(trips_with_patterns, new_trip)
        end
    end

    @assert length(net.trips) == length(trips_with_patterns)
    # clear the entire trips array
    empty!(net.trips)
    append!(net.trips, trips_with_patterns)

    @info "created $(length(net.patterns)) trip patterns"
end

# find transfers based on crow-flies distance
function find_transfers_distance!(net::TransitNetwork, max_distance_meters::Real)
    empty!(net.transfers)
    total_transfers = 0

    # first, find all candidate transfers. We'll repeat the routing with each one to get a geometry.
    stoplocs = map(s -> LatLon(s.stop_lat, s.stop_lon), net.stops)
    @info "..Finding crow-flies stop-to-stop distances"
    # initialize the diagonal to true, everything else will be overwritten
    # also, if somehow we mess up below and it's not, we'll still get the right transfers
    # because we'll check for transfers that don't exist, rather than not checking for transfers that do
    stop_to_stop_dists = ones(Float64, (length(stoplocs), length(stoplocs)))
    Threads.@threads for i in ProgressBar(1:length(stoplocs)) # normally frowned upon to index arrays like this but we controls stops/stoplocs
        for j in (i + 1):length(stoplocs)
            dist = euclidean_distance(stoplocs[i], stoplocs[j])
            stop_to_stop_dists[i, j] = dist
            stop_to_stop_dists[j, i] = dist
        end
    end

    for i in 1:length(net.stops)
        istop = net.stops[i]
        stop_transfers = Transfer[]
        for j in 1:length(net.stops)
            if i != j && stop_to_stop_dists[i, j] ≤ max_distance_meters
                jstop = net.stops[j]
                push!(stop_transfers, Transfer(j, stop_to_stop_dists[i, j], stop_to_stop_dists[i, j] / DEFAULT_WALK_SPEED_METERS_PER_SECOND, [
                    LatLon(istop.stop_lat, istop.stop_lon),
                    LatLon(jstop.stop_lat, jstop.stop_lon)
                ]))
                total_transfers += 1
            end
        end
        push!(net.transfers, stop_transfers)
    end

    @assert length(net.transfers) == length(net.stops)

    @info "Created $total_transfers transfers from $(length(net.stops)) stops"
end

# Find transfers through the street network using OSRM
function find_transfers_osrm!(net::TransitNetwork, osrm::OSRMInstance, max_distance_meters::Real)
    empty!(net.transfers)
    total_transfers = 0

    # first, find all candidate transfers. We'll repeat the routing with each one to get a geometry.
    stoplocs = map(s -> LatLon(s.stop_lat, s.stop_lon), net.stops)
    @info "..Finding crow-flies stop-to-stop distances"
    # initialize the diagonal to true, everything else will be overwritten
    # also, if somehow we mess up below and it's not, we'll still get the right transfers
    # because we'll check for transfers that don't exist, rather than not checking for transfers that do
    stop_to_stop_possible = ones(Bool, (length(stoplocs), length(stoplocs)))
    Threads.@threads for i in ProgressBar(1:length(stoplocs)) # normally frowned upon to index arrays like this but we controls stops/stoplocs
        for j in (i + 1):length(stoplocs)
            dist = euclidean_distance(stoplocs[i], stoplocs[j]) ≤ max_distance_meters
            stop_to_stop_possible[i, j] = dist
            stop_to_stop_possible[j, i] = dist
        end
    end

    @info "..Finding stop-to-stop geometries"
    p = ProgressBar(total=length(net.stops))
    transfers = ThreadsX.map(collect(enumerate(net.stops))) do (stopidx, stop)
        # bbox query for nearby stops
        candidate_stops = findall(stop_to_stop_possible[stopidx, :])

        xfers = Vector{Transfer}()

        for dest_stopidx in candidate_stops
            if dest_stopidx == stopidx
                continue
            end
            
            dest_stop = net.stops[dest_stopidx]
            # convert the index in destinations back to the index in net.stops
            rs = route(osrm, LatLon(stop.stop_lat, stop.stop_lon), LatLon(dest_stop.stop_lat, dest_stop.stop_lon))
            rt = first(rs)

            if rt.distance_meters ≤ max_distance_meters
                push!(xfers, Transfer(dest_stopidx, rt.distance_meters, rt.duration_seconds, rt.geometry))
            end
        end

        # update is threadsafe, I checked
        update(p)
        return xfers
    end

    for transfer in transfers
        push!(net.transfers, transfer)
        total_transfers += length(transfer)
    end

    @assert length(net.transfers) == length(net.stops)
    @info "Created $total_transfers transfers from $(length(net.stops)) stops"
end

function index_network!(net::TransitNetwork)
    # first, patterns for stops
    sizehint!(net.patterns_for_stop, length(net.stops))
    for stop in net.stops
        push!(net.patterns_for_stop, Vector{Int64}())
    end

    for (i, pattern) in enumerate(net.patterns)
        for stop in pattern.stops
            push!(net.patterns_for_stop[stop], i)
        end
    end

    # now, trips for pattern
    sizehint!(net.trips_for_pattern, length(net.patterns))
    for pattern in net.patterns
        push!(net.trips_for_pattern, Vector{Int64}())
    end

    for (i, trip) in enumerate(net.trips)
        push!(net.trips_for_pattern[trip.pattern], i)
    end
end

function _interpolate_segment_times(net::TransitNetwork, stop_times::Vector{StopTime})::Vector{StopTime}
    first_time = stop_times[1].departure_time
    last_time = stop_times[length(stop_times)].arrival_time
    
    distances = Vector{Float64}()
    sizehint!(distances, length(stop_times) - 1)

    for i in 1:(length(stop_times) - 1)
        fr = net.stops[stop_times[i].stop]
        to = net.stops[stop_times[i + 1].stop]
        push!(distances, euclidean_distance(
            LatLon(fr.stop_lat, fr.stop_lon),
            LatLon(to.stop_lat, to.stop_lon)
        ))
    end

    distfrac = cumsum(distances) ./ sum(distances)

    timedelta = last_time - first_time

    new_stop_times = Vector{StopTime}()
    sizehint!(new_stop_times, length(stop_times))
    push!(new_stop_times, stop_times[1])

    for i in 2:(length(stop_times) - 1)
        interp_time::Int32 = first_time + round(distfrac[i - 1] * timedelta)
        push!(new_stop_times, StopTime(
            stop_times[i].stop,
            stop_times[i].stop_sequence,
            interp_time,
            interp_time,
            stop_times[i].shape_dist_traveled
        ))
    end

    push!(new_stop_times, stop_times[length(stop_times)])

    @assert length(stop_times) == length(new_stop_times)

    return new_stop_times
end

function interpolate_stoptimes!(net::TransitNetwork)
    for trip in net.trips
        last_bona_fide_stidx = 0
        # collect should avoid concurrent modification issues
        for (i, st) in collect(enumerate(trip.stop_times))
            is_bona_fide_stidx = false
            if (st.arrival_time == INT_MISSING && st.departure_time != INT_MISSING)
                st.arrival_time = st.departure_time
                is_bona_fide_stidx = true
            elseif (st.departure_time == INT_MISSING && st.arrival_time != INT_MISSING)
                st.departure_time = st.arrival_time
                is_bona_fide_stidx = true
            elseif (st.departure_time != INT_MISSING && st.arrival_time != INT_MISSING)
                # do nothing, continue to accumulate
                is_bona_fide_stidx = true
            end

            if is_bona_fide_stidx
                if last_bona_fide_stidx != i - 1
                    trip.stop_times[last_bona_fide_stidx:i] = _interpolate_segment_times(net, trip.stop_times[last_bona_fide_stidx:i])
                end
                last_bona_fide_stidx = i
            end
        end

        # check our work
        @assert all(diff(map(st -> st.arrival_time, trip.stop_times)) .>= 0)
        @assert all(diff(map(st -> st.departure_time, trip.stop_times)) .>= 0)
    end
end

function save_network(network::TransitNetwork, filename::String)
    serialize(filename, network)
end

function load_network(filename::String)::TransitNetwork
    return deserialize(filename)
end