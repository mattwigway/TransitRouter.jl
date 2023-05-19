@testitem "Time tests" begin
    import Dates: Date, DateTime
    
    @test TransitRouter.seconds_since_midnight_to_datetime(Date(2023, 1, 23), 4 * 60 * 60) == DateTime(2023, 1, 23, 4, 0, 0)
    # overnight route
    @test TransitRouter.seconds_since_midnight_to_datetime(Date(2023, 1, 23), 28 * 60 * 60) == DateTime(2023, 1, 24, 4, 0, 0)
    @test TransitRouter.seconds_since_midnight_to_datetime(Date(2023, 1, 23), 52 * 60 * 60) == DateTime(2023, 1, 25, 4, 0, 0)
    # GTFS times usually not negative (not sure it's even allowed), but test anyhow
    # Maybe this should throw an error as it might mean un-transformed results from a reversed network are being used
    @test TransitRouter.seconds_since_midnight_to_datetime(Date(2023, 1, 23), 4 * 60 * 60 - 24 * 3600) == DateTime(2023, 1, 22, 4, 0, 0)
    @test TransitRouter.seconds_since_midnight_to_datetime(Date(2023, 1, 23), 4 * 60 * 60 - 48 * 3600) == DateTime(2023, 1, 21, 4, 0, 0)
end