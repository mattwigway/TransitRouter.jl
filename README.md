# TransitRouter.jl

Experimental transit routing in Julia. For now, using the [RAPTOR](http://research.microsoft.com/pubs/156567/raptor_alenex.pdf) algorithm, though other algorithms could be added in the future. Very much thrown together to meet a deadline, but better comments/documentation are planned.

## Usage

### Build a network

From the command line:

    julia build_network.jl out_network.trjl in_gtfs [in_gtfs...]

From Julia:

```julia
network::TransitNetwork = build_network(gtfs_file...)

# save the network for later use
save_network(network, filename)
```

### Route

```julia
network::TransitNetwork = load_network(network_filename)

raptor_reqest = RaptorRequest(
    # These are stops where you could board transit, and what time you could board there. Multiple can be specified,
    # for instance if an external street router were used to get the travel times to a number of nearby stops
    # stop_idx is a numerical index. It can be retrieved from stop IDs using network.stopidx_for_id["filename:stop_id"]
    # note that stop_ids are prefixed with the path of the GTFS file they came from, as specified on the command line
    # or in the arguments to build_network
    [
        StopAndTime(stop_idx::Int64, time_seconds_since_midnight::Int32),
        ...
    ],
    4, # maximum number of rides, e.g. 4 = max 3 transfers
    Date("2021-04-13", "yyyy-mm-dd"), # date of search
    1.33 # walk speed in meters per second
)

raptor_result = raptor(network, raptor_request)
```

`raptor_result` has a number of arrays. The interesting one is `times_at_stops_each_round`; each row represents the result of a RAPTOR round, with the fastest travel time to that stop found in that round (or before that round). It is longer than the number of rounds, because Round 1 is considered the street search and is initialized based on the request, and then each RAPTOR round results in two rows—one for stops reached via transit, and then an additional "transfers" round.

## References
Delling, D., Pajor, T., & Werneck, R. (2012). Round-Based Public Transit Routing. http://research.microsoft.com/pubs/156567/raptor_alenex.pdf