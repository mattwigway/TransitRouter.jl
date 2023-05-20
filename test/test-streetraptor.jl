@testitem "StreetRaptor" begin
    include("test-includes.jl")
    # define some custom isequal types so snapshot testing works
    @struct_isequal TransitRouter.Transfer
    @struct_isequal TransitRouter.RaptorResult
    @struct_isequal TransitRouter.StreetRaptorResult
    @struct_isequal TransitRouter.AccessEgress

    # we now respect pickup type and dropoff type, which we didn't when the snapshots were originally created
    # This affects three stops in the SBMTD network: stop_ids 685, 679, and 671. The only differences in the times should
    # be at these three stops, or downstream from them
    function predecessor_stops(res, stop, transfer, round)
        if transfer
            res.times_at_stops_each_round[round, stop] != MT || error("round $round, stop $stop not reached")
            # step back if reached in earlier round
            if round > 1 && res.times_at_stops_each_round[round, stop] == res.times_at_stops_each_round[round - 1, stop]
                return predecessor_stops(res, stop, transfer, round - 1)
            end
            prev_stop = res.transfer_prev_stop[round, stop]
            if prev_stop == TransitRouter.INT_MISSING
                prev_stop = stop
            end
        else
            if round > 1
                if round > 1 && res.non_transfer_times_at_stops_each_round[round, stop] == res.non_transfer_times_at_stops_each_round[round - 1, stop]
                    return predecessor_stops(res, stop, transfer, round - 1)
                end

                res.prev_stop[round, stop] != IM || error("round $round, stop $stop not reached")

                prev_stop = res.prev_stop[round, stop]
                round -= 1
            else
                return (stop,)
            end
        end

        return (stop, predecessor_stops(res, prev_stop, !transfer, round)...)
    end

    predecessor_stops_contain(res, stop, predecessors, transfer, round) = any(predecessors .∈ Ref(predecessor_stops(res, stop, transfer, round)))

    const predecessors = [535, 529, 522]

    function Base.isequal(sr1::TransitRouter.StreetRaptorResult, sr2::TransitRouter.StreetRaptorResult)
        if !isequal(sr1.times_at_destinations_each_departure_time, sr2.times_at_destinations_each_departure_time)
            return false
        end

        if !isequal(sr1.egress_stop_each_departure_time, sr2.egress_stop_each_departure_time)
            return false
        end
        if !isequal(sr1.access_geometries, sr2.access_geometries)
            return false
        end
        if !isequal(sr1.egress_geometries, sr2.egress_geometries)
            return false
        end
        if !isequal(sr1.departure_date_time, sr2.departure_date_time)
            return false
        end

        for (minute, val) in enumerate(zip(sr1.raptor_results, sr2.raptor_results))
            rr1, rr2 = val
            for (round, stop) in Tuple.(findall(rr1.times_at_stops_each_round .≠ rr2.times_at_stops_each_round))
                if !predecessor_stops_contain(rr2, stop, predecessors, true, round)
                    @error "Mismatch at minute $minute, round $round, stop $stop, transfer"
                    return false

                end
            end

            for (round, stop) in Tuple.(findall(rr1.non_transfer_times_at_stops_each_round .≠ rr2.non_transfer_times_at_stops_each_round))
                if !predecessor_stops_contain(rr2, stop, predecessors, false, round)
                    @error "Mismatch at minute $minute, round $round, stop $stop, non-transfer"
                    return false
                end
            end

            for (round, stop) in Tuple.(findall(rr1.prev_trip .≠ rr2.prev_trip))
                if !predecessor_stops_contain(rr2, stop, predecessors, false, round)
                    @error "Mismatch at minute $minute, round $round, stop $stop, non-transfer"
                    return false
                end
            end

            for (round, stop) in Tuple.(findall(rr1.prev_stop .≠ rr2.prev_stop))
                if !predecessor_stops_contain(rr2, stop, predecessors, false, round)
                    @error "Mismatch at minute $minute, round $round, stop $stop, non-transfer"
                    return false
                end
            end

            for (round, stop) in Tuple.(findall(rr1.prev_boardtime .≠ rr2.prev_boardtime))
                if !predecessor_stops_contain(rr2, stop, predecessors, false, round)
                    @error "Mismatch at minute $minute, round $round, stop $stop, non-transfer"
                    return false
                end
            end

            for (round, stop) in Tuple.(findall(rr1.transfer_prev_stop .≠ rr2.transfer_prev_stop))
                if !predecessor_stops_contain(rr2, stop, predecessors, true, round)
                    @error "Mismatch at minute $minute, round $round, stop $stop, transfer"
                    return false
                end
            end
        end

        return true
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

        end
    end
end