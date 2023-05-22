# This test compares range-RAPTOR results to repeated RAPTOR results, using the empirical Santa Barbara data.
# Range-RAPTOR and repeated RAPTOR times_at_stops and non_transfer_times_at_stops and walk distances should be identical. The paths
# may not be, because if there are two ways to access a destination using different intermediate stops, range-RAPTOR
# will find the one that departs later, while repeated RAPTOR may not.

@testitem "Range RAPTOR empirical" begin
    include("../../test-includes.jl")

    # copy artifact to temp dir
    # can't re-use net from StreetRAPTOR tests as we want this test to run even if OSRM is not available
    mktempdir() do dir
        Base.Filesystem.cp(artifact"sb_gtfs", joinpath(dir, "data"))
        gtfs = joinpath(dir, "data", "feed.zip")
        net = with_logger(NullLogger()) do
            TransitRouter.build_network([gtfs])
        end
    
        repeated = map(gt(8, 0):60:gt(10, 0)) do time
            raptor([
                    StopAndTime(net.stopidx_for_id["$gtfs:91"], time, 100) # Cliff and Oceano inbound, west of SBCC
                    StopAndTime(net.stopidx_for_id["$gtfs:71"], time + 120, 200) # Cliff and Oceano outbound, west of SBCC
                ],
                net, Date(2023, 5, 12)) 
        end

        rraptor = range_raptor([
                StopAndTime(net.stopidx_for_id["$gtfs:91"], gt(8, 0), 100) # Cliff and Oceano inbound, west of SBCC
                StopAndTime(net.stopidx_for_id["$gtfs:71"], gt(8, 2), 200) # Cliff and Oceano outbound, west of SBCC
            ],
            net, Date(2023, 5, 12), 7200, 60
        )

        @test length(repeated) == 121
        @test length(rraptor) == 121

        for i in 1:length(repeated)
            obs = repeated[i]
            exp = rraptor[i]

            # This is a little complex, so fasten your seat belt (unless you're on the bus, of course, and don't have one)
            # Like most transit routing algorithms, range-RAPTOR only guarantees that it will find an earliest-arrival trips, not
            # necessarily shortest trips (though it can with some preprocessing). This guarantee means that range-RAPTOR and
            # repeated RAPTOR should always find exactly the same times_at_stops and non_transfer_times.
            
            # Neither RAPTOR nor Range-RAPTOR provide any guarantees about aspects of the paths other than that they produce
            # optimal arrival times. Because of differences in how the algorithms work, they often do not produce the same paths,
            # depending on how ties are broken; see http://projects.indicatrix.org/range-raptor-transfer-compression/ for details.

            # however, any stop that was updated in a round should be identical in all aspects (including the full path)
            # to what you would get from a single-shot RAPTOR execution - because if a stop was updated, that implies that
            # it was found that round, which implies all predecessors were also found that round.

            # the times at stops (non transfer and transfer) should be identical
            @test exp.times_at_stops_each_round == obs.times_at_stops_each_round
            @test exp.non_transfer_times_at_stops_each_round == obs.non_transfer_times_at_stops_each_round

            # Find all updated transfer and non-transfer stops
            if i < length(repeated)
                updated_transfer = obs.times_at_stops_each_round .≠ repeated[i + 1].times_at_stops_each_round
                updated_nontransfer = obs.non_transfer_times_at_stops_each_round .≠ repeated[i + 1].non_transfer_times_at_stops_each_round
            else
                # last minute, everything should be identical between RAPTOR and range-RAPTOR
                updated_transfer = ones(Bool, size(exp.times_at_stops_each_round))
                updated_nontransfer = ones(Bool, size(exp.non_transfer_times_at_stops_each_round))
            end

            # confirm that updated transfer times are associated with the same previous stop
            @test exp.transfer_prev_stop[updated_transfer] == obs.transfer_prev_stop[updated_transfer]
            
            # confirm that updated non-transfer times are associated with the same previous ride
            @test exp.prev_stop[updated_nontransfer] == obs.prev_stop[updated_nontransfer]
            @test exp.prev_trip[updated_nontransfer] == obs.prev_trip[updated_nontransfer]
            @test exp.prev_boardtime[updated_nontransfer] == obs.prev_boardtime[updated_nontransfer]

            # Every stop that was updated should have a predecessor that was also updated (i.e. the entire path was found
            # in this range-RAPTOR iteration)
            nrounds = size(exp.non_transfer_times_at_stops_each_round, 1)
            for round in 2:nrounds
                for stop in eachindex(net.stops)
                    # if a stop was updated _in this round_ (as opposed to an earlier time carried forward froma previous round),
                    # the board stop should have been updated in the previous round (by a transfer, loop or bona fide)
                    @test !updated_nontransfer[round, stop] || 
                        exp.prev_stop[round, stop] == TransitRouter.INT_MISSING || # updated in previous round, not this one
                        updated_transfer[round - 1, exp.prev_stop[round, stop]]

                    # if a stop was reached via a transfer, the non-transfer time at the previous stop should have been updated in this round
                    # (transfers occur after rounds)
                    @test round == nrounds || # no transfers in last round
                        !updated_transfer[round, stop] || # transfer not updated
                        exp.times_at_stops_each_round[round, stop] == exp.times_at_stops_each_round[round - 1, stop] || # updated in previous round
                        updated_nontransfer[round, ifelse(exp.transfer_prev_stop[round, stop] == TransitRouter.INT_MISSING, stop, exp.transfer_prev_stop[round, stop])] # non-transfer updated
                    end
                end
            end
        end
    end
end