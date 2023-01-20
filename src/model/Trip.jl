struct Trip
    stop_times::Vector{StopTime}
    route::Int64
    service::Int64
    pattern::Int64
    shape::Union{Shape, Nothing}
end