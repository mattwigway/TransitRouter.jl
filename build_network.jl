include("src/TransitRouter.jl")

using .TransitRouter
using .TransitRouter.OSRM
using ArgParse

function main()
    parser = ArgParseSettings()
    @add_arg_table parser begin
        "--osrm-network", "-n"
            help = "path to a .osrm file to use for transfer finding"
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
        osrm = start_osrm(parsed_args["osrm-network"]::String, "mld")
        network = build_network(gtfs, osrm)
        stop_osrm!(osrm)
        save_network(network, output)
    else
        network = build_network(gtfs)
        save_network(network, output)
    end
end

main()
