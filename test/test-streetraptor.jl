@testitem "StreetRaptor" begin
    include("test-includes.jl")
    # define some custom isequal types so snapshot testing works
    @struct_isequal TransitRouter.Transfer
    @struct_isequal TransitRouter.RaptorResult
    @struct_isequal TransitRouter.AccessEgress
    @struct_isequal TransitRouter.Leg

    function Base.show(io::IO, l::TransitRouter.Leg)
        println(io, "$(l.type != TransitRouter.access ? "  " : "")$(l.type) leg from $(ismissing(l.origin_stop) ? "missing" : l.origin_stop.stop_id)@$(l.start_time) to $(ismissing(l.destination_stop) ? "missing" : l.destination_stop.stop_id)@$(l.end_time) via route $(ismissing(l.route) ? "none" : l.route.route_short_name) ($(l.distance_meters)m)")
    end

    # tests for streetraptor
    # don't run if OSRM binaries not available (currently not available on CI)
    if !success(`which osrm-extract`)
        @warn "Did not find `osrm-extract` in PATH, skipping street RAPTOR tests"
    else
        @info "Building OSRM graph for street routing tests"

        # copy artifact to temp dir
        mktempdir() do dir
            Base.Filesystem.cp(artifact"sb_gtfs", joinpath(dir, "data"))

            osm_path = joinpath(dir, "data", "osrm_network", "SBMTD.osm.pbf")
            net_path = joinpath(dir, "data", "osrm_network", "SBMTD.osrm")
            gtfs_path = joinpath(dir, "data", "feed.zip")
            profile_path = joinpath(dir, "data", "osrm_profiles", "foot.lua")

            @info osm_path

            run(`osrm-extract -p $profile_path $osm_path`, wait=true)
            run(`osrm-partition $net_path`, wait=true)
            run(`osrm-customize $net_path`, wait=true)

            osrm = OSRMInstance(net_path, "mld")

            # build the network
            net = build_network([gtfs_path], osrm)

            # check the transfer from Hitchcock and State to State and Hitchcock
            s1 = net.stopidx_for_id["$gtfs_path:266"]
            s2 = net.stopidx_for_id["$gtfs_path:176"]
            
            transfer = filter(t -> t.target_stop == s2, net.transfers[s1])
            @test length(transfer) == 1
            @snapshot_test "state_hitchcock_transfer" transfer

            # Origin is UCSB, destination is downtown and eastside
            res = street_raptor(net, osrm, osrm, LatLon(34.4128, -119.8487), [LatLon(34.4224, -119.7032), LatLon(34.4226, -119.6777)], DateTime(2023, 5, 10, 8, 0), 3600)
            @snapshot_test "streetrouter_result" res
            
            # now, something different - none of the routes presented above use a transfer.
            # now, origin is the transit center, destination is off Winchester Cyn Blvd in Goleta
            xferres = street_raptor(net, osrm, osrm, LatLon(34.4224, -119.7032), [LatLon(34.4360, -119.8973)], DateTime(2023, 5, 10, 8, 0))
            @snapshot_test "streetrouter_xfer_result" xferres

            # We also test reverse routing here. We do the same trip as the first two above, but make sure that we find a route that arrives
            # at the destination before the requested departure time.
            revres = street_raptor(net, osrm, osrm, LatLon(34.4128, -119.8487), [LatLon(34.4224, -119.7032), LatLon(34.4226, -119.6777)], DateTime(2023, 5, 10, 8, 0);
                reverse_search=true, max_reverse_search_duration=7200)
            @snapshot_test "reverse_street_raptor" revres

            # make sure it doesn't ride forever 'neath the streets of Boston if there's no trip to be found (i.e. the departure minute just keeps getting earlier)
            # now, the second destinations is not accessible by transit
            revres2 = street_raptor(net, osrm, osrm, LatLon(34.4128, -119.8487), [LatLon(34.4224, -119.7032), LatLon(34.4561, -119.6819)], DateTime(2023, 5, 10, 8, 0), reverse_search=true,
                max_reverse_search_duration=7200)
            @snapshot_test "reverse_no_path" revres2

            # @test revres2.times_at_destinations_each_departure_time[1, 1] ≤ gt(8, 0)
            # @test size(revres2.times_at_destinations_each_departure_time, 1) == 121 # search should have been cut off after 7200 seconds
            # @test all(revres2.times_at_destinations_each_departure_time[begin, 2] .== TransitRouter.MAX_TIME)

            # if it rolls back to the previous day (negative times), make sure trace does not fail
            revres3 = street_raptor(net, osrm, osrm, LatLon(34.4128, -119.8487), [LatLon(34.4224, -119.7032), LatLon(34.4226, -119.6777)], DateTime(2023, 5, 10, 0, 5), reverse_search=true)
            @snapshot_test "reverse_rollback" revres3
        end
    end
end