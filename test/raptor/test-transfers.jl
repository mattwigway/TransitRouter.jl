

# Test that transfers work and also that consecutive transfers are not allowed
# Stops like this, with = for a transit route and - for a transfer:
#   1 = 2 - 3 - 4 = 5
#         =
# There is both a transit route and a transfer between 2 and 3
# The transfer is faster, so the fastest trip would be:
#   1 = 2 - 3 - 4 = 5
# but this is not allowed (no two consecutive transfers)
# so what we will get instead:
# 1 = 2 = 3 - 4 = 5
@testitem "RAPTOR transfers" begin
    include("../test-includes.jl")

    gtfs = MockGTFS()

    s1_id = add_stop!(gtfs, 35.180, -80.866)
    s2_id = add_stop!(gtfs, 35.197, -80.788)
    s3_id = add_stop!(gtfs, 35.189, -80.788)
    s4_id = add_stop!(gtfs, 35.181, -80.788)
    s5_id = add_stop!(gtfs, 35.196, -80.686)

    r1_id = add_route!(gtfs)
    r2_id = add_route!(gtfs)
    r3_id = add_route!(gtfs)

    s = add_service!(gtfs, 20230101, 20231231)

    add_trip!(gtfs, r1_id, s, (
        (s1_id, "8:00:00"),
        (s2_id, "8:30:00")
    ))

    add_trip!(gtfs, r2_id, s, (
        (s2_id, "8:40:00"),
        (s3_id, "10:40:00") # make it take an obscenely long time so the transfer is preferable
    ))

    add_trip!(gtfs, r3_id, s, (
        (s4_id, "10:30:00"), # should just miss this trip, unless we do consecutive transfers
        (s5_id, "10:50:00")
    ))

    add_trip!(gtfs, r3_id, s, (
        (s4_id, "11:30:00"),
        (s5_id, "11:50:00")
    ))

    with_gtfs(gtfs) do path
        net::TransitNetwork = with_logger(NullLogger()) do
            build_network([path])
        end

        s1 = net.stopidx_for_id["$path:$s1_id"]
        s2 = net.stopidx_for_id["$path:$s2_id"]
        s3 = net.stopidx_for_id["$path:$s3_id"]
        s4 = net.stopidx_for_id["$path:$s4_id"]
        s5 = net.stopidx_for_id["$path:$s5_id"]

        r1 = net.routeidx_for_id["$path:$r1_id"]
        r2 = net.routeidx_for_id["$path:$r2_id"]
        r3 = net.routeidx_for_id["$path:$r3_id"]

        res = raptor(net, [StopAndTime(s1, gt(7, 55))], Date(2023, 4, 7))

        # stop 1 never reached by transit
        @test all(res.non_transfer_times_at_stops_each_round[:, s1] .== TransitRouter.MAX_TIME)

        # stop 4 never reached by transit
        @test all(res.non_transfer_times_at_stops_each_round[:, s4] .== TransitRouter.MAX_TIME)

        # Round 1: no transit
        @test all(res.non_transfer_times_at_stops_each_round[1, :] .== TransitRouter.MAX_TIME)
        @test res.times_at_stops_each_round[1, s1] == gt(7, 55)
        # all other stops unreached even by transfers/access
        @test all([res.times_at_stops_each_round[1, s] for s in [s2, s3, s4, s5]]  .== TransitRouter.MAX_TIME)

        @test all(res.prev_stop[1, :] .== TransitRouter.INT_MISSING)
        @test all(res.transfer_prev_stop[1, :] .== TransitRouter.INT_MISSING)
        @test all(res.prev_trip[1, :] .== TransitRouter.INT_MISSING)
        @test all(res.prev_boardtime[1, :] .== TransitRouter.INT_MISSING)

        ## Round 2: stop 2 reached via transit, stop 3 reached via transfer
        # stop 1: not reached via transit, and not touched this round
        @test res.times_at_stops_each_round[2, s1] == gt(7, 55)
        @test res.non_transfer_times_at_stops_each_round[2, s1] == MAX_TIME # not reached via transit
        @test res.prev_stop[2, s1] == INT_MISSING
        @test res.prev_trip[2, s1] == INT_MISSING
        @test res.prev_boardtime[2, s1] == INT_MISSING
        @test res.transfer_prev_stop[2, s1] == INT_MISSING

        # stop 2: reached via transit this round
        @test res.times_at_stops_each_round[2, s2] == gt(8, 30)
        @test res.non_transfer_times_at_stops_each_round[2, s2] == gt(8, 30)
        @test res.prev_stop[2, s2] == s1
        @test net.trips[res.prev_trip[2, s2]].route == r1
        @test res.prev_boardtime[2, s2] == gt(8, 0)
        @test res.transfer_prev_stop[2, s2] == INT_MISSING # no xfer

        # stop 3: reached via transfer this round
        @test res.times_at_stops_each_round[2, s3] == round(gt(8, 30) + net.transfers[s2][1].duration_seconds)
        @test res.non_transfer_times_at_stops_each_round[2, s3] == MAX_TIME # not reached via transit
        @test res.prev_stop[2, s3] == INT_MISSING
        @test res.prev_trip[2, s3] == INT_MISSING
        @test res.prev_boardtime[2, s3] == INT_MISSING
        @test res.transfer_prev_stop[2, s3] == s2

        # stops 4/5: not reached
        for s in [s4, s5]
            @test res.times_at_stops_each_round[2, s] == MAX_TIME
            @test res.non_transfer_times_at_stops_each_round[2, s] == MAX_TIME
            @test res.prev_stop[2, s] == INT_MISSING
            @test res.prev_trip[2, s] == INT_MISSING
            @test res.prev_boardtime[2, s] == INT_MISSING
            @test res.transfer_prev_stop[2, s] == INT_MISSING
        end

        ### Round 3: stop 3 reached via transit, stop 4 reached via transfer
        ## Stop 1: still not touched
        @test res.times_at_stops_each_round[3, s1] == gt(7, 55)
        @test res.non_transfer_times_at_stops_each_round[3, s1] == MAX_TIME # not reached via transit
        @test res.prev_stop[3, s1] == INT_MISSING
        @test res.prev_trip[3, s1] == INT_MISSING
        @test res.prev_boardtime[3, s1] == INT_MISSING
        @test res.transfer_prev_stop[3, s1] == INT_MISSING

        ## Stop 2: no updates this round
        @test res.times_at_stops_each_round[3, s2] == gt(8, 30)
        @test res.non_transfer_times_at_stops_each_round[3, s2] == gt(8, 30)
        # vv not updated this round vv
        @test res.prev_stop[3, s2] == INT_MISSING
        @test res.prev_trip[3, s2] == INT_MISSING
        @test res.prev_boardtime[3, s2] == INT_MISSING
        @test res.transfer_prev_stop[3, s2] == INT_MISSING

        ## Stop 3
        # reached via transit
        @test res.non_transfer_times_at_stops_each_round[3, s3] == gt(10, 40)
        # but transfer time from previous round stored as well
        @test res.times_at_stops_each_round[3, s3] == res.times_at_stops_each_round[2, s3]
        @test res.prev_stop[3, s3] == s2
        @test net.trips[res.prev_trip[3, s3]].route == r2
        @test res.prev_boardtime[3, s3] == gt(8, 40)
        # no transfer reached this stop this round
        @test res.transfer_prev_stop[3, s3] == INT_MISSING

        ## stop 4: reached via transfer from stop 3 _after riding transit_
        @test res.times_at_stops_each_round[3, s4] == round(gt(10, 40) + net.transfers[s3][1].duration_seconds)
        @test res.non_transfer_times_at_stops_each_round[3, s4] == MAX_TIME # not reached via transit
        @test res.prev_stop[3, s4] == INT_MISSING
        @test res.prev_trip[3, s4] == INT_MISSING
        @test res.prev_boardtime[3, s4] == INT_MISSING
        @test res.transfer_prev_stop[3, s4] == s3

        ## Stop 5: not reached
        @test res.times_at_stops_each_round[3, s5] == MAX_TIME
        @test res.non_transfer_times_at_stops_each_round[3, s5] == MAX_TIME
        @test res.prev_stop[3, s5] == INT_MISSING
        @test res.prev_trip[3, s5] == INT_MISSING
        @test res.prev_boardtime[3, s5] == INT_MISSING
        @test res.transfer_prev_stop[3, s5] == INT_MISSING

        ### Round 4: stop 5 reached via transit
        ## Stop 1: still not touched
        @test res.times_at_stops_each_round[4, s1] == gt(7, 55)
        @test res.non_transfer_times_at_stops_each_round[4, s1] == MAX_TIME # not reached via transit
        @test res.prev_stop[4, s1] == INT_MISSING
        @test res.prev_trip[4, s1] == INT_MISSING
        @test res.prev_boardtime[4, s1] == INT_MISSING
        @test res.transfer_prev_stop[4, s1] == INT_MISSING

        ## Stop 2: no updates this round
        @test res.times_at_stops_each_round[4, s2] == gt(8, 30)
        @test res.non_transfer_times_at_stops_each_round[4, s2] == gt(8, 30)
        # vv not updated this round vv
        @test res.prev_stop[4, s2] == INT_MISSING
        @test res.prev_trip[4, s2] == INT_MISSING
        @test res.prev_boardtime[4, s2] == INT_MISSING
        @test res.transfer_prev_stop[4, s2] == INT_MISSING

        ## Stop 3 not touched
        @test res.non_transfer_times_at_stops_each_round[4, s3] == gt(10, 40)
        @test res.times_at_stops_each_round[4, s3] == res.times_at_stops_each_round[2, s3]
        @test res.prev_stop[4, s3] == INT_MISSING
        @test res.prev_trip[4, s3] == INT_MISSING
        @test res.prev_boardtime[4, s3] == INT_MISSING
        # no transfer reached this stop this round
        @test res.transfer_prev_stop[4, s3] == INT_MISSING

        ## stop 4: not touched
        @test res.times_at_stops_each_round[4, s4] == round(gt(10, 40) + net.transfers[s3][1].duration_seconds)
        @test res.non_transfer_times_at_stops_each_round[4, s4] == MAX_TIME # not reached via transit
        @test res.prev_stop[4, s4] == INT_MISSING
        @test res.prev_trip[4, s4] == INT_MISSING
        @test res.prev_boardtime[4, s4] == INT_MISSING
        @test res.transfer_prev_stop[4, s4] == INT_MISSING

        ## Stop 5: reached via transit by the second trip that arrives at 11:50, after missing the 10:30 because
        ## we disallow consecutive transfers
        @test res.times_at_stops_each_round[4, s5] == gt(11, 50)
        @test res.non_transfer_times_at_stops_each_round[4, s5] == gt(11, 50)
        @test res.prev_stop[4, s5] == s4
        # make sure we caught the 11:30 on route 3
        @test net.trips[res.prev_trip[4, s5]].route == r3
        @test net.trips[res.prev_trip[4, s5]].stop_times[1].departure_time == gt(11, 30)
        @test res.prev_boardtime[4, s5] == gt(11, 30)
        @test res.transfer_prev_stop[4, s5] == INT_MISSING
    end
