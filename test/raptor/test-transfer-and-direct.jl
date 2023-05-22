#=
This test confirms that the non-transfer and transfer arrays are working correctly.

The network looks like this, where numbers are stops, letters are routes, double lines
are transit, and single lines are transfers.

1 =A= 2
||    |
 C == 3 =B= 4
      |
      5 =D= 6

Route A is much quicker than route C, so to get to 4 the fastest trip is

1=A=2-3=B=4

But you can't get on D this way, because that would require a double-transfer.

So instead you have

1=C=3-5=B=6

Stop 3 is reached twice in the first transit round, once directly and once via a
transfer. Both should be retained.

 =#
@testitem "Transfer and direct" begin
    include("../test-includes.jl")

    gtfs = MockGTFS()

    s1id = add_stop!(gtfs, 37.363, -122.123)
    s2id = add_stop!(gtfs, 37.4, -122.2)
    s3id = add_stop!(gtfs, 37.407, -122.2) # roughly 800 meters, transfer will be created
    s4id = add_stop!(gtfs, 37.44, -122.3)
    s5id = add_stop!(gtfs, 37.414, -122.2) # 800 meters from s3, 1600 from s2
    s6id = add_stop!(gtfs, 37.5, -122.3)

    rs = [add_route!(gtfs) for _ in 1:4]

    svc = add_service!(gtfs, 20230101, 20231231)

    # route A
    add_trip!(gtfs, rs[1], svc, (
        (s1id, "8:00:00"),
        (s2id, "8:12:00")
    ))

    # route A can get you on this trip, but route C cannot
    add_trip!(gtfs, rs[2], svc, (
        (s3id, "8:32:00"),
        (s4id, "8:43:00")
    ))

    # this would be the trip you'd get on if route C were your only option
    add_trip!(gtfs, rs[2], svc, (
        (s3id, "8:52:00"),
        (s4id, "9:12:00")
    ))

    add_trip!(gtfs, rs[3], svc, (
        (s1id, "8:02:00"),
        (s3id, "8:42:00") # will miss first trip on route B
    ))

    add_trip!(gtfs, rs[4], svc, (
        (s5id, "8:40:00"), # won't catch this from route C - shouldn't catch at all since double transfers not allowed
        (s6id, "8:55:00")
    ))

    add_trip!(gtfs, rs[4], svc, (
        (s5id, "9:05:00"), # this is the trip we expect to catch
        (s6id, "9:15:00")
    ))

    with_gtfs(gtfs) do path
        net::TransitNetwork = with_logger(NullLogger()) do
            build_network([path])
        end

        @test length(net.stops) == 6
        @test length(net.routes) == 4
        @test length(net.trips) == 6

        res = raptor(net, [StopAndTime(1, gt(7, 55))], Date(2023, 4, 7))

        # assuming here that stops were read in order, so s1 is index 1 etc.
        # round 1: access
        @test res.times_at_stops_each_round[1,:] == [gt(7, 55), MT, MT, MT, MT, MT]
        @test res.non_transfer_times_at_stops_each_round[1, :] == fill(MT, 6)
        @test res.prev_stop[1,:] == fill(IM, 6)
        @test res.prev_trip[1,:] == fill(IM, 6)
        @test res.prev_boardtime[1,:] == fill(IM, 6)
        @test res.transfer_prev_stop[1,:] == fill(IM, 6)

        # round 2: first transit round, stops 2 and 3 reached via transit and stop 3 and 5 reached via transfer
        @test res.times_at_stops_each_round[2,:] == [
            gt(7, 55),
            gt(8, 12),
            floor(Int32, gt(8, 12) + net.transfers[2][1].duration_seconds),
            MT,
            floor(Int32, gt(8, 42) + net.transfers[3][1].duration_seconds),
            MT
        ]
        @test res.non_transfer_times_at_stops_each_round[2, :] == [MT, gt(8, 12), gt(8, 42), MT, MT, MT]
        @test res.prev_stop[2,:] == [IM, 1, 1, IM, IM, IM]
        @test res.prev_trip[2,:] == [IM, 1, 4, IM, IM, IM]
        @test res.prev_boardtime[2,:] == [IM, gt(8, 0), gt(8, 2), IM, IM, IM]
        @test res.transfer_prev_stop[2,:] == [IM, IM, 2, IM, 3, IM]

        # round 3: second transit round, stops 4 and 6 reached via tranist
        @test res.times_at_stops_each_round[3,:] == [
            gt(7, 55),
            gt(8, 12),
            floor(Int32, gt(8, 12) + net.transfers[2][1].duration_seconds),
            gt(8, 43),
            floor(Int32, gt(8, 42) + net.transfers[3][1].duration_seconds),
            gt(9, 15)
        ]
        @test res.non_transfer_times_at_stops_each_round[3, :] == [MT, gt(8, 12), gt(8, 42), gt(8, 43), MT, gt(9, 15)]
        @test res.prev_stop[3,:] == [IM, IM, IM, 3, IM, 5]
        @test res.prev_trip[3,:] == [IM, IM, IM, 2, IM, 6]
        @test res.prev_boardtime[3,:] == [IM, IM, IM, gt(8, 32), IM, gt(9, 5)]
        @test res.transfer_prev_stop[3,:] == [IM, IM, IM, IM, IM, IM]


    end

end