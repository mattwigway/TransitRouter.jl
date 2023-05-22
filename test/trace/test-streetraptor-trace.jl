# Test that trace works as intended in StreetRaptor
# The trace implementation in StreetRaptor is a little bit complicated, here's a rundown
# and there are more details at https://projects.indicatrix.org/range-raptor-transfer-compression/
# The gist is that in order to produce optimal trips, we step backwards through departure times
# and retain trips whenever the arrival time at the destination or the number of transfers gets smaller.

# Since this part of trace() only works with StreetRaptor, we use the Santa Barbara OSM data used in the
# StreetRaptor test but create our own network on top of it that looks like this:
#
# Origin -- 1==A==2==F==3--4==I==5 -- Destination
# Route A is a short access leg to route F. It runs as often as F, but is only marginally faster than walking
# trace() should give results that use it, as well as those that walk all the way to 2 (see Figure 3 of the report
# linked above). Rotue F is frequent, every 10 minutes, while route I is infrequent, running only every hour.
# Through RAPTOR transfer compression, we should get only the trips on F that require the minimum wait at I.

@testitem "StreetRaptor trace" begin
    get_routes(path) = map(x -> x.route.route_id, filter(x -> x.type == TransitRouter.transit, path))
    get_transit_times(path) = collect(Iterators.flatten(map(x -> (x.start_time, x.end_time), filter(x -> x.type == TransitRouter.transit, path))))

    include("../test-includes.jl")

    if !success(`which osrm-extract`)
        @warn "Did not find `osrm-extract` in PATH, skipping street RAPTOR tests"
    else
        gtfs = MockGTFS()

        stops = [
            add_stop!(gtfs, 34.412650, -119.866306),
            add_stop!(gtfs, 34.412631, -119.858734),
            add_stop!(gtfs, 34.436223, -119.789674),
            add_stop!(gtfs, 34.436849, -119.789230),
            add_stop!(gtfs, 34.466355, -119.801297)
        ]

        routes = [add_route!(gtfs) for _ in 1:3]

        svc = add_service!(gtfs, 20230101, 20231231; tuesday=false) # avoid finding trips on the next day


        # Route A
        add_trip!(gtfs, routes[1], svc, (
            (stops[1], "8:05:00"),
            (stops[2], "8:05:30")
        ))

        add_trip!(gtfs, routes[1], svc, (
            (stops[1], "9:05:00"),
            (stops[2], "9:05:30")
        ))

        # Route F
        add_trip!(gtfs, routes[2], svc, (
            (stops[2], "8:07:00"),
            (stops[3], "8:35:00")
        ))

        add_trip!(gtfs, routes[2], svc, (
            (stops[2], "8:17:00"),
            (stops[3], "8:45:00")
        ))

        add_trip!(gtfs, routes[2], svc, (
            (stops[2], "8:27:00"),
            (stops[3], "8:55:00")
        ))

        add_trip!(gtfs, routes[2], svc, (
            (stops[2], "8:37:00"),
            (stops[3], "9:05:00")
        ))

        add_trip!(gtfs, routes[2], svc, (
            (stops[2], "8:47:00"),
            (stops[3], "9:15:00")
        ))

        add_trip!(gtfs, routes[2], svc, (
            (stops[2], "8:57:00"),
            (stops[3], "9:25:00")
        ))

        add_trip!(gtfs, routes[2], svc, (
            (stops[2], "9:07:00"),
            (stops[3], "9:35:00")
        ))

        add_trip!(gtfs, routes[2], svc, (
            (stops[2], "9:17:00"),
            (stops[3], "9:45:00")
        ))

        # Route I
        add_trip!(gtfs, routes[3], svc, (
            (stops[4], "8:40:00"),
            (stops[5], "8:55:00")
        ))

        add_trip!(gtfs, routes[3], svc, (
            (stops[4], "9:40:00"),
            (stops[5], "9:55:00")
        ))


        with_gtfs(gtfs) do gtfs_path
            mktempdir() do dir
                Base.Filesystem.cp(artifact"sb_gtfs", joinpath(dir, "data"))

                osm_path = joinpath(dir, "data", "osrm_network", "SBMTD.osm.pbf")
                net_path = joinpath(dir, "data", "osrm_network", "SBMTD.osrm")
                profile_path = joinpath(dir, "data", "osrm_profiles", "foot.lua")

                @info osm_path

                run(`osrm-extract -p $profile_path $osm_path`, wait=true)
                run(`osrm-partition $net_path`, wait=true)
                run(`osrm-customize $net_path`, wait=true)

                osrm = OSRMInstance(net_path, "mld")

                # build the network
                net = build_network([gtfs_path], osrm)

                res = street_raptor(net, osrm, osrm, LatLon(34.4123, -119.8664), [LatLon(34.466354, -119.801296)], DateTime(2023, 5, 22, 7, 55), 4500)

                paths = trace_all_optimal_paths(net, res, 1)

                println(join(Base.show.(Iterators.flatten(paths)), "\n"))
                @test length(paths) == 4

                # First path should be the one-transfer walk to frequent route
                @test get_routes(paths[1]) == routes[2:3]
                @test get_transit_times(paths[1]) == [
                    DateTime(2023, 5, 22, 8, 7),
                    DateTime(2023, 5, 22, 8, 35),
                    DateTime(2023, 5, 22, 8, 40),
                    DateTime(2023, 5, 22, 8, 55)
                ]

                # Second path should be the two-transfer access -> frequent -> infrequent
                # as it allows one to leave a bit later
                @test get_routes(paths[2]) == routes
                @test get_transit_times(paths[2]) == [
                    DateTime(2023, 5, 22, 8, 5),
                    DateTime(2023, 5, 22, 8, 5, 30),
                    DateTime(2023, 5, 22, 8, 7),
                    DateTime(2023, 5, 22, 8, 35),
                    DateTime(2023, 5, 22, 8, 40),
                    DateTime(2023, 5, 22, 8, 55)
                ]

                # Third path should again be the one-transfer walk
                @test get_routes(paths[3]) == routes[2:3]
                @test get_transit_times(paths[3]) == [
                    DateTime(2023, 5, 22, 9, 7),
                    DateTime(2023, 5, 22, 9, 35),
                    DateTime(2023, 5, 22, 9, 40),
                    DateTime(2023, 5, 22, 9, 55)
                ]

                # fourth path should again be the two-transfer access -> frequent -> infrequent
                @test get_routes(paths[4]) == routes
                @test get_transit_times(paths[4]) == [
                    DateTime(2023, 5, 22, 9, 5),
                    DateTime(2023, 5, 22, 9, 5, 30),
                    DateTime(2023, 5, 22, 9, 7),
                    DateTime(2023, 5, 22, 9, 35),
                    DateTime(2023, 5, 22, 9, 40),
                    DateTime(2023, 5, 22, 9, 55)
                ]
            end
        end
    end
end
