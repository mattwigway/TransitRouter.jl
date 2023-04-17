@testset "shape_dist_traveled inference" begin
    gtfs = MockGTFS()

    r = add_route!(gtfs)
    svc = add_service!(gtfs, 20230101, 20231231)

    s1 = add_stop!(gtfs, 44.904799, -93.287731) # before start
    s2 = add_stop!(gtfs, 44.904921, -93.287731) # at start
    s3 = add_stop!(gtfs, 44.905106, -93.285758) # middle, not on point
    s4 = add_stop!(gtfs, 44.904936, -93.284481) # middle, on point
    s5 = add_stop!(gtfs, 44.903869, -93.278087) # at end
    s6 = add_stop!(gtfs, 44.903783, -93.278087) # past end

    shape = add_shape!(gtfs, [
        # s1
        LatLon(44.904921, -93.287731), # s2
        LatLon(44.905089, -93.287733),
        LatLon(44.905096, -93.287119),
        LatLon(44.905097, -93.287028),
        LatLon(44.905098, -93.286932),
        LatLon(44.905102, -93.286364),
        # s3
        LatLon(44.905106, -93.285619),
        LatLon(44.905105, -93.285585),
        LatLon(44.905101, -93.285507),
        LatLon(44.905098, -93.285477),
        LatLon(44.905089, -93.285399),
        LatLon(44.905062, -93.285239),
        LatLon(44.905053, -93.28518),
        LatLon(44.904985, -93.284792),
        LatLon(44.904936, -93.284481), # s4
        LatLon(44.904736, -93.283199),
        LatLon(44.90463, -93.282609),
        LatLon(44.904522, -93.281868),
        LatLon(44.904431, -93.281249),
        LatLon(44.904343, -93.280647),
        LatLon(44.904148, -93.27932),
        LatLon(44.904105, -93.279032),
        LatLon(44.904079, -93.278852),
        LatLon(44.904057, -93.278702),
        LatLon(44.903988, -93.278235),
        LatLon(44.903966, -93.278086),
        LatLon(44.903869, -93.278087) # s5
        # s6
    ])  # no shape_dist_traveled

    add_trip!(gtfs, r, svc, (
        (s1, "8:00:00"),
        (s2, "8:03:00"),
        (s3, "8:05:00"),
        (s4, "8:08:00"),
        (s5, "8:10:00"),
        (s6, "8:11:00")
    ); shape_id=shape)

    with_gtfs(gtfs) do path
        net::TransitNetwork = with_logger(NullLogger()) do
            build_network([path])
        end

        trip = net.trips[1]
        shape = trip.shape

        # before shape
        @test TransitRouter.infer_shape_dist_traveled(shape, 44.904799, -93.287731) ≈ 0.0

        # at start of shape
        @test TransitRouter.infer_shape_dist_traveled(shape, 44.904921, -93.287731) ≈ 0.0

        # In middle of route
        s3dist = TransitRouter.infer_shape_dist_traveled(shape, 44.905106, -93.285758)
        @test s3dist > shape.shape_dist_traveled[6] && s3dist < shape.shape_dist_traveled[7]

        # On a point in middle of route
        @test TransitRouter.infer_shape_dist_traveled(shape, 44.904936, -93.284481) ≈ shape.shape_dist_traveled[15]

        # at end of shape
        @test TransitRouter.infer_shape_dist_traveled(shape, 44.903869, -93.278087) ≈ last(shape.shape_dist_traveled)

        # past end of shape
        @test TransitRouter.infer_shape_dist_traveled(shape, 44.903783, -93.278087) ≈ last(shape.shape_dist_traveled)

        # stop 1 to 3
        @test TransitRouter.geom_between(shape, net, trip.stop_times[1], trip.stop_times[3]) == [
            LatLon(44.904799, -93.287731),
            LatLon(44.904921, -93.287731),
            LatLon(44.905089, -93.287733),
            LatLon(44.905096, -93.287119),
            LatLon(44.905097, -93.287028),
            LatLon(44.905098, -93.286932),
            LatLon(44.905102, -93.286364),
            LatLon(44.905106, -93.285758)
        ]

        # stop 2 to 3
        @test TransitRouter.geom_between(shape, net, trip.stop_times[2], trip.stop_times[3]) == [
            LatLon(44.904921, -93.287731), # appears twice because once from stop, once from shape
            LatLon(44.904921, -93.287731),
            LatLon(44.905089, -93.287733),
            LatLon(44.905096, -93.287119),
            LatLon(44.905097, -93.287028),
            LatLon(44.905098, -93.286932),
            LatLon(44.905102, -93.286364),
            LatLon(44.905106, -93.285758)
        ]

        # stop 3 to 4
        @test TransitRouter.geom_between(shape, net, trip.stop_times[3], trip.stop_times[4]) == [
            LatLon(44.905106, -93.285758),
            LatLon(44.905106, -93.285619),
            LatLon(44.905105, -93.285585),
            LatLon(44.905101, -93.285507),
            LatLon(44.905098, -93.285477),
            LatLon(44.905089, -93.285399),
            LatLon(44.905062, -93.285239),
            LatLon(44.905053, -93.28518),
            LatLon(44.904985, -93.284792),
            LatLon(44.904936, -93.284481),
            LatLon(44.904936, -93.284481)
        ]

        # stop 4 to 5
        @test TransitRouter.geom_between(shape, net, trip.stop_times[4], trip.stop_times[5]) == [
            LatLon(44.904936, -93.284481), # s4
            LatLon(44.904936, -93.284481),
            LatLon(44.904736, -93.283199),
            LatLon(44.90463, -93.282609),
            LatLon(44.904522, -93.281868),
            LatLon(44.904431, -93.281249),
            LatLon(44.904343, -93.280647),
            LatLon(44.904148, -93.27932),
            LatLon(44.904105, -93.279032),
            LatLon(44.904079, -93.278852),
            LatLon(44.904057, -93.278702),
            LatLon(44.903988, -93.278235),
            LatLon(44.903966, -93.278086),
            LatLon(44.903869, -93.278087),
            LatLon(44.903869, -93.278087)
        ]

        # stop 4 to 6 (same except for stop 6 coordinate)
        @test TransitRouter.geom_between(shape, net, trip.stop_times[4], trip.stop_times[6]) == [
            LatLon(44.904936, -93.284481), # s4
            LatLon(44.904936, -93.284481),
            LatLon(44.904736, -93.283199),
            LatLon(44.90463, -93.282609),
            LatLon(44.904522, -93.281868),
            LatLon(44.904431, -93.281249),
            LatLon(44.904343, -93.280647),
            LatLon(44.904148, -93.27932),
            LatLon(44.904105, -93.279032),
            LatLon(44.904079, -93.278852),
            LatLon(44.904057, -93.278702),
            LatLon(44.903988, -93.278235),
            LatLon(44.903966, -93.278086),
            LatLon(44.903869, -93.278087),
            LatLon(44.903783, -93.278087)
        ]

        # make sure it handles gracefully stops that snap to the same point on the shape
        # stop 1 to 2
        @test TransitRouter.geom_between(shape, net, trip.stop_times[1], trip.stop_times[2]) == [
            LatLon(44.904799, -93.287731),
            LatLon(44.904921, -93.287731),
            LatLon(44.904921, -93.287731)
        ]

        @test TransitRouter.geom_between(shape, net, trip.stop_times[5], trip.stop_times[6]) == [
            LatLon(44.903869, -93.278087),
            LatLon(44.903869, -93.278087),
            LatLon(44.903783, -93.278087)
        ]

    end
end