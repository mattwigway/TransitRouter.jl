# represents transfers from a stop

struct Transfer
    target_stop::Int64
    distance_meters::Float64
    duration_seconds::Float64
    geometry::Vector{LatLon{Float64}}
end