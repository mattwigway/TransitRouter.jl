struct Route
    route_short_name::Union{String, Missing}
    route_long_name::Union{String, Missing}
    route_type::UInt16
end