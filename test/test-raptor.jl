# helper function for Gtfs Time
gt = TransitRouter.time_to_seconds_since_midnight ∘ Time

include("raptor/test-faster-transfer.jl")
include("raptor/test-transfers.jl")