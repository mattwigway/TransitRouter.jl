using Serialization

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
                found_pattern = true
                new_trip = Trip(
                    trip.stop_times,
                    trip.route,
                    trip.service,
                    tpidx
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
        end
    end

    # clear the entire trips array
    deleteat!(net.trips, fill(true, length(net.trips)))
    append!(net.trips, trips_with_patterns)

    @info "created $(length(net.patterns)) trip patterns"
end

# find transfers based on crow-flies distance
function find_transfers_distance!(net::TransitNetwork, max_distance_meters::Real)
    total_transfers = 0
    sizehint!(net.transfers, length(net.stops))
    for stop in net.stops
        # find nearby stops
        # could use a spatial index if this is slow
        lat_diff = meters_to_degrees_lat(max_distance_meters)
        lon_diff = meters_to_degrees_lon(max_distance_meters, stop.stop_lat)

        # bbox query for nearby stops
        candidate_stops = filter(t -> (
            (t[2].stop_lat > stop.stop_lat - lat_diff) &&
            (t[2].stop_lat < stop.stop_lat + lat_diff) &&
            (t[2].stop_lon > stop.stop_lon - lon_diff) &&
            (t[2].stop_lon < stop.stop_lon + lon_diff) &&
            (t[2] !== stop)
            ), collect(enumerate(net.stops)))

        candidate_xfers = map(t -> Transfer(
            t[1],
            distance_meters(stop.stop_lat, stop.stop_lon, t[2].stop_lat, t[2].stop_lon)
        ), candidate_stops)

        # some overselection possible in corners of bbox
        xfers = filter(xfer -> xfer.distance_meters <= max_distance_meters, candidate_xfers)
        total_transfers += length(xfers)
        push!(net.transfers, xfers)
    end

    @assert length(net.transfers) == length(net.stops)

    @info "Created $total_transfers from $(length(net.stops)) stops"
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

function save_network(network::TransitNetwork, filename::String)
    serialize(filename, network)
end

function load_network(filename::String)::TransitNetwork
    return deserialize(filename)
end