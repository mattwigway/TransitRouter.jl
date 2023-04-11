

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
@testset "RAPTOR transfers" begin
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



# add testsets for: trip/service running, overnight routing, right trip selected when multiple on the pattern
#  transfer and direct transit to same stop, with direct transit and transfer built on.