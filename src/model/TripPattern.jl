# Represents a pattern, a unique sequence of stops visited by a transit vehicle

struct TripPattern
    stops::Vector{Int64}
    service::Int64
end
