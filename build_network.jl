include("src/TransitRouter.jl")

using .TransitRouter

netname, gtfs = Iterators.peel(ARGS)
network = build_network(gtfs...)
save_network(network, netname)
