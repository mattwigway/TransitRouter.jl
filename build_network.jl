using TransitRouter
import ArgParse: parse_args, ArgParseSettings, @add_arg_table!
import OSRM: OSRMInstance

function main()
    parser = ArgParseSettings()
    @add_arg_table! parser begin
        "--osrm-network", "-n"
            help = "path to a .osrm file to use for transfer finding"
        "--max-transfer-distance", "-t"
            help = "maximum transfer distance (meters)"
            arg_type = Float64
            default = 1000.0
        "--osrm-pipeline"
            help = "OSRM pipeline, contraction hierarchies (ch) or Multi-Level Dijkstra (mld)"
            default = "mld"
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

    if !isnothing(parsed_args["osrm-network"])
        @info "Starting OSRM to route through the street network"
        # TODO don't hardwire mld
        osrm = OSRMInstance(parsed_args["osrm-network"]::String, parsed_args["osrm-pipeline"])
        network = build_network(gtfs, osrm, max_transfer_distance_meters=parsed_args["max-transfer-distance"])
        save_network(network, output)
    else
        network = build_network(gtfs, max_transfer_distance_meters=parsed_args["max-transfer-distance"])
        save_network(network, output)
    end
end

main()
