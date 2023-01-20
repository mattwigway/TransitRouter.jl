struct Route
    route_id::String
    route_short_name::Union{String, Missing}
    route_long_name::Union{String, Missing}
    route_type::Int16
end