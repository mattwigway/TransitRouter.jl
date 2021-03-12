# TransitRouter.jl

Experimental transit routing in Julia. For now, using the [RAPTOR](http://research.microsoft.com/pubs/156567/raptor_alenex.pdf) algorithm, though other algorithms could be added in the future. Very much thrown together to meet a deadline, but better comments/documentation are planned.

## Usage

### Build a network

From the command line:

    julia build_network.jl out_network.trjl in_gtfs [in_gtfs...]

From Julia:

```julia
network::TransitNetwork = build_network([gtfs_file, ...])

# save the network for later use
save_network(network, filename)
```

The `--max-transfer-distance` option sets the maximum distance, in meters, that will be allowed for transfer between stops (default 1km).

### Routing

```julia
network::TransitNetwork = load_network(network_filename)

raptor_request = RaptorRequest(
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

`raptor_result` has a number of arrays. The most interesting one is `times_at_stops_each_round`; each row represents the result of a RAPTOR round, with the fastest travel time to that stop found in that round (or before that round). It is longer than the number of rounds, because Round 1 is considered the street search and is initialized based on the request, and then each RAPTOR round results in two rows—one for stops reached via transit, and then an additional "transfers" round.

### Extracting paths

With a `RaptorResult` (or a `StreetRaptorResult`, described below), you can call `trace_path(result, stop)` (or `trace_path(result, destination)` in the `StreetRaptorResult` context). This will return a vector of `Leg`s which have members `start_time`, `end_time`, `origin_stop`, `destination_stop`, `type` (`LegType` enum member, `transit` or `transfer`), and `route`. `origin_stop`, `destination_stop`, and `route` are all indexes into `network.stops` or `network.routes` if you need to derive more information.

### Street routing

Transit network routing is most usefully combined with street routing, because access, egress, and (most) transfers occur on the street network. Rather than implement a complete street router, TransitRouter.jl uses [OSRM](http://project-osrm.org) (Luxen and Vetter, 2011) to provide street routing, and uses Julia's `ccall` functionality to call OSRM. Since OSRM is written in C++, TransitRouter.jl includes a very small C++ shim around OSRM with `extern "C"` functions to initialize, route, and shut down an OSRM routing engine. The code for this is in the `cxx` folder of this repository. 

Street routing is entirely optional, and TransitRouter.jl will function just fine without it. Configuring street routing requires a few additional steps, described below.

#### Building and installing the C++ shim

The OSRM interface relies on a shared library `libosrmjl.so` (`libosrmjl.dylib` on Mac) which contains a shim around OSRM, and is built from the code in the `cxx` folder. Before you can build `libosrmjl`, you need to have [osrm-backend](https://github.com/Project-OSRM/osrm-backend) installed, with `libosrm.so`, `libosrm.dylib`, or `libosrm.a` somewhere in your library path. This may require building `osrm-backend` from source.

Once `osrm-backend` is installed, in the `cxx/build` directory, run `cmake ..` then `cmake --build .`. If all goes well, there will be no errors, and this will create a file called `libosrm.so` or `libosrm.dylib` in the build directory. In order for TransitRouter.jl to find this library, it either needs to be moved into a system-wide library directory (e.g. `/usr/local/lib`) or Julia needs to be run with the path to the `cxx/build` in the environment variable `LD_LIBRARY_PATH` (e.g. `"LD_LIBRARY_PATH=~/TransitRouter.jl/cxx/build/:$LD_LIBRARY_PATH"" julia ...`).

#### Building a street network

Since TransitRouter.jl calls out to OSRM for street routing, an OSRM network will need to be built in order to use street routing. An OSRM network should be prepared using the normal tools from the OSRM project. Instructions for preparing a `.osrm` file from an OpenStreetMap extract of the area in question are found in [OSRM's quick start documentation](https://github.com/Project-OSRM/osrm-backend#quick-start). The documentation describes using OSRM in Docker, but using OSRM within TransitRouter.jl requires OSRM be installed locally. The instructions translate well if you just remove `docker run -t -v "${PWD}:/data" osrm/osrm-backend` from the start of commands, and pass paths on the local file system.

For instance, to build an OSRM network for Southern California using multi-level Dijkstra for use in walk routing, you would run:

```
osrm-extract -p /usr/local/share/osrm/profiles/foot.lua socal-latest.osm.pbf
osrm-partition socal-latest.osrm
osrm-customize socal-latest.osrm
```

#### Performing street + transit routing

Street + transit routing is done a little bit differently than transit only routing, as the following example demonstrates. Rather than being stop-based, it is origin-destination based. Note that street + transit routing always requires a transit ride, so travel times to areas very close to the origin (where one would normally just walk) may seem quite high.

```julia
using TransitRouter
using TransitRouter.OSRM

network = load_network("path/to/network.trjl")
osrm = start_osrm("path/to/osrm/network.osrm")

# somehow get a vector of TransitRouter.OSRM.Coordinate to use as your destinations
# could come from a CSV, JuliaGeo object, etc.
# coordinates are lat, lon WGS84
destinations = [
    Coordinate(34.108624, -118.152524), # South Pasadena
    Coordinate(34.056828, -118.246004), # DTLA
    Coordinate(34.050271, -118.421021)  # Century City
]

# this caches the travel times from stops to your destinations
# with a large number of destinations, this will be slow, but the resulting
# object can be re-used for multiple origins
# max_egress_distance_meters is the limit on how far you allow egressing from transit
# (for example, not walking more than 2km after alighting)
# the osrm parameter here is used for egressing from transit
cached_egress_times = find_egress_times(network, osrm, destinations, max_egress_distance_meters)

# perform street + transit routing from a single origin to all destinations
street_raptor_request = StreetRaptorRequest(
    StreetRaptorRequest(
        Coordinate(33.938471, -118.242011),  # Origin
        25200,                               # Departure time from origin, seconds since midnight
        Date(2018, 01, 08),                  # Date
        2000,                                # Maximum access distance to first boarding, meters
        1.33,                                # Walk speed for transfers, meters/second 
                                             # (the user is responsible for making this comparable
                                             #    to the speeds used in OSRM)
        4                                    # Maximum number of transit rides
    )
)

# run the request. the osrm parameter here is used for the access portion of the search. it can
# differ from the osrm parameter used in find_egress_times, for instance for a drive-to-transit
# search where a driving osrm network would be used here, and a walking network used for egress
# (this is the -p option to osrm-extract, see
#   https://github.com/Project-OSRM/osrm-backend/blob/master/docs/profiles.md)
street_raptor_result = street_raptor(network, osrm, street_raptor_request, cached_egress_times)

# this frees the memory used by the OSRM server, which is allocated outside the purview of the
# Julia garbage collector.
stop_osrm!(osrm)
```

`street_raptor_result` contains an array `times_at_destinations`, the original `request`, the `raptor_result` from the transit portion of the search, and `egress_stop_for_destination` which records which stop was used to get to the destination.

As with a `RaptorResult`, you can run `trace_path(street_raptor_result, destination_index)` and get a list of the legs used to get to the destination `destination_index` (note that unlike when tracing a `RaptorResult`, this is a destination index, not a stop index). The output will be identical to tracing a `RaptorResult`, but will include `access` and `egress` legs.

#### Using the street network for transfers

Transfer distances are precomputed when the network is built. By default they are based on straight-line differences, but by passing a `-n path/to/osrm/network.osrm` option to `build_network.jl`, or calling `build_network()` with a second parameter that is an OSRM object created `start_osrm`, OSRM will be used to compute network distances for transfers.

## References

Delling, D., Pajor, T., & Werneck, R. (2012). Round-Based Public Transit Routing. http://research.microsoft.com/pubs/156567/raptor_alenex.pdf

Luxen, D., & Vetter, C. (2011). Real-time routing with OpenStreetMap data. Proceedings of the 19th ACM SIGSPATIAL International Conference on Advances in Geographic Information Systems - GIS ’11, 513. https://doi.org/10.1145/2093973.2094062
