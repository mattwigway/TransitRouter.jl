# Test that the router uses only services that are running on the date requested
# Network looks like this:
#  1 -a- 2 -b- 3
#   \____c____/
# Route C runs only on weekdays. It also has removed service on July 4, and added service
# on April 8, 2023 (a saturday). Other routes run all the time.

# This test is currently broken due to the implementation of overnight routing.
# plaes where we expect to not find a route, we find a route that involves waiting until tomorrow.
@testset "RAPTOR service running" begin
    gtfs = MockGTFS()
    sids = [add_stop!(gtfs) for i in 1:3]
    rids = [add_route!(gtfs) for i in 1:3]
    
    every_day = add_service!(gtfs, 20230101, 20231231)
    weekdays_only = add_service!(gtfs, 20230101, 20231231, sunday=0, saturday=0, exceptions=(
        (20230704, 2), # no service July 4
        (20230705, 2), # no service July 5 (so we don't get tripped up by overnight routing letting the July 4 trips wait for July 5)
        (20230408, 1) # but it does run April 8 (Saturday)
    ))

    add_trip!(gtfs, rids[1], every_day, (
        (sids[1], "8:00:00"),
        (sids[2], "8:40:00")
    ))

    add_trip!(gtfs, rids[2], every_day, (
        (sids[2], "8:55:00"),
        (sids[3], "9:35:00")
    ))

    add_trip!(gtfs, rids[3], weekdays_only, (
        (sids[1], "8:05:00"),
        (sids[3], "8:45:00")
    ))

    with_gtfs(gtfs) do path
        net::TransitNetwork = with_logger(NullLogger()) do
            build_network([path])
        end

        s1, s2, s3 = getindex.(Ref(net.stopidx_for_id), ["$path:$s" for s in sids])
        ra, rb, rc = getindex.(Ref(net.routeidx_for_id), ["$path:$r" for r in rids])

        weekday_result = raptor(net, [StopAndTime(s1, gt(7, 55))], Date(2023, 4, 7))
        weekend_result = raptor(net, [StopAndTime(s1, gt(7, 55))], Date(2023, 4, 1))
        added_weekend = raptor(net, [StopAndTime(s1, gt(7, 55))], Date(2023, 4, 8))
        removed_weekday = raptor(net, [StopAndTime(s1, gt(7, 55))], Date(2023, 7, 4))

        ###################
        # Weekday results #
        ###################

        # Stop 1: accessed via access leg round 1, no transit or transfer access
        # times_at_stops does not include record for last round, since we don't do a transfer phase after the last round
        # only non_transfer_times is updated
        @test weekday_result.times_at_stops_each_round[:, s1] == fill(gt(7, 55), 4)
        @test weekday_result.non_transfer_times_at_stops_each_round[:, s1] == fill(MAX_TIME, 5)
        @test weekday_result.prev_stop[:, s1] == fill(INT_MISSING, 5)
        @test get_route.(weekday_result.prev_trip[:, s1], Ref(net)) == fill(INT_MISSING, 5)
        @test weekday_result.prev_boardtime[:, s1] == fill(INT_MISSING, 5)
        @test weekday_result.transfer_prev_stop[:, s1] == fill(INT_MISSING, 5)

        # Stop 2: accessed via transit round 2
        @test weekday_result.times_at_stops_each_round[:, s2] == [MAX_TIME, fill(gt(8, 40), 3)...]
        @test weekday_result.non_transfer_times_at_stops_each_round[:, s2] == [MAX_TIME, fill(gt(8, 40), 4)...]
        @test weekday_result.prev_stop[:, s2] == [INT_MISSING, s1, fill(INT_MISSING, 3)...]
        @test get_route.(weekday_result.prev_trip[:, s2], Ref(net)) == [INT_MISSING, ra, fill(INT_MISSING, 3)...]
        @test weekday_result.prev_boardtime[:, s2] == [INT_MISSING, gt(8, 0), fill(INT_MISSING, 3)...]
        @test weekday_result.transfer_prev_stop[:, s2] == fill(INT_MISSING, 5)

        # Stop 3: accessed via transit round 2 (via route c)
        @test weekday_result.times_at_stops_each_round[:, s3] == [MAX_TIME, fill(gt(8, 45), 3)...]
        @test weekday_result.non_transfer_times_at_stops_each_round[:, s3] == [MAX_TIME, fill(gt(8, 45), 4)...]
        @test weekday_result.prev_stop[:, s3] == [INT_MISSING, s1, fill(INT_MISSING, 3)...]
        @test get_route.(weekday_result.prev_trip[:, s3], Ref(net)) == [INT_MISSING, rc, fill(INT_MISSING, 3)...]
        @test weekday_result.prev_boardtime[:, s3] == [INT_MISSING, gt(8, 5), fill(INT_MISSING, 3)...]
        @test weekday_result.transfer_prev_stop[:, s3] == fill(INT_MISSING, 5)


        ###################
        # Weekend results #
        ###################
        
        # Stop 1: accessed via access leg round 1, no transit or transfer access
        @test weekend_result.times_at_stops_each_round[:, s1] == fill(gt(7, 55), 4)
        @test weekend_result.non_transfer_times_at_stops_each_round[:, s1] == fill(MAX_TIME, 5)
        @test weekend_result.prev_stop[:, s1] == fill(INT_MISSING, 5)
        @test get_route.(weekend_result.prev_trip[:, s1], Ref(net)) == fill(INT_MISSING, 5)
        @test weekend_result.prev_boardtime[:, s1] == fill(INT_MISSING, 5)
        @test weekend_result.transfer_prev_stop[:, s1] == fill(INT_MISSING, 5)

        # Stop 2: accessed via transit round 2
        @test weekend_result.times_at_stops_each_round[:, s2] == [MAX_TIME, fill(gt(8, 40), 3)...]
        @test weekend_result.non_transfer_times_at_stops_each_round[:, s2] == [MAX_TIME, fill(gt(8, 40), 4)...]
        @test weekend_result.prev_stop[:, s2] == [INT_MISSING, s1, fill(INT_MISSING, 3)...]
        @test get_route.(weekend_result.prev_trip[:, s2], Ref(net)) == [INT_MISSING, ra, fill(INT_MISSING, 3)...]
        @test weekend_result.prev_boardtime[:, s2] == [INT_MISSING, gt(8, 0), fill(INT_MISSING, 3)...]
        @test weekend_result.transfer_prev_stop[:, s2] == fill(INT_MISSING, 5)

        # Stop 3: accessed via transit round 3 (via route b)
        @test weekend_result.times_at_stops_each_round[:, s3] == [MAX_TIME, MAX_TIME, gt(9, 35), gt(9, 35)]
        @test weekend_result.non_transfer_times_at_stops_each_round[:, s3] == [MAX_TIME, MAX_TIME, fill(gt(9, 35), 3)...]
        @test weekend_result.prev_stop[:, s3] == [INT_MISSING, INT_MISSING, s2, fill(INT_MISSING, 2)...]
        @test get_route.(weekend_result.prev_trip[:, s3], Ref(net)) == [INT_MISSING, INT_MISSING, rb, fill(INT_MISSING, 2)...]
        @test weekend_result.prev_boardtime[:, s3] == [INT_MISSING, INT_MISSING, gt(8, 55), fill(INT_MISSING, 2)...]
        @test weekend_result.transfer_prev_stop[:, s3] == fill(INT_MISSING, 5)

        # July 4 results should be same as weekend results
        @test removed_weekday.times_at_stops_each_round == weekend_result.times_at_stops_each_round
        @test removed_weekday.non_transfer_times_at_stops_each_round == weekend_result.non_transfer_times_at_stops_each_round
        @test removed_weekday.prev_stop == weekend_result.prev_stop
        @test removed_weekday.prev_boardtime == weekend_result.prev_boardtime
        @test removed_weekday.prev_trip == weekend_result.prev_trip
        @test removed_weekday.transfer_prev_stop == weekend_result.transfer_prev_stop

        # April 8 results should be same as weekday results
        @test added_weekend.times_at_stops_each_round == weekday_result.times_at_stops_each_round
        @test added_weekend.non_transfer_times_at_stops_each_round == weekday_result.non_transfer_times_at_stops_each_round
        @test added_weekend.prev_stop == weekday_result.prev_stop
        @test added_weekend.prev_boardtime == weekday_result.prev_boardtime
        @test added_weekend.prev_trip == weekday_result.prev_trip
        @test added_weekend.transfer_prev_stop == weekday_result.transfer_prev_stop
    end
end