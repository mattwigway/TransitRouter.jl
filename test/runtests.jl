using Test, TransitRouter, Dates, CSV, ZipFile, Dates, Geodesy, Logging, Artifacts, OSRM
import SnapshotTests: @snapshot_test
import TransitRouter: MAX_TIME, INT_MISSING
import StructEquality: @struct_isequal
import StatsBase: rle, median, percentile, mean

include("mock_gtfs.jl")
include("test-shapes.jl")
include("time-tests.jl")
include("test-raptor.jl")
include("test-network-build.jl")
include("test-streetraptor.jl")
