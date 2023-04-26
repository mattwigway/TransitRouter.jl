# helper function for Gtfs Time
const gt = TransitRouter.time_to_seconds_since_midnight ∘ Time
const MT = TransitRouter.MAX_TIME
const IM = TransitRouter.INT_MISSING

get_route(trip, net) = trip == INT_MISSING ? INT_MISSING : net.trips[trip].route

include("raptor/test-faster-transfer.jl")
include("raptor/test-transfers.jl")
include("raptor/test-service-running.jl")
include("raptor/test-transfer-and-direct.jl")

# add testsets for: trip/service running, overnight routing, right trip selected when multiple on the pattern
#  transfer and direct transit to same stop, with direct transit and transfer built on.
#  local and express service
#  overtaking trips
#  loop trip
#  different arrival/departure times
#  DST
#  max_rides