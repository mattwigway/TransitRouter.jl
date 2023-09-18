var documenterSearchIndex = {"docs":
[{"location":"raptor/#RAPTOR","page":"RAPTOR","title":"RAPTOR","text":"","category":"section"},{"location":"raptor/","page":"RAPTOR","title":"RAPTOR","text":"The RAPTOR algorithm is implemented by the raptor function","category":"page"},{"location":"raptor/","page":"RAPTOR","title":"RAPTOR","text":"CurrentModule = TransitRouter","category":"page"},{"location":"raptor/","page":"RAPTOR","title":"RAPTOR","text":"RaptorResult","category":"page"},{"location":"raptor/#TransitRouter.RaptorResult","page":"RAPTOR","title":"TransitRouter.RaptorResult","text":"Contains the results of a RAPTOR search.\n\nFields\n\ntimes_at_stops_each_round[i, j] is the earliest time stop j can be reached after round i, whether directly via transit or via a transfer. Round 1 is only has the access stops and times, transit routing first appears in round 2.\nTimes at stops are propagated forward, so a stop reached in round 2 will still be present with the same time in round 3, unless a faster way has been found.\nnon_transfer_times_at_stops_each_round[i, j] is the earliest time stop j can be reached after round i, directly via transit. Round 1 will be blank, as the access leg is considered a transfer, transit routing first appears in round 2.\nNon-transfer times at stops are propagated forward, so a stop reached in round 2 will still be present with the same time in round 3, unless a faster way has been found.\nwalk_distance_meters[i, j] is the walk distance corresponding to the route in timeatstopseachround. Walk distance is used as a tiebreaker when multiple routes get you on the same vehicle.\nnon_transfer_walk_distance_meters[i, j] is similar for the route coresponding to the time in nontransfertimesatstopseachround.\nprev_stop[i, j] is the stop where the passenger boarded the transit vehicle that delivered them to stop j in round i. This only reflects stops reached via transit; if the stop was reached via a transfer, the origin of the transfer will be stored in transfer_prev_stop. transfer_prev_stop and prev_stop may differ, if the stop was reached via transit, but there is a faster way to reach it via a transfer.\nprevstop will contain INTMISSING for a stop not reached in round i, even if it was previously reached.\ntransfer_prev_stop[i, j] is the stop where the passenger alighted from transit vehicle in this round, and then transferred to this stop. This only reflects stops reached via transfers; if the stop was reached via transit directly, the origin will be stored in rev_stop. transfer_prev_stop and prev_stop may differ, if the stop was reached via transit, but there is a faster way to reach it via a transfer.\ntransferprevstop will contain INT_MISSING for a stop not reached in round i, even if it was previously reached.\nprev_trip[i, j] is the trip index of the transit vehicle that delivered the passenger to stop j in round i. Like prev_stop, always refers to stops reached via transit directly, not via transfers. To find the trip that brought a user to a transfer, first look for the transfer origin in transferprevstop, and then look at prev_trip for that stop.\nWill contain INT_MISSING if stop j not reached in round i.\nprev_boardtime[i, j] is the board time index of the transit vehicle that delivered the passenger to stop j in round i. Like prev_stop, always refers to stops reached via transit directly, not via transfers. To find the trip that brought a user to a transfer, first look for the transfer origin in transferprevstop, and then look at prev_trip for that stop.\nWill contain INT_MISSING if stop j not reached in round i.\ndate is the date of the request\n\n\n\n\n\n","category":"type"},{"location":"#TransitRouter.jl","page":"TransitRouter.jl","title":"TransitRouter.jl","text":"","category":"section"},{"location":"#Usage","page":"TransitRouter.jl","title":"Usage","text":"","category":"section"},{"location":"#Build-a-network","page":"TransitRouter.jl","title":"Build a network","text":"","category":"section"},{"location":"","page":"TransitRouter.jl","title":"TransitRouter.jl","text":"From the command line:","category":"page"},{"location":"","page":"TransitRouter.jl","title":"TransitRouter.jl","text":"julia build_network.jl out_network.trjl in_gtfs [in_gtfs...]","category":"page"},{"location":"","page":"TransitRouter.jl","title":"TransitRouter.jl","text":"From Julia:","category":"page"},{"location":"","page":"TransitRouter.jl","title":"TransitRouter.jl","text":"network::TransitNetwork = build_network([gtfs_file, ...])\n\n# save the network for later use\nsave_network(network, filename)","category":"page"},{"location":"","page":"TransitRouter.jl","title":"TransitRouter.jl","text":"The --max-transfer-distance option sets the maximum distance, in meters, that will be allowed for transfer between stops (default 1km).","category":"page"},{"location":"#Routing","page":"TransitRouter.jl","title":"Routing","text":"","category":"section"},{"location":"","page":"TransitRouter.jl","title":"TransitRouter.jl","text":"network::TransitNetwork = load_network(network_filename)\n\nraptor_request = RaptorRequest(\n    # These are stops where you could board transit, and what time you could board there. Multiple can be specified,\n    # for instance if an external street router were used to get the travel times to a number of nearby stops\n    # stop_idx is a numerical index. It can be retrieved from stop IDs using network.stopidx_for_id[\"filename:stop_id\"]\n    # note that stop_ids are prefixed with the path of the GTFS file they came from, as specified on the command line\n    # or in the arguments to build_network\n    [\n        StopAndTime(stop_idx::Int64, time_seconds_since_midnight::Int32),\n        ...\n    ],\n    4, # maximum number of rides, e.g. 4 = max 3 transfers\n    Date(\"2021-04-13\", \"yyyy-mm-dd\"), # date of search\n    1.33 # walk speed in meters per second\n)\n\nraptor_result = raptor(network, raptor_request)","category":"page"},{"location":"","page":"TransitRouter.jl","title":"TransitRouter.jl","text":"raptor_result has a number of arrays. The most interesting one is times_at_stops_each_round; each row represents the result of a RAPTOR round, with the fastest travel time to that stop found in that round (or before that round). It is longer than the number of rounds, because Round 1 is considered the street search and is initialized based on the request, and then each RAPTOR round results in two rows—one for stops reached via transit, and then an additional \"transfers\" round.","category":"page"},{"location":"#Extracting-paths","page":"TransitRouter.jl","title":"Extracting paths","text":"","category":"section"},{"location":"","page":"TransitRouter.jl","title":"TransitRouter.jl","text":"With a RaptorResult (or a StreetRaptorResult, described below), you can call trace_path(result, stop) (or trace_path(result, destination) in the StreetRaptorResult context). This will return a vector of Legs which have members start_time, end_time, origin_stop, destination_stop, type (LegType enum member, transit or transfer), and route. origin_stop, destination_stop, and route are all indexes into network.stops or network.routes if you need to derive more information.","category":"page"},{"location":"#Street-routing","page":"TransitRouter.jl","title":"Street routing","text":"","category":"section"},{"location":"","page":"TransitRouter.jl","title":"TransitRouter.jl","text":"Transit network routing is most usefully combined with street routing, because access, egress, and (most) transfers occur on the street network. Rather than implement a complete street router, TransitRouter.jl uses OSRM (Luxen and Vetter, 2011) to provide street routing, and uses Julia's ccall functionality to call OSRM. Since OSRM is written in C++, TransitRouter.jl includes a very small C++ shim around OSRM with extern \"C\" functions to initialize, route, and shut down an OSRM routing engine. The code for this is in the cxx folder of this repository. ","category":"page"},{"location":"","page":"TransitRouter.jl","title":"TransitRouter.jl","text":"Street routing is entirely optional, and TransitRouter.jl will function just fine without it. Configuring street routing requires a few additional steps, described below.","category":"page"},{"location":"#Building-and-installing-the-C-shim","page":"TransitRouter.jl","title":"Building and installing the C++ shim","text":"","category":"section"},{"location":"","page":"TransitRouter.jl","title":"TransitRouter.jl","text":"The OSRM interface relies on a shared library libosrmjl.so (libosrmjl.dylib on Mac) which contains a shim around OSRM, and is built from the code in the cxx folder. Before you can build libosrmjl, you need to have osrm-backend installed, with libosrm.so, libosrm.dylib, or libosrm.a somewhere in your library path. This may require building osrm-backend from source.","category":"page"},{"location":"","page":"TransitRouter.jl","title":"TransitRouter.jl","text":"Once osrm-backend is installed, in the cxx/build directory, run cmake .. then cmake --build .. If all goes well, there will be no errors, and this will create a file called libosrm.so or libosrm.dylib in the build directory. In order for TransitRouter.jl to find this library, it either needs to be moved into a system-wide library directory (e.g. /usr/local/lib) or Julia needs to be run with the path to the cxx/build in the environment variable LD_LIBRARY_PATH (e.g. \"LD_LIBRARY_PATH=~/TransitRouter.jl/cxx/build/:$LD_LIBRARY_PATH\"\" julia ...).","category":"page"},{"location":"#Building-a-street-network","page":"TransitRouter.jl","title":"Building a street network","text":"","category":"section"},{"location":"","page":"TransitRouter.jl","title":"TransitRouter.jl","text":"Since TransitRouter.jl calls out to OSRM for street routing, an OSRM network will need to be built in order to use street routing. An OSRM network should be prepared using the normal tools from the OSRM project. Instructions for preparing a .osrm file from an OpenStreetMap extract of the area in question are found in OSRM's quick start documentation. The documentation describes using OSRM in Docker, but using OSRM within TransitRouter.jl requires OSRM be installed locally. The instructions translate well if you just remove docker run -t -v \"${PWD}:/data\" osrm/osrm-backend from the start of commands, and pass paths on the local file system.","category":"page"},{"location":"","page":"TransitRouter.jl","title":"TransitRouter.jl","text":"For instance, to build an OSRM network for Southern California using multi-level Dijkstra for use in walk routing, you would run:","category":"page"},{"location":"","page":"TransitRouter.jl","title":"TransitRouter.jl","text":"osrm-extract -p /usr/local/share/osrm/profiles/foot.lua socal-latest.osm.pbf\nosrm-partition socal-latest.osrm\nosrm-customize socal-latest.osrm","category":"page"},{"location":"#Performing-street-transit-routing","page":"TransitRouter.jl","title":"Performing street + transit routing","text":"","category":"section"},{"location":"","page":"TransitRouter.jl","title":"TransitRouter.jl","text":"Street + transit routing is done a little bit differently than transit only routing, as the following example demonstrates. Rather than being stop-based, it is origin-destination based. Note that street + transit routing always requires a transit ride, so travel times to areas very close to the origin (where one would normally just walk) may seem quite high.","category":"page"},{"location":"","page":"TransitRouter.jl","title":"TransitRouter.jl","text":"using TransitRouter\nusing TransitRouter.OSRM\n\nnetwork = load_network(\"path/to/network.trjl\")\nosrm = start_osrm(\"path/to/osrm/network.osrm\")\n\n# somehow get a vector of TransitRouter.OSRM.Coordinate to use as your destinations\n# could come from a CSV, JuliaGeo object, etc.\n# coordinates are lat, lon WGS84\ndestinations = [\n    Coordinate(34.108624, -118.152524), # South Pasadena\n    Coordinate(34.056828, -118.246004), # DTLA\n    Coordinate(34.050271, -118.421021)  # Century City\n]\n\n# this caches the travel times from stops to your destinations\n# with a large number of destinations, this will be slow, but the resulting\n# object can be re-used for multiple origins\n# max_egress_distance_meters is the limit on how far you allow egressing from transit\n# (for example, not walking more than 2km after alighting)\n# the osrm parameter here is used for egressing from transit\ncached_egress_times = find_egress_times(network, osrm, destinations, max_egress_distance_meters)\n\n# perform street + transit routing from a single origin to all destinations\nstreet_raptor_request = StreetRaptorRequest(\n    StreetRaptorRequest(\n        Coordinate(33.938471, -118.242011),  # Origin\n        25200,                               # Departure time from origin, seconds since midnight\n        Date(2018, 01, 08),                  # Date\n        2000,                                # Maximum access distance to first boarding, meters\n        1.33,                                # Walk speed for transfers, meters/second \n                                             # (the user is responsible for making this comparable\n                                             #    to the speeds used in OSRM)\n        4                                    # Maximum number of transit rides\n    )\n)\n\n# run the request. the osrm parameter here is used for the access portion of the search. it can\n# differ from the osrm parameter used in find_egress_times, for instance for a drive-to-transit\n# search where a driving osrm network would be used here, and a walking network used for egress\n# (this is the -p option to osrm-extract, see\n#   https://github.com/Project-OSRM/osrm-backend/blob/master/docs/profiles.md)\nstreet_raptor_result = street_raptor(network, osrm, street_raptor_request, cached_egress_times)\n\n# this frees the memory used by the OSRM server, which is allocated outside the purview of the\n# Julia garbage collector.\nstop_osrm!(osrm)","category":"page"},{"location":"","page":"TransitRouter.jl","title":"TransitRouter.jl","text":"street_raptor_result contains an array times_at_destinations, the original request, the raptor_result from the transit portion of the search, and egress_stop_for_destination which records which stop was used to get to the destination.","category":"page"},{"location":"","page":"TransitRouter.jl","title":"TransitRouter.jl","text":"As with a RaptorResult, you can run trace_path(street_raptor_result, destination_index) and get a list of the legs used to get to the destination destination_index (note that unlike when tracing a RaptorResult, this is a destination index, not a stop index). The output will be identical to tracing a RaptorResult, but will include access and egress legs.","category":"page"},{"location":"#Using-the-street-network-for-transfers","page":"TransitRouter.jl","title":"Using the street network for transfers","text":"","category":"section"},{"location":"","page":"TransitRouter.jl","title":"TransitRouter.jl","text":"Transfer distances are precomputed when the network is built. By default they are based on straight-line differences, but by passing a -n path/to/osrm/network.osrm option to build_network.jl, or calling build_network() with a second parameter that is an OSRM object created start_osrm, OSRM will be used to compute network distances for transfers.","category":"page"},{"location":"#References","page":"TransitRouter.jl","title":"References","text":"","category":"section"},{"location":"","page":"TransitRouter.jl","title":"TransitRouter.jl","text":"Delling, D., Pajor, T., & Werneck, R. (2012). Round-Based Public Transit Routing. http://research.microsoft.com/pubs/156567/raptor_alenex.pdf","category":"page"},{"location":"","page":"TransitRouter.jl","title":"TransitRouter.jl","text":"Luxen, D., & Vetter, C. (2011). Real-time routing with OpenStreetMap data. Proceedings of the 19th ACM SIGSPATIAL International Conference on Advances in Geographic Information Systems - GIS ’11, 513. https://doi.org/10.1145/2093973.2094062","category":"page"}]
}
