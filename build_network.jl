include("src/TransitRouter.jl")

using .TransitRouter

netname, gtfs = Iterators.peel(ARGS)
network = build(gtfs...)
save_network(network, netname)
