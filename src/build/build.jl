# Build a network from a GTFS file name
using ZipFile
using CSV
using DataFrames
using Logging
using Tables
using Dates
using .OSRM

const TRANSFER_DISTANCE_METERS = 2000

function strip_colnames!(df)
    rename!(strip, df)
end

# refactor needed - split all of these load methods for individual files out into functions
function build_network(gtfs_filenames::Vector{String}, transfers_osrm_path::Union{String, Missing}=missing)::TransitNetwork
    # initialize a new, empty transit network
    net::TransitNetwork = TransitNetwork()

    for gtfs_filename in gtfs_filenames
        stop_number_for_stop_id::Dict{String,UInt16} = Dict()

        @info "Reading $gtfs_filename..."

        # first read stops
        r = ZipFile.Reader(gtfs_filename)
        @debug "opened file"
        filename_map = Dict([f.name=>f for f in r.files]...)
        kys = keys(filename_map)
        @debug "indexed file, keys $kys"

        @info "..stops.txt"
        stop_df = DataFrame(CSV.File(read(filename_map["stops.txt"])))
        strip_colnames!(stop_df)
        nstops = nrow(stop_df)

        # pre-allocate space for the new stops TODO can I sizehint a dict?
        # TODO should this just be nstops? are we over-allocating?
        sizehint!(net.stops, length(net.stops) + nstops)

        for srow in Tables.rows(stop_df)
            if (ismissing(srow.stop_lat) | ismissing(srow.stop_lon))
                @warn "Stop $(srow.stop_id) is missing coordinates, skipping"
            else
                stop = Stop(srow.stop_lat, srow.stop_lon)
                push!(net.stops, stop)
                net.stopidx_for_id["$gtfs_filename:$(srow.stop_id)"] = length(net.stops)
            end
        end

        @info "...Read $nstops stops"

        @info "..routes.txt"
        route_df = DataFrame(CSV.File(read(filename_map["routes.txt"]); types=Dict(:route_short_name => String, :route_long_name => String)))
        strip_colnames!(route_df)
        nroutes = nrow(route_df)

        sizehint!(net.routes, length(net.routes) + nroutes)

        for rrow in Tables.rows(route_df)
            rte = Route(rrow.route_short_name, rrow.route_long_name, rrow.route_type)
            push!(net.routes, rte)
            net.routeidx_for_id["$gtfs_filename:$(rrow.route_id)"] = length(net.routes)
        end

        @info "...Read $nroutes routes"

        if haskey(filename_map, "calendar.txt")
            @info "..calendar.txt"

            cal_df = DataFrame(CSV.File(read(filename_map["calendar.txt"])))
            strip_colnames!(cal_df)
            ncals = nrow(cal_df)

            sizehint!(net.services, length(net.services) + ncals)

            for crow in Tables.rows(cal_df)
                svc = Service(
                    crow.monday::Integer == 1,
                    crow.tuesday::Integer == 1,
                    crow.wednesday::Integer == 1,
                    crow.thursday::Integer == 1,
                    crow.friday::Integer == 1,
                    crow.saturday::Integer == 1,
                    crow.sunday::Integer == 1,
                    parse_gtfsdate(crow.start_date),
                    parse_gtfsdate(crow.end_date),
                    # calendar_dates processed later
                    Vector{Date}(),
                    Vector{Date}()
                )
                push!(net.services, svc)
                net.serviceidx_for_id["$gtfs_filename:$(crow.service_id)"] = length(net.services)
            end

            @info "...Read $ncals calendars"
        else
            @info "..calendar.txt (not present)"
        end

        if haskey(filename_map, "calendar_dates.txt")
            @info "..calendar_dates.txt"

            cal_df = DataFrame(CSV.File(read(filename_map["calendar_dates.txt"])))
            strip_colnames!(cal_df)
            ncals = nrow(cal_df)

            for crow in Tables.rows(cal_df)
                local svc::Service
                namespaced_service_id = "$gtfs_filename:$(crow.service_id)"

                if haskey(net.serviceidx_for_id, namespaced_service_id)
                    svc = net.services[net.serviceidx_for_id[namespaced_service_id]]
                else
                    svc = Service(
                        false,
                        false,
                        false,
                        false,
                        false,
                        false,
                        false,
                        Date("19700101", "yyyymmdd"),
                        Date("22500101", "yyyymmdd"),
                        Vector{Date}(),
                        Vector{Date}()
                    )
                    push!(net.services, svc)
                    net.serviceidx_for_id[namespaced_service_id] = length(net.services)
                end

                date = parse_gtfsdate(crow.date)

                if (crow.exception_type::Integer == 1)
                    push!(svc.added_dates, date)
                elseif (crow.exception_type::Integer == 2)
                    push!(svc.removed_dates, date)
                end
            end

        else
            @info "..calendar_dates.txt (not present)"
        end

        @info "..trips.txt"
        trip_df = DataFrame(CSV.File(filename_map["trips.txt"]))
        strip_colnames!(trip_df)
        ntrips = nrow(trip_df)

        sizehint!(net.trips, length(net.trips) + ntrips)

        for trow in Tables.rows(trip_df)
            service = net.serviceidx_for_id["$gtfs_filename:$(trow.service_id)"]
            route = net.routeidx_for_id["$gtfs_filename:$(trow.route_id)"]
            trp = Trip(Vector{StopTime}(), route, service, -1)
            push!(net.trips, trp)
            net.tripidx_for_id["$gtfs_filename:$(trow.trip_id)"] = length(net.trips)
        end

        @info "...loaded $ntrips trips"

        @info "..stop_times.txt"

        st_df = DataFrame(CSV.File(filename_map["stop_times.txt"], typemap=Dict(Dates.Time=>String)))
        strip_colnames!(st_df)
        nst = nrow(st_df)

        for strow in Tables.rows(st_df)
            trp = net.trips[net.tripidx_for_id["$gtfs_filename:$(strow.trip_id)"]]
            stopidx = net.stopidx_for_id["$gtfs_filename:$(strow.stop_id)"]
            st = StopTime(
                stopidx,
                strow.stop_sequence,
                parse_gtfstime(strow.arrival_time),
                parse_gtfstime(strow.departure_time)
            )
            push!(trp.stop_times, st)
        end

        @info "Loaded $nst stop times"

        if haskey(filename_map, "frequencies.txt")
            @warn "frequencies.txt present but not yet supported - frequency trips will run once at the time they are scheduled in stop times (often midnight)"
        end
    end

    @info "Loaded all GTFS files"

    @info "Sorting stop times..."
    sort_stoptimes!(net)
    @info "Done sorting stop times"

    @info "Interpolating stop times..."
    interpolate_stoptimes!(net)
    @info "Done interpolating stop times"

    @info "Finding trip patterns..."
    find_trip_patterns!(net)
    @info "Done finding trip patterns" 

    @info "Finding transfers within $(TRANSFER_DISTANCE_METERS)m crow-flies distance..."
    find_transfers_distance!(net, TRANSFER_DISTANCE_METERS)

    @info "Indexing patterns..."
    index_network!(net)
    
    @info "Network build completed."

    return net
end
