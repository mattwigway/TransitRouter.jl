function build_gtfs()
    gtfs = MockGTFS()

    # add a few stops
    downtown = add_stop!(gtfs, 35.9932, -78.8975, stop_name="Downtown", stop_id="dtn")
    nccu = add_stop!(gtfs, 35.9728, -78.8952, stop_name="NCCU")
    lowes = add_stop!(gtfs, 35.9409, -78.9078, stop_name="Lowes")
    rtp = add_stop!(gtfs, 35.9208, -78.8751, stop_name="RTP")

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
    add_trip!(gtfs, fayetteville, every_day, (
        (downtown, "08:00:00"),
        (nccu, "08:12:00"),
        (lowes, "08:18:00"),
        (rtp, "08:21:00")
    ))

    return gtfs
end

@testset "Network build" begin
    gtfs = build_gtfs()

    with_gtfs(gtfs) do gtfspath
        net::TransitNetwork = build_network([gtfspath])

        # Check stops - four stops read, stop names and locations read correctly
        @testset "Stops" begin
            @test length(net.stops) == 4
            downtown = net.stops[net.stopidx_for_id["$(gtfspath):dtn"]]
            @test downtown.stop_name == "Downtown"
            @test downtown.stop_lat == 35.9932
            @test downtown.stop_lon == -78.8975
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

    end
end