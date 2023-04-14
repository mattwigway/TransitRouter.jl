# helper function for Gtfs Time
gt = TransitRouter.time_to_seconds_since_midnight ∘ Time

get_route(trip, net) = trip == INT_MISSING ? INT_MISSING : net.trips[trip].route

include("raptor/test-faster-transfer.jl")
include("raptor/test-transfers.jl")
include("raptor/test-service-running.jl")

# add testsets for: trip/service running, overnight routing, right trip selected when multiple on the pattern
#  transfer and direct transit to same stop, with direct transit and transfer built on.
#  loop trip
#  different arrival/departure times
#  DST
#  max_rides