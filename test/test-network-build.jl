function build_gtfs()
    gtfs = MockGTFS()

    # add a few stops
    downtown = add_stop!(gtfs, 35.9932, -78.8975, stop_name="Downtown", stop_id="dtn")
    nccu = add_stop!(gtfs, 35.9728, -78.8952, stop_name="NCCU", stop_id="nccu")
    lowes = add_stop!(gtfs, 35.9409, -78.9078, stop_name="Lowes", stop_id="lowes")
    rtp = add_stop!(gtfs, 35.9208, -78.8751, stop_name="RTP", stop_id="rtp")
    rtp2 = add_stop!(gtfs, 35.9218, -78.8751, stop_name="RTP2", stop_id="rtp2")

    fayetteville = add_route!(gtfs, "Fayetteville", route_id="ftv")
    rtp_express = add_route!(gtfs, "RTP Express", route_id="rtpx")

    every_day = add_service!(gtfs, 20230101, 20231231, service_id="every_day", exceptions=(
        (20230704, 2), # no service July 4
    ))

    weekdays_only = add_service!(gtfs, 20230101, 20231231, service_id="weekdays_only",
        saturday=0,
        sunday=0,
        exceptions=(
            (20230704, 2), # no service July 4
            (20230408, 1) # but it does run April 8 (Saturday)
        ))

    all_calendar_dates = add_service!(gtfs, 0, 0, service_id="dates_only", write_calendar_entry=false, exceptions=(
        (20230201, 1),
        (20230202, 1)
    ))

    # add a few trips to the routes
    # the pattern Downtown -> NCCU -> Lowes -> RTP should have two trips
    add_trip!(gtfs, fayetteville, every_day, (
        (downtown, "08:00:00"),
        (nccu, "08:12:00"),
        (lowes, "08:18:00"),
        (rtp, "08:21:00")
    ), trip_id="f1")

    add_trip!(gtfs, fayetteville, every_day, (
        (downtown, "08:05:00"),
        (nccu, "08:17:00"),
        (lowes, "08:23:00"),
        (rtp, "08:40:00")
    ), trip_id="f2")

    # The opposite pattern also has two, but should end up in separate
    # patterns because they don't run the same days
    add_trip!(gtfs, fayetteville, every_day, (
        (rtp, "16:00:00"),
        (lowes, "16:10:00"),
        (nccu, "16:15:00"),
        (downtown, "16:22:00")
    ), trip_id="f-1")

    add_trip!(gtfs, fayetteville, weekdays_only, (
        (rtp, "17:00:00"),
        (lowes, "17:10:00"),
        (nccu, "17:15:00"),
        (downtown, "17:22:00")
    ), trip_id="f-2")

    return gtfs
end

