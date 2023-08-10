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
# However, a trip departing 2 at 00:15 on Tuesday should wait until midnight (A does not run until Tuesday night/Wednesday morning)
# Similarly, a trip departing 3 at 00:15 on Thursday should fail to route

@testitem "Overnight routing" begin
    include("../test-includes.jl")

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

        #@testitem "Tuesday night" begin
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

            # make sure that trace works with an overnight trip
            path, boardstop = trace_path(net, res, 4)
            @test get_routes(path) == routes
            @test get_transit_times(path) == [DateTime(2023, 5, 2, 23, 55), DateTime(2023, 5, 3, 0, 30), DateTime(2023, 5, 3, 0, 35), DateTime(2023, 5, 3, 0, 40)]

        #end

        #@testitem "Wednesday morning" begin
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

            path, boardstop = trace_path(net, res, 4)
            @test get_routes(path) == routes
            @test get_transit_times(path) == [DateTime(2023, 5, 3, 0, 20), DateTime(2023, 5, 3, 0, 30), DateTime(2023, 5, 3, 0, 35), DateTime(2023, 5, 3, 0, 40)]
        #end

        #@testitem "Tuesday morning" begin
            # on tuesday morning, routing should succeed, but only by waiting until Tuesday night
            res = raptor(net, [StopAndTime(2, gt(0, 15))], Date(2023, 5, 2))

            # round 1: access
            @test res.times_at_stops_each_round[1, :] == [MT, gt(0, 15), MT, MT]
            @test res.non_transfer_times_at_stops_each_round[1, :] == fill(MT, 4)
            @test res.prev_trip[1, :] == fill(IM, 4)
            @test res.prev_stop[1, :] == fill(IM, 4)
            @test res.prev_boardtime[1, :] == fill(IM, 4)
            @test res.transfer_prev_stop[1, :] == fill(IM, 4)

            # round 2: rode route A
            @test res.times_at_stops_each_round[2, :] == [MT, gt(0, 15), gt(24, 30), MT]
            @test res.non_transfer_times_at_stops_each_round[2, :] == [MT, MT, gt(24, 30), MT]
            @test res.prev_trip[2, :] == [IM, IM, 1, IM]
            @test res.prev_stop[2, :] == [IM, IM, 2, IM]
            @test res.prev_boardtime[2, :] == [IM, IM, gt(24, 20), IM]
            @test res.transfer_prev_stop[2, :] == fill(IM, 4)

            # round 3: rode route B (from next service day)
            @test res.times_at_stops_each_round[3, :] == [MT, gt(0, 15), gt(24, 30), gt(24, 40)]
            @test res.non_transfer_times_at_stops_each_round[3, :] == [MT, MT, gt(24, 30), gt(24, 40)]
            @test res.prev_stop[3, :] == [IM, IM, IM, 3]
            @test res.prev_trip[3, :] == [IM, IM, IM, 2]
            @test res.prev_boardtime[3, :] == [IM, IM, IM, gt(24, 35)]
            @test res.transfer_prev_stop[3, :] == fill(IM, 4)

            test_no_updates_after_round(res, 3)
        #end

        #@testitem "Thursday morning" begin
            # On thursday morning, routing should fail - previous service day service doesn't run late enough
            res = raptor(net, [StopAndTime(3, gt(0, 15))], Date(2023, 5, 4))

            # round 1: access
            @test res.times_at_stops_each_round[1, :] == [MT, MT, gt(0, 15), MT]
            @test res.non_transfer_times_at_stops_each_round[1, :] == fill(MT, 4)
            @test res.prev_trip[1, :] == fill(IM, 4)
            @test res.prev_stop[1, :] == fill(IM, 4)
            @test res.prev_boardtime[1, :] == fill(IM, 4)
            @test res.transfer_prev_stop[1, :] == fill(IM, 4)

            # no transit riding occurred
            test_no_updates_after_round(res, 1)
        #end
    end
end

# This is a test for issue 39, which involved double counting of stop time offsets.
# The full description from that issue (note that the problem referenced is of course now fixed):

# Sometimes the best trip is not selected in overnight routing. The issue appears to be on line 331 of raptor.jl:

#  if current_trip_arrival_time::Int32 + stop_time_offset < result.non_transfer_times_at_stops_each_round[target, stop]

# The issue here is that stop_time_offset has already been added to current_trip_arrival_time. For same-day trips,
# this is a no-op, as stop_time_offset is 0, but for overnight trips this means trips from the next day are treated
# as arriving too late, and trips from the previous day are treated as arriving too early. The times are recorded correctly
# into non_transfer_times, though. In a case where there is a next-day trip, the first trip explored will generally be selected,
# as even with the double stop time offset it will be less than MAX_TIME. However, any additional trips (even if they arrive
# earlier) will have the double stop-time offset compared to the correct existing time in non-transfer times, and will almost
# never be selected; the first trip explored will generally be chosen even if there is a better trip (the only exception, I think,
# is trips more than 24 hours long - but even then there's no guarantee the right trip would be selected, just maybe not the first
# one explored). For trips from the previous day, the reverse is true - the last trip explored will be selected.

# This tests the issue with a simple network with two stops and two trips running in the morning, and a departure time in the
# evening to force next-day arrival. The later trip is coded first in the GTFS. The routing engine will discover it first,
# but should replace it with the earlier trip. The trips must be on separate patterns, as within explore_pattern only the first trip
# will be boarded.
@testitem "Multiple overnight routing" begin
    include("../test-includes.jl")

    gtfs = MockGTFS()

    r = add_route!(gtfs)
    svc = add_service!(gtfs, 20230101, 20231231)
    s1, s2, s3 = [add_stop!(gtfs) for _ in 1:3]

    # later trip
    add_trip!(gtfs, r, svc, [
        (s1, "09:00:00"),
        (s2, "09:30:00")
    ])
    
    # earlier trip
    add_trip!(gtfs, r, svc, [
        (s1, "08:00:00"),
        (s2, "08:30:00"),
        (s3, "08:40:00")
    ])

    with_gtfs(gtfs) do path
        net::TransitNetwork = with_logger(NullLogger()) do
            build_network([path])
        end

        res = raptor([StopAndTime(1, gt(19, 30))], net, Date(2023, 5, 2))

        # we should arrive at s2 on trip 2, at 8:30
        @test res.non_transfer_times_at_stops_each_round[2, 2] == gt(8, 30) + TransitRouter.SECONDS_PER_DAY
        @test res.prev_trip[2, 2] == 2
    end
end