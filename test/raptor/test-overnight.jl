# Overnight routing
# Late in the evening or early in the morning, there may be transit service from two service days running
# simultaneously. This tests to ensure that routing on such services works, and that calendars are correctly
# handled in this situation.
# The network is very simple:
# 1 =A= 2 =A= 3 =B= 4
# The catch is that A runs only on Tuesday nights, and B only on Wednesday mornings
# A departs 1 at 23:55, arrives 2 at 24:20, and 3 at 24:30
# B departs 3 at 00:35, and arrives 4 at 00:40
# a trip departing 1 at 23:50 should use both,
# as should a trip departing 2 at 00:15
# However, a trip departing 2 at 00:20 on Tuesday should fail to route (A does not run until Tuesday night/Wednesday morning)
# Similarly, a trip departing 3 at 00:20 on Thursday should fail to route

@testset "Overnight routing" begin
    gtfs = MockGTFS()

    stops = [add_stop!(gtfs) for _ in 1:4]
    tuesday = add_service!(gtfs, 20230101, 20231231, monday=0, tuesday=1, wednesday=0, thursday=0, friday=0, saturday=0, sunday=0)
    wednesday = add_service!(gtfs, 20230101, 20231231, monday=0, tuesday=0, wednesday=1, thursday=0, friday=0, saturday=0, sunday=0)

    routes = [add_route!(gtfs) for _ in 1:2]

    add_trip!(gtfs, routes[1], tuesday, (
        (stops[1], "23:55:00"),
        (stops[2], "24:20:00"),
        (stops[3], "24:30:00")
    ))

    add_trip!(gtfs, routes[2], wednesday, (
        (stops[3], "00:35:00"),
        (stops[4], "00:40:00")
    ))

    with_gtfs(gtfs) do path
        net::TransitNetwork = with_logger(NullLogger()) do
            build_network([path])
        end

        @testset "Tuesday night" begin
            res = raptor(net, [StopAndTime(1, gt(23, 50))], Date(2023, 5, 2))

            # round 1: access
            @test res.times_at_stops_each_round[1, :] == [gt(23, 50), MT, MT, MT]
            @test res.non_transfer_times_at_stops_each_round[1, :] == fill(MT, 4)
            @test res.prev_trip[1, :] == fill(IM, 4)
            @test res.prev_stop[1, :] == fill(IM, 4)
            @test res.prev_boardtime[1, :] == fill(IM, 4)
            @test res.transfer_prev_stop[1, :] == fill(IM, 4)

            # round 2: after riding route A
            @test res.times_at_stops_each_round[2, :] == [gt(23, 50), gt(24, 20), gt(24, 30), MT]
            @test res.non_transfer_times_at_stops_each_round[2, :] == [MT, gt(24, 20), gt(24, 30), MT]
            @test res.prev_stop[2, :] == [IM, 1, 1, IM]
            @test res.prev_trip[2, :] == [IM, 1, 1, IM]
            @test res.prev_boardtime[2, :] == [IM, gt(23, 55), gt(23, 55), IM]
            @test res.transfer_prev_stop[2, :] == fill(IM, 4)

            # round 3: after riding route B (overnight routing - should caught route B)
            # 24:40 - next service day times should be converted to today
            @test res.times_at_stops_each_round[3, :] == [gt(23, 50), gt(24, 20), gt(24, 30), gt(24, 40)]
            @test res.non_transfer_times_at_stops_each_round[3, :] == [MT, gt(24, 20), gt(24, 30), gt(24, 40)]
            @test res.prev_stop[3, :] == [IM, IM, IM, 3]
            @test res.prev_trip[3, :] == [IM, IM, IM, 2]
            @test res.prev_boardtime[3, :] == [IM, IM, IM, gt(24, 35)]
            @test res.transfer_prev_stop[3, :] == fill(IM, 4)

            test_no_updates_after_round(res, 3)
        end

        @testset "Wednesday morning" begin
            # start right at midnight, to ensure that doesn't cause any issues
            res = raptor(net, [StopAndTime(2, gt(0, 0))], Date(2023, 5, 3))

            # round 1: access
            @test res.times_at_stops_each_round[1, :] == [MT, gt(0, 0), MT, MT]
            @test res.non_transfer_times_at_stops_each_round[1, :] == fill(MT, 4)
            @test res.prev_trip[1, :] == fill(IM, 4)
            @test res.prev_stop[1, :] == fill(IM, 4)
            @test res.prev_boardtime[1, :] == fill(IM, 4)
            @test res.transfer_prev_stop[1, :] == fill(IM, 4)

            # round 2: rode route A (from previous service day)
            @test res.times_at_stops_each_round[2, :] == [MT, gt(0, 0), gt(0, 30), MT]
            @test res.non_transfer_times_at_stops_each_round[2, :] == [MT, MT, gt(0, 30), MT]
            @test res.prev_trip[2, :] == [IM, IM, 1, IM]
            @test res.prev_stop[2, :] == [IM, IM, 2, IM]
            @test res.prev_boardtime[2, :] == [IM, IM, gt(0, 20), IM]
            @test res.transfer_prev_stop[2, :] == fill(IM, 4)

            # round 3: rode route B (from today)
            @test res.times_at_stops_each_round[3, :] == [MT, gt(0, 0), gt(0, 30), gt(0, 40)]
            @test res.non_transfer_times_at_stops_each_round[3, :] == [MT, MT, gt(0, 30), gt(0, 40)]
            @test res.prev_stop[3, :] == [IM, IM, IM, 3]
            @test res.prev_trip[3, :] == [IM, IM, IM, 2]
            @test res.prev_boardtime[3, :] == [IM, IM, IM, gt(0, 35)]
            @test res.transfer_prev_stop[3, :] == fill(IM, 4)

            test_no_updates_after_round(res, 3)
        end
    end


end