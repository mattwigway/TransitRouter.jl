# define some custom isequal types so snapshot testing works
@struct_isequal TransitRouter.Transfer

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
        res = street_raptor(net, osrm, osrm, LatLon(34.4128, -119.8487), [LatLon(34.4224, -119.7032), LatLon(34.4226, -119.6777)], DateTime(2023, 5, 10, 8, 0))

        @snapshot_test "streetrouter_times_at_destinations" res.times_at_destinations
        @snapshot_test "streetrouter_egress_stop_for_destination" res.egress_stop_for_destination
        @snapshot_test "streetrouter_access_geom_for_destination" res.access_geom_for_destination
        @snapshot_test "streetrouter_access_dist_for_destination" res.access_dist_for_destination
        @snapshot_test "streetrouter_egress_geom_for_destination" res.egress_geom_for_destination
        @snapshot_test "streetrouter_egress_dist_for_destination" res.egress_dist_for_destination
    end
end