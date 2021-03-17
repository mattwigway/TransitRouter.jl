include("src/TransitRouter.jl")

using .TransitRouter
using .TransitRouter.OSRM
using ArgParse

function main()
    parser = ArgParseSettings()
    @add_arg_table! parser begin
        "--osrm-network", "-n"
            help = "path to a .osrm file to use for transfer finding"
        "--max-transfer-distance", "-t"
            help = "maximum transfer distance (meters)"
            arg_type = Float64
            default = 1000.0
        "output"
            help = "Output file to save network (ends in .trjl)"
            required = true
        "gtfs"
            help = "GTFS input files"
            nargs = '+'
            required = true
    end

    parsed_args = parse_args(parser)

    gtfs::Vector{String} = convert(Vector{String}, parsed_args["gtfs"])::Vector{String}
    output::String = parsed_args["output"]::String

    if haskey(parsed_args, "osrm-network")
        @info "Starting OSRM to route through the street network"
        # TODO don't hardwire mld
        osrm = start_osrm(parsed_args["osrm-network"]::String, "ch")
        network = build_network(gtfs, osrm, parsed_args["max-transfer-distance"])
        stop_osrm!(osrm)
        save_network(network, output)
    else
        network = build_network(gtfs, max_transfer_distance_meters=parsed_args["max-transfer-distance"])
        save_network(network, output)
    end
end

main()
