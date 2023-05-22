# includes available in all tests
# TODO could not do this, and just import what's needed in each test

using Test, TransitRouter, Dates, CSV, ZipFile, Dates, Geodesy, Logging, Artifacts, OSRM
import SnapshotTests: @snapshot_test
import TransitRouter: MAX_TIME, INT_MISSING
import StructEquality: @struct_isequal
import StatsBase: rle, median, percentile, mean

include("mock_gtfs.jl")
include("test-raptor.jl")

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

# helper function for Gtfs Time
const MT = TransitRouter.MAX_TIME
const IM = TransitRouter.INT_MISSING

function gt(h, m)
    offset = 0
    # handle overnight routing - Time() cannot accept hours over 24, but GTFS of course can
    while h >= 24
        h -= 24
        offset += 24 * 60 * 60
    end

    return offset + TransitRouter.time_to_seconds_since_midnight(Time(h, m))
end


get_route(trip, net) = trip == INT_MISSING ? INT_MISSING : net.trips[trip].route

function test_no_updates_after_round(result, round)
    n_rounds = size(result.non_transfer_times_at_stops_each_round)[1]
    for current_round in ((round + 1):n_rounds)
        if current_round != n_rounds
            # no times_at_stops_each_round after last round - no transfers
            @test result.times_at_stops_each_round[current_round, :] == result.times_at_stops_each_round[round, :]
        end

        @test result.non_transfer_times_at_stops_each_round[current_round, :] == result.non_transfer_times_at_stops_each_round[round, :]
        @test all(result.prev_stop[current_round] .== IM)
        @test all(result.prev_trip[current_round] .== IM)
        @test all(result.prev_boardtime[current_round] .== IM)
        @test all(result.transfer_prev_stop[current_round] .== IM)
    end
end

get_routes(path) = map(x -> x.route.route_id, filter(x -> x.type == TransitRouter.transit, path))
get_transit_times(path) = collect(Iterators.flatten(map(x -> (x.start_time, x.end_time), filter(x -> x.type == TransitRouter.transit, path))))

