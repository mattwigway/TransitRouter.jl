# functions to call out to OSRM. See osrmjl.cpp for the C++ side.
# Since Julia can only call plain C functions, not C++, we have a thin C++ wrapper with
# extern "C" functions to allocate a new OSRM engine, compute a distance matrix, and destroy
# the OSRM engine when you're done with it.

# To use the OSRM module, libosrmjl.so (or libosrmjl.dylib on macOS) must be in your LD_LIBRARY_PATH,
# which likely means you have to build it first, and may need to build OSRM as well. To build libosrmjl,
# run cmake .. && cmake --build . in the cxx/build directory, and put the resulting shared object file somewhere.
# You may need to build OSRM from source so you have the requisitie libraries available. osrm-backend from Homebrew
# is not compatible with Boost from Homebrew.

module OSRM

struct Coordinate
    latitude::Float64
    longitude::Float64
end

const osrmjl = "libosrmjl"

mutable struct OSRMInstance
    _engine::Ptr{Any}
    file_path::String
    algorithm::String
    running::Bool
end

# Start OSRM, with the file path to an already built OSRM graph, and an algorithm
# specification which is mld for multi-level Dijkstra, and ch for contraction hierarchies.
function start_osrm(file_path::String, algorithm::String)::OSRMInstance
    algorithm = lowercase(algorithm)

    if (algorithm != "mld" && algorithm != "ch")
        error("Algorithm must be 'mld' for Multi-Level Dijkstra, or 'ch' for Contraction Hierarchies.")
    end

    ptr = @ccall osrmjl.init_osrm(file_path::Cstring, algorithm::Cstring)::Ptr{Any}
    return OSRMInstance(ptr, file_path, algorithm, true)
end

function distance_matrix(osrm::OSRMInstance, origins::Vector{Coordinate}, destinations::Vector{Coordinate})
    if !osrm.running
        error("OSRM is not running!")
    end

    n_origins::Csize_t = length(origins)
    n_destinations::Csize_t = length(destinations)
    origin_lats::Vector{Float64} = map(c -> c.latitude, origins)
    origin_lons::Vector{Float64} = map(c -> c.longitude, origins)
    destination_lats::Vector{Float64} = map(c -> c.latitude, destinations)
    destination_lons::Vector{Float64} = map(c -> c.longitude, destinations)

    durations::Array{Float64, 2} = fill(-1.0, (n_origins, n_destinations))::Array{Float64, 2}
    distances::Array{Float64, 2} = fill(-1.0, (n_origins, n_destinations))::Array{Float64, 2}

    @ccall osrmjl.distance_matrix(
        osrm._engine::Ptr{Any},
        n_origins::Csize_t,
        origin_lats::Ptr{Float64},
        origin_lons::Ptr{Float64},
        n_destinations::Csize_t,
        destination_lats::Ptr{Float64},
        destination_lons::Ptr{Float64},
        durations::Ptr{Float64},
        distances::Ptr{Float64}
    )::Cvoid

    return (durations=durations, distances=distances)
end

function stop_osrm!(osrm::OSRMInstance)
    if osrm.running
        @ccall osrmjl.stop_osrm(osrm._engine::Ptr{Any})::Cvoid
        osrm.running = false
    else
        @warn "stop_osrm! called on already stopped OSRM instance"
    end
end

export start_osrm, distance_matrix, stop_osrm!, Coordinate, OSRMInstance

end