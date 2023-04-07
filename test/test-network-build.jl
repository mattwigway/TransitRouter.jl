function build_gtfs()
    gtfs = MockGTFS()

    # add a few stops
    downtown = add_stop!(gtfs, 35.9932, -78.8975, stop_name="Downtown", stop_id="dtn")
    nccu = add_stop!(gtfs, 35.9728, -78.8952, stop_name="NCCU")
    lowes = add_stop!(gtfs, 35.9409, -78.9078, stop_name="Lowes")
    rtp = add_stop!(gtfs, 35.9208, -78.8751, stop_name="RTP")

    fayetteville = add_route!(gtfs, "Fayetteville")
    rtp_express = add_route!(gtfs, "RTP Express")

    every_day = add_service!(gtfs, 20230101, 20231231)

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

    @testset "General" begin
        with_gtfs(gtfs) do gtfspath
            net = build_network([gtfspath])

            # Check stops - four stops read, 
            @test length(net.stops) == 4
            downtown = net.stops[net.stopidx_for_id["$(gtfspath):dtn"]]
            @test downtown.stop_name == "Downtown"
            @test downtown.stop_lat == 35.9932
            @test downtown.stop_lon == -78.8975
        end
    end
end