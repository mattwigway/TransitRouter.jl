@testset "RAPTOR" begin
    # A network where there is a faster one-transfer route than the one seat ride that's also available
    @testset "Faster transfer" begin
        gtfs = MockGTFS()
        s1 = add_stop!(gtfs, 35.180, -80.866)
        s2 = add_stop!(gtfs, 35.197, -80.788)
        s3 = add_stop!(gtfs, 35.196, -80.686)

        svc = add_service!(gtfs, 20230101, 20231231)
        r1 = add_route!(gtfs)
        r2 = add_route!(gtfs)
        r3 = add_route!(gtfs)

        one_seat = add_trip!(gtfs, r1, svc, (
            (s1, "8:00:00"),
            (s3, "9:00:00")
        ))

        two_seat_1 = add_trip!(gtfs, r2, svc, (
            (s1, "8:02:00"),
            (s2, "8:12:00")
        ))

        two_seat_2 = add_trip!(gtfs, r3, svc, (
            (s2, "8:20:00"),
            (s3, "8:30:00")
        ))

        with_gtfs(gtfs) do path
            net = build_network([path])

            s1_id = net.stopidx_for_id["$path:$s1"]
            s2_id = net.stopidx_for_id["$path:$s2"]
            s3_id = net.stopidx_for_id["$path:$s3"]

            res = raptor(net, [StopAndTime(s1_id, TransitRouter.time_to_seconds_since_midnight(Time(7, 55)))], Date(2023, 4, 7))

            # Round 1: no transit ridden yet, access is considered a transfer.
            @test all(res.non_transfer_times_at_stops_each_round[1, :] .== TransitRouter.MAX_TIME)

            # stop 1 never reached via transit only via transfer/access
            @test all(res.non_transfer_times_at_stops_each_round[:, s1_id] .== TransitRouter.MAX_TIME)

            @test res.times_at_stops_each_round[1, s1_id] == TransitRouter.time_to_seconds_since_midnight(Time(7, 55))
            @test res.times_at_stops_each_round[1, s2_id] == TransitRouter.MAX_TIME
            @test res.times_at_stops_each_round[1, s3_id] == TransitRouter.MAX_TIME

            @test all(res.prev_stop[1, :] .== TransitRouter.INT_MISSING)
            @test all(res.prev_trip[1, :] .== TransitRouter.INT_MISSING)
            @test all(res.prev_boardtime[1, :] .== TransitRouter.INT_MISSING)


            # Round 2: one-seat ride and first two-seat ride ridden
            @test res.non_transfer_times_at_stops_each_round[2, s2_id] == TransitRouter.time_to_seconds_since_midnight(Time(8, 12))
            @test res.non_transfer_times_at_stops_each_round[2, s3_id] == TransitRouter.time_to_seconds_since_midnight(Time(9, 0))

            @test res.times_at_stops_each_round[2, s1_id] == TransitRouter.time_to_seconds_since_midnight(Time(7, 55))
            @test res.times_at_stops_each_round[2, s2_id] == TransitRouter.time_to_seconds_since_midnight(Time(8, 12))
            @test res.times_at_stops_each_round[2, s3_id] == TransitRouter.time_to_seconds_since_midnight(Time(9, 0))

            @test res.prev_stop[2, s1_id] == TransitRouter.INT_MISSING
            @test res.prev_stop[2, s2_id] == s1_id
            @test res.prev_stop[2, s3_id] == s1_id

            # check that they were accessed by the correct route
            @test res.prev_trip[2, s1_id] == TransitRouter.INT_MISSING
            @test res.prev_trip[2, s2_id] == findfirst([t.route == net.routeidx_for_id["$path:$r2"] for t in net.trips]) # two seat ride 1
            @test res.prev_trip[2, s3_id] == findfirst([t.route == net.routeidx_for_id["$path:$r1"] for t in net.trips]) # one seat ride

            @test res.prev_boardtime[2, s1_id] == TransitRouter.INT_MISSING
            @test res.prev_boardtime[2, s2_id] == TransitRouter.time_to_seconds_since_midnight(Time(8, 2))
            @test res.prev_boardtime[2, s3_id] == TransitRouter.time_to_seconds_since_midnight(Time(8, 0))


            # Round 3: routing complete
            @test res.non_transfer_times_at_stops_each_round[3, s2_id] == TransitRouter.time_to_seconds_since_midnight(Time(8, 12))
            @test res.non_transfer_times_at_stops_each_round[3, s3_id] == TransitRouter.time_to_seconds_since_midnight(Time(8, 30))

            @test res.prev_stop[3, s1_id] == TransitRouter.INT_MISSING
            @test res.prev_stop[3, s2_id] == TransitRouter.INT_MISSING # not updated this round
            @test res.prev_stop[3, s3_id] == s2_id # updated with new transfer

            @test res.prev_trip[3, s1_id] == TransitRouter.INT_MISSING
            @test res.prev_trip[3, s2_id] == TransitRouter.INT_MISSING # not updated this route
            @test res.prev_trip[3, s3_id] == findfirst([t.route == net.routeidx_for_id["$path:$r3"] for t in net.trips]) # second route of two seat ride

            @test res.prev_boardtime[3, s1_id] == TransitRouter.INT_MISSING
            @test res.prev_boardtime[3, s2_id] == TransitRouter.INT_MISSING # not updated this round
            @test res.prev_boardtime[3, s3_id] == TransitRouter.time_to_seconds_since_midnight(Time(8, 20))

            # round 4 and 5: no changes
            @test res.non_transfer_times_at_stops_each_round[4, :] == res.non_transfer_times_at_stops_each_round[3, :]
            # no transfers after round 4, check non-transfer times
            @test res.non_transfer_times_at_stops_each_round[5, :] == res.non_transfer_times_at_stops_each_round[3, :]        

            @test all(res.prev_stop[4:5, :] .== TransitRouter.INT_MISSING)
            @test all(res.prev_trip[4:5, :] .== TransitRouter.INT_MISSING)
            @test all(res.prev_boardtime[4:5, :] .== TransitRouter.INT_MISSING)

            # no transfers
            @test all(res.transfer_prev_stop .== TransitRouter.INT_MISSING)
        end
    end
end