# This tests that local and express services that use the same stops
# work correctly

# Network looks like this:
# 
# 1==2==3==4==5==6==7==8
#  ===== ======== =====
#
# local service serves all stops, express only serves 1, 3, 6, 8
# Optimal trips:
# 1->6: express
# 2->4: local
# 2->6: local -> express
# 2->7: local -> express -> local

@testitem "Local and express" begin
    include("../test-includes.jl")

    gtfs = MockGTFS()
    stops = [add_stop!(gtfs) for _ in 1:8]
    routes = [add_route!(gtfs) for _ in 1:2]
    svc = add_service!(gtfs, 20230101, 20231231)

    # local service
    add_trip!(gtfs, routes[1], svc, (
        (stops[1], "7:50:00"),
        (stops[2], "8:00:00"),
        (stops[3], "8:10:00"),
        (stops[4], "8:20:00"),
        (stops[5], "8:30:00"),
        (stops[6], "8:42:00"), # give enough time to catch from express
        (stops[7], "8:50:00"),
        (stops[8], "9:00:00")
    ))

    add_trip!(gtfs, routes[1], svc, (
        (stops[1], "8:00:00"),
        (stops[2], "8:10:00"),
        (stops[3], "8:20:00"),
        (stops[4], "8:30:00"),
        (stops[5], "8:40:00"),
        (stops[6], "8:50:00"),
        (stops[7], "9:00:00"),
        (stops[8], "9:10:00")
    ))

    add_trip!(gtfs, routes[1], svc, (
        (stops[1], "8:10:00"),
        (stops[2], "8:20:00"),
        (stops[3], "8:30:00"),
        (stops[4], "8:40:00"),
        (stops[5], "8:50:00"),
        (stops[6], "9:00:00"),
        (stops[7], "9:10:00"),
        (stops[8], "9:20:00")
    ))

    # express trips
    add_trip!(gtfs, routes[2], svc, (
        (stops[1], "8:18:00"),
        (stops[3], "8:22:00"), # can catch from second local
        (stops[6], "8:39:00"), # can catch up to first local
        (stops[8], "8:45:00")
    ))

    add_trip!(gtfs, routes[2], svc, (
        (stops[1], "8:26:00"),
        (stops[3], "8:32:00"), # can catch from third local bus
        (stops[6], "8:45:00"), # can catch up to second local bus
        (stops[8], "8:55:00")
    ))

    with_gtfs(gtfs) do path
        net::TransitNetwork = with_logger(NullLogger()) do
            build_network([path])
        end

        #@testitem "From stop 1" begin
            res = raptor(net, [StopAndTime(1, gt(7, 55))], Date(2023, 4, 7))

            # round 1: access
            @test res.times_at_stops_each_round[1, :] == [gt(7, 55), MT, MT, MT, MT, MT, MT, MT]
            @test res.non_transfer_times_at_stops_each_round[1, :] == fill(MT, 8)
            @test res.prev_trip[1, :] == fill(IM, 8)
            @test res.prev_stop[1, :] == fill(IM, 8)
            @test res.prev_boardtime[1, :] == fill(IM, 8)
            @test res.transfer_prev_stop[1, :] == fill(IM, 8)

            # round 2: local and express ridden
            @test res.times_at_stops_each_round[2, :] == [
                gt(7, 55), 
                gt(8, 10),
                gt(8, 20), # local
                gt(8, 30),
                gt(8, 40),
                gt(8, 39), # express
                gt(9, 0),
                gt(8, 45) # express
            ]
            @test res.non_transfer_times_at_stops_each_round[2, :] == [
                MT, 
                gt(8, 10),
                gt(8, 20), # local
                gt(8, 30),
                gt(8, 40),
                gt(8, 39), # express
                gt(9, 0),
                gt(8, 45) # express
            ]

            @test res.prev_trip[2, :] == [IM, 2, 2, 2, 2, 4, 2, 4]
            @test res.prev_stop[2, :] == [IM, 1, 1, 1, 1, 1, 1, 1]
            @test res.prev_boardtime[2, :] == [IM, gt(8, 0), gt(8, 0), gt(8, 0), gt(8, 0), gt(8, 18), gt(8, 0), gt(8, 18)]

            # round 3: transfer from express to earlier local at stop 6
            @test res.times_at_stops_each_round[3, :] == [
                gt(7, 55), 
                gt(8, 10),
                gt(8, 20), # local
                gt(8, 30),
                gt(8, 40),
                gt(8, 39), # express
                gt(8, 50), # local from express
                gt(8, 45) # express
            ]

            @test res.non_transfer_times_at_stops_each_round[3, :] == [
                MT, 
                gt(8, 10),
                gt(8, 20), # local
                gt(8, 30),
                gt(8, 40),
                gt(8, 39), # express
                gt(8, 50), # local from express
                gt(8, 45) # express
            ]

            @test res.prev_trip[3, :] == [IM, IM, IM, IM, IM, IM, 1, IM]
            @test res.prev_stop[3, :] == [IM, IM, IM, IM, IM, IM, 6, IM]
            @test res.prev_boardtime[3, :] == [IM, IM, IM, IM, IM, IM, gt(8, 42), IM]
            @test res.transfer_prev_stop[3, :] == fill(IM, 8)

            test_no_updates_after_round(res, 3)
        #end

        #@testitem "From stop 2" begin
            res = raptor(net, [StopAndTime(2, gt(8, 5))], Date(2023, 4, 7))

            # round 1: access
            @test res.times_at_stops_each_round[1, :] == [MT, gt(8, 5), MT, MT, MT, MT, MT, MT]
            @test res.non_transfer_times_at_stops_each_round[1, :] == fill(MT, 8)
            @test res.prev_stop[1, :] == fill(IM, 8)
            @test res.prev_boardtime[1, :] == fill(IM, 8)
            @test res.prev_trip[1, :] == fill(IM, 8)
            @test res.transfer_prev_stop[1, :] == fill(IM, 8)

            # round 2: local ridden
            @test res.times_at_stops_each_round[2, :] == [
                MT,
                gt(8, 5),
                gt(8, 20),
                gt(8, 30),
                gt(8, 40),
                gt(8, 50),
                gt(9, 0),
                gt(9, 10)
            ]

            @test res.non_transfer_times_at_stops_each_round[2, :] == [
                MT,
                MT,
                gt(8, 20),
                gt(8, 30),
                gt(8, 40),
                gt(8, 50),
                gt(9, 0),
                gt(9, 10)
            ]

            @test res.prev_stop[2, :] == [IM, IM, 2, 2, 2, 2, 2, 2]
            @test res.prev_trip[2, :] == [IM, IM, 2, 2, 2, 2, 2, 2]
            @test res.prev_boardtime[2, :] == [IM, IM, fill(gt(8, 10), 6)...]
            @test res.transfer_prev_stop[2, :] == fill(IM, 8)

            # round 3: transfer to express
            @test res.times_at_stops_each_round[3, :] == [
                MT,
                gt(8, 5),
                gt(8, 20),
                gt(8, 30),
                gt(8, 40),
                gt(8, 39), # express
                gt(9, 0),
                gt(8, 45) # express
            ]

            @test res.non_transfer_times_at_stops_each_round[3, :] == [
                MT,
                MT,
                gt(8, 20),
                gt(8, 30),
                gt(8, 40),
                gt(8, 39), # express
                gt(9, 0),
                gt(8, 45) # express
            ]

            @test res.prev_trip[3, :] == [IM, IM, IM, IM, IM, 4, IM, 4]
            @test res.prev_stop[3, :] == [IM, IM, IM, IM, IM, 3, IM, 3]
            @test res.prev_boardtime[3, :] == [IM, IM, IM, IM, IM, gt(8, 22), IM, gt(8, 22)]
            @test res.transfer_prev_stop[3, :] == fill(IM, 8)

            # Round 4: transfer back to local bus at stop 6
            @test res.times_at_stops_each_round[4, :] == [
                MT,
                gt(8, 5),
                gt(8, 20),
                gt(8, 30),
                gt(8, 40),
                gt(8, 39), # express
                gt(8, 50), # first local
                gt(8, 45) # express
            ]

            @test res.non_transfer_times_at_stops_each_round[4, :] == [
                MT,
                MT,
                gt(8, 20),
                gt(8, 30),
                gt(8, 40),
                gt(8, 39), # express
                gt(8, 50), # first local
                gt(8, 45) # express
            ]

            @test res.prev_stop[4, :] == [IM, IM, IM, IM, IM, IM, 6, IM]
            @test res.prev_trip[4, :] == [IM, IM, IM, IM, IM, IM, 1, IM]
            @test res.prev_boardtime[4, :] == [IM, IM, IM, IM, IM, IM, gt(8, 42), IM]
            @test res.transfer_prev_stop[4, :] == fill(IM, 8)

            test_no_updates_after_round(res, 4)

        #end
    end
    
end