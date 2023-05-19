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