using Test, TransitRouter, Dates, CSV, ZipFile, Dates, Geodesy, Logging
import TransitRouter: MAX_TIME, INT_MISSING

include("mock_gtfs.jl")
include("time-tests.jl")
include("test-raptor.jl")
include("test-network-build.jl")