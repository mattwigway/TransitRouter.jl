# Represents a pattern, a unique sequence of stops visited by a transit vehicle

struct TripPattern
    stops::Array{UInt32}
    stopTimes::Array{UInt16}
    serviceIds::Array{UInt16}
end