end

# test that the RAPTOR transfer distance limit works
# the network looks like this, with = a transit route and - a transfer
# 1 =A= 2 ========A===== 3
#       | 800m           | 100m
#       4 ========B===== 5 ====B==== 6
#
# The second segment of route A is slow, so it is fastest to transfer 2-4, but this requires an 800m walk.
# If you transfer 3 to 5, you miss the first vehicle on route B, and have to take the second. So when there is
# no transfer distance limit, we will get 1=2-4=5=6, but with a transfer distance limit will get 1=2=3-5=6
@testitem "RAPTOR transfer distance limit" begin
    include("../test-includes.jl")

    gtfs = MockGTFS()

    s1 = add_stop!(gtfs, 33.5896, -111.8312)
    s2 = add_stop!(gtfs, 33.5896, -111.8134)
    s3 = add_stop!(gtfs, 33.5896, -111.7961)
    s4 = add_stop!(gtfs, 33.5825, -111.8135)
    s5 = add_stop!(gtfs, 33.5877, -111.7967)
    s6 = add_stop!(gtfs, 33.5886, -111.7339) # far away, no transfers

    s = add_service!(gtfs, 19900101, 20501231)
    ra = add_route!(gtfs)
    rb = add_route!(gtfs)

    add_trip!(gtfs, ra, s, (
        (s1, "8:00:00"),
        (s2, "8:05:00"),
        # long travel time to s3, transfer at s2 will be better
        (s3, "10:00:00")
    ))

    add_trip!(gtfs, rb, s, (
        (s4, "8:30:00"), # plenty of time to walk from s2
        (s5, "8:35:00"), # can't transfer from s3
        (s6, "8:45:00")
    ))

    add_trip!(gtfs, rb, s, (
        (s4, "10:30:00"),
        (s5, "10:55:00"), # plenty of time to walk from s3
        (s6, "11:05:00")
    ))

    with_gtfs(gtfs) do path
        net::TransitNetwork = with_logger(NullLogger()) do
            build_network([path])
        end

        res = raptor(net, [StopAndTime(1, gt(7, 55))], Date(2023, 4, 7))

        # round 1: no transit
        @test res.times_at_stops_each_round[1, :] == [gt(7, 55), MT, MT, MT, MT, MT]
        @test all(res.non_transfer_times_at_stops_each_round[1, :] .== MT)
        @test all(res.prev_trip[1, :] .== IM)
        @test all(res.prev_stop[1, :] .== IM)
        @test all(res.transfer_prev_stop[1, :] .== IM)

        # round 2: stops 2 and 3 reached directly, 4 and 5 via transfer
        @test res.times_at_stops_each_round[2, :] == [gt(7, 55), gt(8, 5), gt(10, 0),
            round(Int64, gt(8, 5) + net.transfers[2][1].duration_seconds),
            round(Int64,gt(10, 0) + net.transfers[3][1].duration_seconds),
            MT
        ]
        @test res.non_transfer_times_at_stops_each_round[2, :] == [MT, gt(8, 5), gt(10, 0), MT, MT, MT]
        @test res.prev_trip[2, :] == [IM, 1, 1, IM, IM, IM]
        @test res.prev_stop[2, :] == [IM, 1, 1, IM, IM, IM]
        @test res.transfer_prev_stop[2, :] == [IM, IM, IM, 2, 3, IM]

        # round 3: stops 4 and 5 reached via transit
        @test res.times_at_stops_each_round[3, :] == [gt(7, 55), gt(8, 5),
            round(Int64, gt(8, 35) + net.transfers[5][1].duration_seconds), # back-transfer from stop 5
            round(Int64, gt(8, 5) + net.transfers[2][1].duration_seconds),
            gt(8, 35),
            gt(8, 45)
        ]
        @test res.non_transfer_times_at_stops_each_round[3, :] == [MT, gt(8, 5), gt(10, 0), MT, gt(8, 35), gt(8, 45)]
        @test res.prev_stop[3, :] == [IM, IM, IM, IM, 4, 4]
        @test res.prev_trip[3, :] == [IM, IM, IM, IM, 2, 2]
        @test res.transfer_prev_stop[3, :] == [IM, IM, 5, IM, IM, IM]

        test_no_updates_after_round(res, 3)

        println(net.transfers[3][1])

        # Now, the same thing with a 500m transfer limit (will drop the transfer 2-4)
        res = raptor(net, [StopAndTime(1, gt(7, 55))], Date(2023, 4, 7), max_transfer_distance_meters=500.0)

        # round 1: no transit
        @test res.times_at_stops_each_round[1, :] == [gt(7, 55), MT, MT, MT, MT, MT]
        @test all(res.non_transfer_times_at_stops_each_round[1, :] .== MT)
        @test all(res.prev_trip[1, :] .== IM)
        @test all(res.prev_stop[1, :] .== IM)
        @test all(res.transfer_prev_stop[1, :] .== IM)

        # round 2: stops 2 and 3 reached directly, 5 via transfer
        @test res.times_at_stops_each_round[2, :] == [gt(7, 55), gt(8, 5), gt(10, 0), MT,
            round(Int64,gt(10, 0) + net.transfers[3][1].duration_seconds),
            MT
        ]
        @test res.non_transfer_times_at_stops_each_round[2, :] == [MT, gt(8, 5), gt(10, 0), MT, MT, MT]
        @test res.prev_trip[2, :] == [IM, 1, 1, IM, IM, IM]
        @test res.prev_stop[2, :] == [IM, 1, 1, IM, IM, IM]
        @test res.transfer_prev_stop[2, :] == [IM, IM, IM, IM, 3, IM]

        # round 3: stops 5 reached via transit
        @test res.times_at_stops_each_round[3, :] == [gt(7, 55), gt(8, 5),
            gt(10, 0),
            MT,
            round(Int64,gt(10, 0) + net.transfers[3][1].duration_seconds),
            gt(11, 5)
        ]
        @test res.non_transfer_times_at_stops_each_round[3, :] == [MT, gt(8, 5), gt(10, 0), MT, MT, gt(11, 5)]
        @test res.prev_stop[3, :] == [IM, IM, IM, IM, IM, 5]
        @test res.prev_trip[3, :] == [IM, IM, IM, IM, IM, 3]
        @test res.transfer_prev_stop[3, :] == [IM, IM, IM, IM, IM, IM]

        test_no_updates_after_round(res, 3)


    end

end
