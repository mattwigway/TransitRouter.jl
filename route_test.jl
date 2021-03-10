include("src/TransitRouter.jl")

using Dates
using DataFrames
using CSV
using .TransitRouter

net = load_network(ARGS[1])

@info "Loaded network"

raptor_req = RaptorRequest(
    [StopAndTime(21, 25200)],
    4,
    Date("2021-02-05", "yyyy-mm-dd"),
    1.33
)

raptor_res = raptor(net, raptor_req)

@info "Completed RAPTOR"

travel_time_df = DataFrame(
    lat=map(s -> s.stop_lat, net.stops),
    lon=map(s -> s.stop_lon, net.stops),
    ttime=raptor_res.times_at_stops_each_iteration[9, :] .- 25200
)

CSV.write(ARGS[2], travel_time_df)
