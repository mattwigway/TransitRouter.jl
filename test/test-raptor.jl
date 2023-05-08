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

include("raptor/test-faster-transfer.jl")
include("raptor/test-transfers.jl")
include("raptor/test-service-running.jl")
include("raptor/test-overnight.jl")
include("raptor/test-transfer-and-direct.jl")
include("raptor/test-local-express.jl")
include("raptor/test-min-walk-distance.jl")

# add testsets for: 
#  overnight routing
#  local and express service
#  overtaking trips
#  loop trip
#  different arrival/departure times
#  DST
#  max_rides
#  Both-direction trips
#  multiple origin stops