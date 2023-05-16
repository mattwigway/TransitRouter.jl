# This test compares range-RAPTOR results to repeated RAPTOR results, using the empirical Santa Barbara data.
# Range-RAPTOR and repeated RAPTOR times_at_stops and non_transfer_times_at_stops and walk distances should be identical. The paths
# may not be, because if there are two ways to access a destination using different intermediate stops, range-RAPTOR
# will find the one that departs later, while repeated RAPTOR may not.

function arraycomparison(a1, a2)
    if a1 == a2
        return true
    end

    if size(a1) != size(a2)
        @warn "sizes differ: $(size(a1)) vs $(size(a2))"
    else
        io = IOBuffer()

        diff = a1 .≠ a2
        for round in 1:(size(a1)[1])
            if any(diff[round, :])
                write(io, "In round $round:\n")
                rleres = rle(diff[round, :])

                offset = 1
                for (val, len) in zip(rleres...)
                    if val
                        endix = offset + len - 1
                        write(io, "Stops $(offset)–$endix,\n  expected: $(a1[round, offset:endix])\n  observed: $(a2[round, offset:endix])\n")
                    end
                    offset += len
                end

                write(io, "\n")
            end
        end

        # summary stats
        dv = vec(a1 .- a2)
        summ = """
        Summary of differences
        ----------------------
        Max: $(maximum(dv))
        75th pctile: $(percentile(dv, 75))
        median: $(median(dv))
        mean: $(mean(dv))
        25th pctile: $(percentile(dv, 25))
        Min: $(minimum(dv))
        """
        write(io, summ)

        @warn String(take!(io))
    end

    return false
end

@testset "Range RAPTOR empirical" begin
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

        for (exp, obs) in zip(repeated[begin:begin], rraptor[begin:begin])
            @test arraycomparison(exp.times_at_stops_each_round, obs.times_at_stops_each_round)
            @test arraycomparison(exp.walk_distance_meters, obs.walk_distance_meters)
            @test arraycomparison(exp.non_transfer_times_at_stops_each_round, obs.non_transfer_times_at_stops_each_round)
            @test arraycomparison(exp.non_transfer_walk_distance_meters, obs.non_transfer_walk_distance_meters)
        end
    end
end