@testset "Network build" begin
    gtfs = build_gtfs()

    with_gtfs(gtfs) do gtfspath
        net::TransitNetwork = build_network([gtfspath])

        # Check stops - four stops read, stop names and locations read correctly
        downtown = net.stopidx_for_id["$(gtfspath):dtn"]
        nccu = net.stopidx_for_id["$(gtfspath):nccu"]
        lowes = net.stopidx_for_id["$(gtfspath):lowes"]
        rtp = net.stopidx_for_id["$(gtfspath):rtp"]
        rtp2 = net.stopidx_for_id["$(gtfspath):rtp2"]
        @testset "Stops" begin
            @test length(net.stops) == 5
            @test net.stops[downtown].stop_name == "Downtown"
            @test net.stops[downtown].stop_lat == 35.9932
            @test net.stops[downtown].stop_lon == -78.8975
        end

        @testset "Routes" begin
            @test length(net.routes) == 2
            fayetteville = net.routes[net.routeidx_for_id["$(gtfspath):ftv"]]
            @test fayetteville.route_short_name == "Fayetteville"
        end

        @testset "Calendar and calendar dates" begin
            every_day = net.services[net.serviceidx_for_id["$(gtfspath):every_day"]]

            # every day of 2023, except July 4
            for date in Date(2023, 1, 1):Day(1):Date(2023, 12, 31)
                @test TransitRouter.is_service_running(every_day, date) == (date != Date(2023, 7, 4))
            end

            # not 2022 or 2024
            @test !TransitRouter.is_service_running(every_day, Date(2022, 12, 31))
            @test !TransitRouter.is_service_running(every_day, Date(2024, 1, 1))

            weekdays = net.services[net.serviceidx_for_id["$(gtfspath):weekdays_only"]]

            for date in Date(2023, 1, 1):Day(1):Date(2023, 12, 31)
                @test TransitRouter.is_service_running(weekdays, date) == ((
                        dayofweek(date) ≤ 5 &&
                        # service removed July 4
                        date != Date(2023, 7, 4)
                    # service added April 8 (Sat)
                    ) || (date == Date(2023, 4, 8)))
            end

            @test !TransitRouter.is_service_running(weekdays, Date(2022, 12, 30)) # 12/31 was a Saturday
            @test !TransitRouter.is_service_running(weekdays, Date(2024, 1, 1))

            calendar_only = net.services[net.serviceidx_for_id["$(gtfspath):dates_only"]]

            for date in Date(2023, 1, 1):Day(1):Date(2023, 12, 31)
                @test TransitRouter.is_service_running(calendar_only, date) == (date ∈ [Date(2023, 2, 1), Date(2023, 2, 2)])
            end

            # make sure it wasn't applied to other years
            @test !TransitRouter.is_service_running(calendar_only, Date(2022, 2, 1))
            @test !TransitRouter.is_service_running(calendar_only, Date(2024, 2, 1))
        end

        @testset "Trips and patterns" begin
            @test length(net.trips) == 4
            @test length(net.patterns) == 3

            downtown_rtp = findall(map(p -> p.stops == [downtown, nccu, lowes, rtp], net.patterns))
            @test length(downtown_rtp) == 1
            @test net.patterns[downtown_rtp[1]].service == net.serviceidx_for_id["$(gtfspath):every_day"]

            # should be two trips
            downtown_rtp_trips = map(x -> net.trips[x], net.trips_for_pattern[downtown_rtp[1]])
            println(downtown_rtp_trips)
            
            @test length(downtown_rtp_trips) == 2

            for trip in downtown_rtp_trips
                @test trip.route == net.routeidx_for_id["$(gtfspath):ftv"]
                @test trip.service == net.serviceidx_for_id["$(gtfspath):every_day"]
                
                @test length(trip.stop_times) == 4
                @test trip.stop_times[1].stop == downtown
                @test trip.stop_times[2].stop == nccu
                @test trip.stop_times[3].stop == lowes
                @test trip.stop_times[4].stop == rtp
            end

            # force them into order
            sort!(downtown_rtp_trips, by=x->x.stop_times[1].departure_time)
            
            @test downtown_rtp_trips[1].stop_times[1].departure_time == TransitRouter.time_to_seconds_since_midnight(Time(8, 0))
            @test downtown_rtp_trips[1].stop_times[2].departure_time == TransitRouter.time_to_seconds_since_midnight(Time(8, 12))
            @test downtown_rtp_trips[1].stop_times[3].departure_time == TransitRouter.time_to_seconds_since_midnight(Time(8, 18))
            @test downtown_rtp_trips[1].stop_times[4].departure_time == TransitRouter.time_to_seconds_since_midnight(Time(8, 21))

            @test downtown_rtp_trips[2].stop_times[1].departure_time == TransitRouter.time_to_seconds_since_midnight(Time(8, 5))
            @test downtown_rtp_trips[2].stop_times[2].departure_time == TransitRouter.time_to_seconds_since_midnight(Time(8, 17))
            @test downtown_rtp_trips[2].stop_times[3].departure_time == TransitRouter.time_to_seconds_since_midnight(Time(8, 23))
            @test downtown_rtp_trips[2].stop_times[4].departure_time == TransitRouter.time_to_seconds_since_midnight(Time(8, 40))

            @test downtown_rtp_trips[1].stop_times[1].arrival_time == TransitRouter.time_to_seconds_since_midnight(Time(8, 0))
            @test downtown_rtp_trips[1].stop_times[2].arrival_time == TransitRouter.time_to_seconds_since_midnight(Time(8, 12))
            @test downtown_rtp_trips[1].stop_times[3].arrival_time == TransitRouter.time_to_seconds_since_midnight(Time(8, 18))
            @test downtown_rtp_trips[1].stop_times[4].arrival_time == TransitRouter.time_to_seconds_since_midnight(Time(8, 21))

            @test downtown_rtp_trips[2].stop_times[1].arrival_time == TransitRouter.time_to_seconds_since_midnight(Time(8, 5))
            @test downtown_rtp_trips[2].stop_times[2].arrival_time == TransitRouter.time_to_seconds_since_midnight(Time(8, 17))
            @test downtown_rtp_trips[2].stop_times[3].arrival_time == TransitRouter.time_to_seconds_since_midnight(Time(8, 23))
            @test downtown_rtp_trips[2].stop_times[4].arrival_time == TransitRouter.time_to_seconds_since_midnight(Time(8, 40))
        
            # there should be two patterns for this because they have different services
            rtp_downtown = findall(map(p -> p.stops == [rtp, lowes, nccu, downtown], net.patterns))
            @test length(rtp_downtown) == 2

            # these depend on order. Possible they would get reversed in the future, causing this
            # test to fail.
            @test net.patterns[rtp_downtown[1]].service == net.serviceidx_for_id["$(gtfspath):every_day"]
            @test net.patterns[rtp_downtown[2]].service == net.serviceidx_for_id["$(gtfspath):weekdays_only"]

            @test length(net.trips_for_pattern[rtp_downtown[1]]) == 1
            @test length(net.trips_for_pattern[rtp_downtown[2]]) == 1

            trip_1 = net.trips[net.trips_for_pattern[rtp_downtown[1]][1]]
            @test trip_1.stop_times[1].stop == rtp
            @test trip_1.stop_times[2].stop == lowes
            @test trip_1.stop_times[3].stop == nccu
            @test trip_1.stop_times[4].stop == downtown

            @test trip_1.stop_times[1].arrival_time == TransitRouter.time_to_seconds_since_midnight(Time(16, 0))
            @test trip_1.stop_times[2].arrival_time == TransitRouter.time_to_seconds_since_midnight(Time(16, 10))
            @test trip_1.stop_times[3].arrival_time == TransitRouter.time_to_seconds_since_midnight(Time(16, 15))
            @test trip_1.stop_times[4].arrival_time == TransitRouter.time_to_seconds_since_midnight(Time(16, 22))

            @test trip_1.stop_times[1].departure_time == TransitRouter.time_to_seconds_since_midnight(Time(16, 0))
            @test trip_1.stop_times[2].departure_time == TransitRouter.time_to_seconds_since_midnight(Time(16, 10))
            @test trip_1.stop_times[3].departure_time == TransitRouter.time_to_seconds_since_midnight(Time(16, 15))
            @test trip_1.stop_times[4].departure_time == TransitRouter.time_to_seconds_since_midnight(Time(16, 22))


            trip_2 = net.trips[net.trips_for_pattern[rtp_downtown[2]][1]]
            @test trip_2.stop_times[1].stop == rtp
            @test trip_2.stop_times[2].stop == lowes
            @test trip_2.stop_times[3].stop == nccu
            @test trip_2.stop_times[4].stop == downtown

            @test trip_2.stop_times[1].arrival_time == TransitRouter.time_to_seconds_since_midnight(Time(17, 0))
            @test trip_2.stop_times[2].arrival_time == TransitRouter.time_to_seconds_since_midnight(Time(17, 10))
            @test trip_2.stop_times[3].arrival_time == TransitRouter.time_to_seconds_since_midnight(Time(17, 15))
            @test trip_2.stop_times[4].arrival_time == TransitRouter.time_to_seconds_since_midnight(Time(17, 22))

            @test trip_2.stop_times[1].departure_time == TransitRouter.time_to_seconds_since_midnight(Time(17, 0))
            @test trip_2.stop_times[2].departure_time == TransitRouter.time_to_seconds_since_midnight(Time(17, 10))
            @test trip_2.stop_times[3].departure_time == TransitRouter.time_to_seconds_since_midnight(Time(17, 15))
            @test trip_2.stop_times[4].departure_time == TransitRouter.time_to_seconds_since_midnight(Time(17, 22))
        end

        @testset "Transfers" begin
            @test length(collect(Iterators.flatten(net.transfers))) == 2
            expected_distance = euclidean_distance(LatLon(35.9208, -78.8751), LatLon(35.9218, -78.8751))

            @test length(net.transfers[rtp]) == 1
            @test net.transfers[rtp][1].target_stop == rtp2
            @test net.transfers[rtp][1].distance_meters ≈ expected_distance
            @test net.transfers[rtp][1].duration_seconds ≈ expected_distance / TransitRouter.DEFAULT_WALK_SPEED_METERS_PER_SECOND
            @test net.transfers[rtp][1].geometry == [LatLon(35.9208, -78.8751), LatLon(35.9218, -78.8751)]

            @test length(net.transfers[rtp2]) == 1
            @test net.transfers[rtp2][1].target_stop == rtp
            @test net.transfers[rtp2][1].distance_meters ≈ expected_distance
            @test net.transfers[rtp2][1].duration_seconds ≈ expected_distance / TransitRouter.DEFAULT_WALK_SPEED_METERS_PER_SECOND
            @test net.transfers[rtp2][1].geometry == [LatLon(35.9218, -78.8751), LatLon(35.9208, -78.8751)]
        end
    end
end