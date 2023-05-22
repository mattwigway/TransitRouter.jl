# Provides a test for whether pickup and dropoff types work correctly
# Network looks like this:
#  1==2==3==4==5
# There are several trips serving stops 1 through 5
# Trip 1 has no pickup allowed at 1 and no dropoff allowed at 3
# Trip 2 has pickup allowed at 1, but no dropoff allowed at 3
# Trip 3 has no pickup allowed at 1, but dropoff allowed at 3
# pickup/dropoff types at 2 are all 2, pickup/dropoff types at 4 are all 3 - these should not affect routing
# stop 5 has an invalid dropoff type
@testitem "Pickup/dropoff type" begin
    include("../test-includes.jl")
    import TransitRouter: PickupDropoffType

    gtfs = MockGTFS()

    stops = [add_stop!(gtfs) for _ in 1:5]
    service = add_service!(gtfs, 20230101, 20231231)
    route = add_route!(gtfs)

    add_trip!(gtfs, route, service, (
        (stops[1], "8:00:00", "8:00:00", 1, 0),
        (stops[2], "8:05:00", "8:05:00", 2, 2),
        (stops[3], "8:10:00", "8:10:00", 0, 1),
        (stops[4], "8:15:00", "8:15:00", 3, 3),
        (stops[5], "8:20:00", "8:20:00", 3, 5)
    ))

    add_trip!(gtfs, route, service, (
        (stops[1], "9:00:00", "9:00:00", 0, 0),
        (stops[2], "9:05:00", "9:05:00", 2, 2),
        (stops[3], "9:10:00", "9:10:00", 0, 1),
        (stops[4], "9:15:00", "9:15:00", 3, 3),
        (stops[5], "9:20:00", "9:20:00", 3, 5)
    ))

    add_trip!(gtfs, route, service, (
        (stops[1], "10:00:00", "10:00:00", 1, 0),
        (stops[2], "10:05:00", "10:05:00", 2, 2),
        (stops[3], "10:10:00", "10:10:00", 0, 0),
        (stops[4], "10:15:00", "10:15:00", 3, 3),
        (stops[5], "10:20:00", "10:20:00", 3, 5)
    ))

    with_gtfs(gtfs) do path
        net = with_logger(NullLogger()) do 
            build_network([path])
        end

        # each trip should be its own pattern
        @test length(net.patterns) == 3

        # from stop 1
        res = raptor([StopAndTime(1, gt(7, 55), 100)], net, Date(2023, 5, 18))

        @test res.times_at_stops_each_round[1:3, :] == [
            gt(7, 55)  MT         MT          MT          MT;  # round 1: access only
            gt(7, 55)  gt(9, 5)   MT          gt(9, 15)   gt(9, 20); # round 2: stops 2, 4, 5 reached via Trip 2. Trip does not allow pickup at 1, and trip 2 does not allow dropoff 3. Trip 3 does not allow pickup at 1
            gt(7, 55)  gt(9, 5)   gt(10, 10)  gt(9, 15)   gt(9, 20) # round 3: stop 3 reached via transfer
        ]
        
        # no on-street transfers, non-transfer times should be identical except access
        @test res.non_transfer_times_at_stops_each_round[1:3, :] == [
            MT         MT         MT          MT          MT;  # round 1: access only
            MT         gt(9, 5)   MT          gt(9, 15)   gt(9, 20); # round 2: stops 2, 4, 5 reached via Trip 2. Trip does not allow pickup at 1, and trip 2 does not allow dropoff 3. Trip 3 does not allow pickup at 1
            MT         gt(9, 5)   gt(10, 10)  gt(9, 15)   gt(9, 20) # round 3: stop 3 reached via transfer
        ]

        @test res.prev_trip[1:3, :] == [
            IM  IM  IM  IM  IM; # no transit ridden
            IM  2   IM  2   2 ; # see comments above
            IM  IM  3   IM  IM;
        ]

        @test res.prev_stop[1:3, :] == [
            IM  IM  IM  IM  IM;
            IM  1   IM  1   1 ;
            IM  IM  2   IM  IM;  # transfer from trip 2 at stop 2
        ]

        # no transfers
        @test all(res.transfer_prev_stop .== IM)

        test_no_updates_after_round(res, 3)

        # from stop 2, to test pickup types. Everything except 1 is treated the same way.
        # trip 1 is now a possibility for everything except stop 3, and no transfers are neeed as all trips
        # pick up at stop 2.
        res = raptor([StopAndTime(2, gt(7, 55), 100)], net, Date(2023, 5, 18))

        @test res.times_at_stops_each_round[1:2, :] == [
            MT  gt(7, 55)  MT        MT        MT;        # access
            MT  gt(7, 55)  gt(10, 10) gt(8, 15) gt(8, 20); # stop 3 requires waiting for trip 3 as trip 2does not allow dropoff
        ]

        @test res.non_transfer_times_at_stops_each_round[1:2, :] == [
            MT  MT  MT        MT        MT;        # access
            MT  MT  gt(10, 10) gt(8, 15) gt(8, 20); # stop 3 requires waiting for trip 3 as trip 1/2 does not allow dropoff
        ]

        @test res.prev_trip[1:2, :] == [
            IM  IM  IM  IM  IM;
            IM  IM  3   1   1
        ]

        @test res.prev_stop[1:2, :] == [
            IM  IM  IM  IM  IM;
            IM  IM  2   2   2;
        ]

        test_no_updates_after_round(res, 2)

        # from stop 4, to test pickup types.
        # should reach stop 5 with trip 1
        res = raptor([StopAndTime(4, gt(7, 55), 100)], net, Date(2023, 5, 18))

        @test res.times_at_stops_each_round[1:2, :] == [
            MT  MT  MT  gt(7, 55)  MT;
            MT  MT  MT  gt(7, 55)  gt(8, 20);
        ]

        @test res.non_transfer_times_at_stops_each_round[1:2, :] == [
            MT  MT  MT  MT  MT;
            MT  MT  MT  MT  gt(8, 20);
        ]

        @test res.prev_trip[1:2, :] == [
            IM  IM  IM  IM  IM;
            IM  IM  IM  IM  1;
        ]

        @test res.prev_stop[1:2, :] == [
            IM  IM  IM  IM  IM;
            IM  IM  IM  IM  4;
        ]

        test_no_updates_after_round(res, 2)

        @test PickupDropoffType.parse("0") == PickupDropoffType.Scheduled
        @test PickupDropoffType.parse("") == PickupDropoffType.Scheduled
        @test PickupDropoffType.parse(nothing) == PickupDropoffType.Scheduled
        @test PickupDropoffType.parse(missing) == PickupDropoffType.Scheduled
        @test PickupDropoffType.parse("1") == PickupDropoffType.NotAvailable
        @test PickupDropoffType.parse(1)   == PickupDropoffType.NotAvailable
        @test PickupDropoffType.parse("2") == PickupDropoffType.PhoneAgency
        @test PickupDropoffType.parse(2)   == PickupDropoffType.PhoneAgency
        @test PickupDropoffType.parse("3") == PickupDropoffType.CoordinateWithDriver
        @test PickupDropoffType.parse(3)   == PickupDropoffType.CoordinateWithDriver
        @test PickupDropoffType.parse("4") == PickupDropoffType.Scheduled
        @test PickupDropoffType.parse(4)   == PickupDropoffType.Scheduled
        @test_logs (:warn, "Unknown pickup/dropoff type 4, assuming regularly scheduled") PickupDropoffType.parse("4")
        @test_logs (:warn, "Unknown pickup/dropoff type 4, assuming regularly scheduled") PickupDropoffType.parse(4)
        @test PickupDropoffType.parse("test")   == PickupDropoffType.Scheduled
        @test_logs (:warn, "Unknown pickup/dropoff type test, assuming regularly scheduled") PickupDropoffType.parse("test")



    end
end