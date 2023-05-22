# The RAPTOR algorithm is Pareto-optimal in terms of time and transfers. Walk distance does not
# enter the algorithm except when it influences time. Since time is quantized by transit routes,
# especially infrequent ones, the router will often choose long walks that no one would do in real
# life. Consider the following network (to scale):
#
#  +--- Origin
#  |         |
#  1 ===A=== 2 ===A=== 3 ===A=== 4
#                      |         |
#                +-----+         |
#                |               |
#                5 ======B====== 6 ===B=== 7
#
# To get to stop 7, the reasonable thing to do is walk to stop 2 (since it's closer than stop 1), ride to stop 4, then
# transfer to stop 6. This minimizes walking, and still gives the earliest arrival assuming you can get all the same vehicles.
# However, what the base RAPTOR algorithm will *actually* find is boarding at stop 1, transfer stop 3->5. This is because we
# explore stops in order, and the first stop that can get you on a vehicle will win.
#
# Adding additional objectives to the routing is computationally undesirable, so what we do instead is track walk distance and
# just use it as a tiebreaker - i.e. a "transfer preference" in the RAPTOR paper. This may not always produce all pareto points
# for time, transfers, walk distance, but it will eliminate weirdness like ladder transfers and long initial walks when a closer
# stop is a possibility.

@testitem "Minimum walk distance" begin
    include("../test-includes.jl")

    gtfs = MockGTFS()
    stops = [
        add_stop!(gtfs, 37.363, -122.123),
        add_stop!(gtfs, 37.364, -122.124),
        add_stop!(gtfs, 37.4, -122.1),
        add_stop!(gtfs, 37.45, -122.1),
        add_stop!(gtfs, 37.401, -122.1),
        add_stop!(gtfs, 37.45001, -122.1),
        add_stop!(gtfs, 37.5, -122.15)
    ]

    routes = [add_route!(gtfs) for _ in 1:2]

    service = add_service!(gtfs, 20230101, 20231231)

    add_trip!(gtfs, routes[1], service, (
        (stops[1], "8:00:00"),
        (stops[2], "8:05:00"),
        (stops[3], "8:10:00"),
        (stops[4], "8:15:00")
    ))

    add_trip!(gtfs, routes[2], service, (
        (stops[5], "9:00:00"), # plenty of time to make the transfer
        (stops[6], "9:05:00"),
        (stops[7], "9:10:00")
    ))

    with_gtfs(gtfs) do path
        net::TransitNetwork = with_logger(NullLogger()) do
            build_network([path])
        end

        res = raptor(net, [StopAndTime(1, gt(7, 55), 150), StopAndTime(2, gt(7, 55), 100)], Date(2023, 5, 8))

        # round 1: access
        @test res.times_at_stops_each_round[1, :] == [gt(7, 55), gt(7, 55), MT, MT, MT, MT, MT]
        @test res.non_transfer_times_at_stops_each_round[1, :] == fill(MT, 7)
        @test res.prev_trip[1, :] == fill(IM, 7)
        @test res.prev_stop[1, :] == fill(IM, 7)
        @test res.prev_boardtime[1, :] == fill(IM, 7)
        @test res.transfer_prev_stop[1, :] == fill(IM, 7)
        @test res.walk_distance_meters[1, :] == [150, 100, IM, IM, IM, IM, IM]
        @test res.non_transfer_walk_distance_meters[1, :] == fill(IM, 7)

        # round 2: after riding route A
        # NB the longer walk will be chosen if it provides the only non-transfer way to get to a location. For instance,
        # to get to stop 2 by transit, you can board at stop 1, even though it's better to just walk straight to stop 2.
        @test res.times_at_stops_each_round[2, :] == [gt(7, 55), gt(7, 55), gt(8, 10), gt(8, 15),
            gt(8, 10) + round(Int64, net.transfers[3][1].duration_seconds),
            gt(8, 15) + round(Int64, net.transfers[4][1].duration_seconds),
            MT]
        @test res.non_transfer_times_at_stops_each_round[2, :] == [MT, gt(8, 5), gt(8, 10), gt(8, 15), MT, MT, MT]
        @test res.prev_trip[2, :] == [IM, 1, 1, 1, IM, IM, IM]
        @test res.prev_stop[2, :] == [IM, 1, 2, 2, IM, IM, IM]  # should have boarded at 2 - shorter walk - but to get to 2 will board at 1 for non-transfer trip
        @test res.prev_boardtime[2, :] == [IM, gt(8, 0), gt(8, 5), gt(8, 5), IM, IM, IM]
        @test res.transfer_prev_stop[2, :] == [IM, IM, IM, IM, 3, 4, IM]
        @test res.walk_distance_meters[2, :] == [150, 100, 100, 100, 100 + round(Int32, net.transfers[3][1].distance_meters), 100 + round(Int32, net.transfers[4][1].distance_meters), IM]
        @test res.non_transfer_walk_distance_meters[2, :] == [IM, 150, 100, 100, IM, IM, IM]

        # round 3: after riding route B
        @test res.times_at_stops_each_round[3, :] == [gt(7, 55), gt(7, 55), gt(8, 10), gt(8, 15),
            gt(8, 10) + round(Int64, net.transfers[3][1].duration_seconds),
            gt(8, 15) + round(Int64, net.transfers[4][1].duration_seconds),
            gt(9, 10)]

        # The 9:05 is coming from the longer transfer - the only non-transfer way to get to stop 6
        @test res.non_transfer_times_at_stops_each_round[3, :] == [MT, gt(8, 5), gt(8, 10), gt(8, 15), MT, gt(9, 5), gt(9, 10)]
        @test res.prev_trip[3, :] == [IM, IM, IM, IM, IM, 2, 2]
        @test res.prev_stop[3, :] == [IM, IM, IM, IM, IM, 5, 6]  # should have boarded at 6 - shorter walk - but to get to 6 via transit, boarded at 5
        @test res.prev_boardtime[3, :] == [IM, IM, IM, IM, IM, gt(9, 0), gt(9, 5)]
        @test res.transfer_prev_stop[3, :] == [IM, IM, IM, IM, IM, IM, IM]
        @test res.walk_distance_meters[3, :] == [150, 100, 100, 100,
            100 + round(Int32, net.transfers[3][1].distance_meters),
            100 + round(Int32, net.transfers[4][1].distance_meters),
            100 + round(Int32, net.transfers[4][1].distance_meters)
            ]
        # second non-transfer is 150 because you'd have to board at stop 1 to get here by transit
        @test res.non_transfer_walk_distance_meters[3, :] == [IM, 150, 100, 100,            
            IM, # can't get to 5 by transit
            100 + round(Int32, net.transfers[3][1].distance_meters), # 6 accessed via transfer at 5
            100 + round(Int32, net.transfers[4][1].distance_meters)]

    end
end