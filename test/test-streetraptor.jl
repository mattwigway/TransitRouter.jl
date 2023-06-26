@testitem "StreetRaptor" begin
    include("test-includes.jl")
    # define some custom isequal types so snapshot testing works
    @struct_isequal TransitRouter.Transfer
    @struct_isequal TransitRouter.RaptorResult
    @struct_isequal TransitRouter.AccessEgress

    function Base.isequal(x::TransitRouter.Leg, y::TransitRouter.Leg)
        isequal(x.start_time, y.start_time) &&
            isequal(x.end_time, y.end_time) &&
            isequal(x.origin_stop, y.origin_stop) &&
            isequal(x.destination_stop, y.destination_stop) &&
            isequal(x.type, y.type) &&
            isequal(x.route, y.route) &&
            (ismissing(x.distance_meters) && ismissing(y.distance_meters) || abs(x.distance_meters - y.distance_meters) < 5) 
            isequal(x.geometry, y.geometry)
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
            revres = street_raptor(net, osrm, osrm, LatLon(34.4128, -119.8487), [LatLon(34.4224, -119.7032), LatLon(34.4226, -119.6777)], DateTime(2023, 5, 10, 8, 0), -7200)

            # @test all(revres.times_at_destinations_each_departure_time[begin, :] .≤  gt(8, 0))
            # for dest in 1:2
            #     egress_stop = revres.egress_stop_each_departure_time[begin, dest]
            #     @test revres.raptor_results[1].non_transfer_times_at_stops_each_round[end, egress_stop] +
            #         round(Int32, revres.egress_geometries[(dest, egress_stop)].duration_seconds) == revres.times_at_destinations_each_departure_time[begin, dest]
            # end

            # make sure it doesn't ride forever 'neath the streets of Boston if there's no trip to be found (i.e. the departure minute just keeps getting earlier)
            # now, the seconds of the destinations is not accessible by transit
            revres2 = street_raptor(net, osrm, osrm, LatLon(34.4128, -119.8487), [LatLon(34.4224, -119.7032), LatLon(34.4561, -119.6819)], DateTime(2023, 5, 10, 8, 0), -7200)
            # @test revres2.times_at_destinations_each_departure_time[1, 1] ≤ gt(8, 0)
            # @test size(revres2.times_at_destinations_each_departure_time, 1) == 121 # search should have been cut off after 7200 seconds
            # @test all(revres2.times_at_destinations_each_departure_time[begin, 2] .== TransitRouter.MAX_TIME)

            # if it rolls back to the previous day (negative times), make sure trace does not fail
            revres3 = street_raptor(net, osrm, osrm, LatLon(34.4128, -119.8487), [LatLon(34.4224, -119.7032), LatLon(34.4226, -119.6777)], DateTime(2023, 5, 10, 0, 5), -TransitRouter.SECONDS_PER_DAY)

            # @test all(revres3.times_at_destinations_each_departure_time[begin, :] .≤  gt(0, 5))
            # for dest in 1:2
            #     egress_stop = revres3.egress_stop_each_departure_time[begin, dest]
            #     @test revres3.raptor_results[1].non_transfer_times_at_stops_each_round[end, egress_stop] +
            #         round(Int32, revres3.egress_geometries[(dest, egress_stop)].duration_seconds) == revres3.times_at_destinations_each_departure_time[begin, dest]
            # end

            @snapshot_test "reverse_trace" revres3
        end
    end
end