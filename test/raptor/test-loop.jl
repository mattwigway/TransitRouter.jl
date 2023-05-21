# this test ensures that a trip that serves the same stop twice works
# The loop route looks like this:
#
#  1===2===3==6
#      || ||
#      5===4
# 
# with stops served in the order 1-2-3-4-5-2-3-6
# 
# There are two runs, spaced close enough that getting off the second run at 2 allows you to board the previous run.
# Someone traveling 2 to 5 should always board before the loop.
#
# This seems like it would be unlikely to occur in the real world, but this is not necessarily the case - it may happen
# when a vehicle deviates around a block, into a shopping center, etc. For instance, consider the Amtrak Lakeland, FL
# station. It is served twice by the Silver Star, with a loop to Tampa in between. Amtrak solves the issue by having two
# logical station codes for the same physical station, depending on whether you're coming from the north or south, but
# such situations may exist in the real world without this type of allowance.

@testitem "Loop trip" begin
    include("../test-includes.jl")

    gtfs = MockGTFS()

    s = [add_stop!(gtfs) for _ in 1:6]
    r = add_route!(gtfs)
    svc = add_service!(gtfs, 20230101, 20231231)

    add_trip!(gtfs, r, svc, (
        (s[1], "8:00:00"),
        (s[2], "8:05:00"),
        (s[3], "8:10:00"),
        (s[4], "8:15:00"),
        (s[5], "8:20:00"),
        (s[2], "8:25:00"),
        (s[3], "8:30:00"),
        (s[6], "8:35:00")
    ))

    add_trip!(gtfs, r, svc, (
        (s[1], "8:15:00"),
        (s[2], "8:20:00"),
        (s[3], "8:25:00"),
        (s[4], "8:30:00"),
        (s[5], "8:35:00"),
        (s[2], "8:40:00"),
        (s[3], "8:45:00"),
        (s[6], "8:50:00")
    ))

    with_gtfs(gtfs) do path
        net::TransitNetwork = with_logger(NullLogger()) do
            build_network([path])
        end

        # from stop 1
        res = raptor([StopAndTime(1, gt(8, 10), 100)], net, Date(2023, 5, 22))

        @test res.times_at_stops_each_round[1:3, :] == [
        # stop 1       2          3          4          5           6          round
            gt(8, 10)  MT         MT         MT         MT          MT;       # 1 - access
            gt(8, 10)  gt(8, 20)  gt(8, 25)  gt(8, 30)  gt(8, 35)  gt(8, 50); # 2 - one seat ride
            gt(8, 10)  gt(8, 20)  gt(8, 25)  gt(8, 30)  gt(8, 35)  gt(8, 35); # 3 - catch up to prev
        ]

        @test res.non_transfer_times_at_stops_each_round[1:3, :] == [
        # stop 1       2          3          4          5           6          round
            MT         MT         MT         MT         MT          MT;       # 1 - access
            MT         gt(8, 20)  gt(8, 25)  gt(8, 30)  gt(8, 35)  gt(8, 50); # 2 - one seat ride
            MT         gt(8, 20)  gt(8, 25)  gt(8, 30)  gt(8, 35)  gt(8, 35); # 3 - catch up to prev
        ]

        @test res.prev_trip[1:3, :] == [
            # stop 1   2   3   4   5   6    round
                   IM  IM  IM  IM  IM  IM; # 1 - access
                   IM  2   2   2   2   2;  # 2 - could only catch second vehicle
                   IM  IM  IM  IM  IM  1;  # 3 - catch up to first
        ]
        
        @test res.prev_stop[1:3, :] == [
            # stop 1   2   3   4   5   6    round
                   IM  IM  IM  IM  IM  IM; # 1 - access
                   IM  1   1   1   1   1;  # 2 - could only catch second vehicle
                   IM  IM  IM  IM  IM  2;  # 3 - catch up to first
        ]

        test_no_updates_after_round(res, 3)

        # from stop 2
        res = raptor([StopAndTime(2, gt(8, 15), 100)], net, Date(2023, 5, 22))

        @test res.times_at_stops_each_round[1:2, :] == [
        # stop 1       2          3          4          5           6          round
               MT      gt(8, 15)  MT         MT         MT          MT
               MT      gt(8, 15)  gt(8, 25)  gt(8, 30)  gt(8, 35)   gt(8, 35)  # 2 - one seat ride - have to take second trip for 3-5, but can catch first trip for 6
        ]

        # stop 2 (board stop) reached via the loop for non-transfer times
        @test res.non_transfer_times_at_stops_each_round[1:2, :] == [
        # stop 1       2          3          4          5           6          round
               MT      MT         MT         MT         MT          MT
               MT      gt(8, 40)  gt(8, 25)  gt(8, 30)  gt(8, 35)   gt(8, 35)  # 2 - one seat ride - have to take second trip for 3-5, but can catch first trip for 6
        ]

        @test res.prev_trip[1:2, :] == [
            # stop 1   2   3   4   5   6    round
                   IM  IM  IM  IM  IM  IM; # 1 - access
                   IM  2  2   2   2   1;  # 2 - catch second vehicle for 3-5, first for 6
        ]
        
        @test res.prev_stop[1:2, :] == [
            # stop 1   2   3   4   5   6    round
                   IM  IM  IM  IM  IM  IM; # 1 - access
                   IM  2   2   2   2   2;  # 2 - could only catch second vehicle
        ]

        test_no_updates_after_round(res, 2)
    end
end