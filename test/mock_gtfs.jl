# Code to create a mock GTFS feed

const ids = Iterators.Stateful(1:1e6)

const GTFSStop = @NamedTuple{
    stop_id::String,
    stop_name::String,
    stop_lat::Float64,
    stop_lon::Float64
}

const GTFSRoute = @NamedTuple{
    route_id::String,
    route_short_name::String,
    route_long_name::String,
    route_type::Int64
}

const GTFSTrip = @NamedTuple{
    trip_id::String,
    route_id::String,
    service_id::String,
    shape_id::Union{Missing, String}
}

const GTFSStopTime = @NamedTuple{
    trip_id::String,
    stop_id::String,
    arrival_time::String,
    departure_time::String,
    stop_sequence::Int64,
    pickup_type::String,
    drop_off_type::String
}

const GTFSCalendar = @NamedTuple{
    service_id::String,
    monday::Int8,
    tuesday::Int8,
    wednesday::Int8,
    thursday::Int8,
    friday::Int8,
    saturday::Int8,
    sunday::Int8,
    start_date::Int64,
    end_date::Int64
}

const GTFSCalendarDate = @NamedTuple{
    service_id::String,
    date::Int64,
    exception_type::Int8
}

const GTFSShape = @NamedTuple{
    shape_id::String,
    shape_pt_lats::Vector{Float64},
    shape_pt_lons::Vector{Float64},
    shape_dist_traveled::Union{Vector{Float64}, Nothing}
}

struct MockGTFS
    stops::Vector{GTFSStop}
    routes::Vector{GTFSRoute}
    trips::Vector{GTFSTrip}
    stop_times::Vector{GTFSStopTime}
    calendar::Vector{GTFSCalendar}
    calendar_dates::Vector{GTFSCalendarDate}
    shapes::Vector{GTFSShape}
    id_iterator::Any
    lat_iterator::Any
    lon_iterator::Any
end

MockGTFS() = MockGTFS(GTFSStop[], GTFSRoute[], GTFSTrip[], GTFSStopTime[], GTFSCalendar[], GTFSCalendarDate[], GTFSShape[], Iterators.Stateful(Iterators.countfrom(1)),
    # Lat and lon iterators in southern and eastern hemisphere, to make sure there are no issues with sign of lat/lon
    Iterators.Stateful(Iterators.countfrom(-27.4, 0.01)), Iterators.Stateful(Iterators.countfrom(153.0, 0.01)))

nextid(o::MockGTFS) = string(popfirst!(o.id_iterator))

function add_stop!(o::MockGTFS, stop_lat::Float64=popfirst!(o.lat_iterator), stop_lon::Float64=popfirst!(o.lon_iterator); stop_name="stop", stop_id=nextid(o))
    push!(o.stops, GTFSStop((stop_id, stop_name, stop_lat, stop_lon)))
    return stop_id
end

function add_route!(o::MockGTFS, route_short_name::String=""; route_long_name::String="", route_id=nextid(o))
    push!(o.routes, GTFSRoute((route_id, route_short_name, route_long_name, 3)))
    return route_id
end

function add_service!(o::MockGTFS, start_date, end_date;
        monday=1,
        tuesday=1,
        wednesday=1,
        thursday=1,
        friday=1,
        saturday=1,
        sunday=1,
        exceptions=NTuple{2, Integer}[],
        write_calendar_entry=true,
        service_id=nextid(o)
    )
    
    if write_calendar_entry
        cal = GTFSCalendar((
            service_id,
            monday,
            tuesday,
            wednesday,
            thursday,
            friday,
            saturday,
            sunday,
            start_date,
            end_date
        ))
        push!(o.calendar, cal)
    end

    for exc in exceptions
        push!(o.calendar_dates, GTFSCalendarDate((service_id, exc[1], exc[2])))
    end

    return service_id
end

# add a trip on the specified route with the specified stops
# stops_and_times is a vector of tuple (stop_id, stop_time) or (stop_id, arrival_time, departure_time)
function add_trip!(o::MockGTFS, route_id, service_id, stops_and_times; shape_id=missing, trip_id=nextid(o))
    push!(o.trips, GTFSTrip((trip_id, route_id, service_id, shape_id)))

    stop_seq = 1
    for stop_and_time in stops_and_times
        stop_id, arrival_time, departure_time, pickup_type, drop_off_type = if length(stop_and_time) == 5
            stop_and_time
        elseif length(stop_and_time) == 3
            (stop_and_time..., "", "")
        else
            # arrival/departure the same
            stop_and_time[1], stop_and_time[2], stop_and_time[2], "", ""
        end

        push!(o.stop_times, GTFSStopTime((trip_id, stop_id, arrival_time, departure_time, stop_seq, repr(pickup_type), repr(drop_off_type))))

        # make them monotonically increasing, but not consecutive
        stop_seq *= 2
    end
    return trip_id
end

add_shape!(o::MockGTFS, latlons::AbstractVector{<:LatLon{<:Any}}; shape_dist_traveled=nothing, shape_id=nextid(o)) =
    add_shape!(o, [x.lat for x in latlons], [x.lon for x in latlons], shape_dist_traveled=shape_dist_traveled, shape_id=shape_id)

function add_shape!(o::MockGTFS, lat, lon; shape_dist_traveled=nothing, shape_id=nextid(o))
    length(lat) == length(lon) || error("Differing numbers of latitudes and longitudes!")
    isnothing(shape_dist_traveled) || length(shape_dist_traveled) == length(lat) || error("Differing number of shape_dist_traveled vs lat/lon")
    push!(o.shapes, GTFSShape((shape_id, lat, lon, shape_dist_traveled)))
    return shape_id
end

# run function f with the first argument specifying the path to GTFS file
function with_gtfs(func, o::MockGTFS)
    mktemp() do path, io
        w = ZipFile.Writer(io)

        f = ZipFile.addfile(w, "stops.txt")
        CSV.write(f, o.stops)
        
        f = ZipFile.addfile(w, "routes.txt")
        CSV.write(f, o.routes)

        f = ZipFile.addfile(w, "trips.txt")
        CSV.write(f, o.trips)

        f = ZipFile.addfile(w, "stop_times.txt")
        CSV.write(f, o.stop_times)

        if !isempty(o.calendar)
            f = ZipFile.addfile(w, "calendar.txt")
            CSV.write(f, o.calendar)
        end

        if !isempty(o.calendar_dates)
            f = ZipFile.addfile(w, "calendar_dates.txt")
            CSV.write(f, o.calendar_dates)
        end

        if !isempty(o.shapes)
            f = ZipFile.addfile(w, "shapes.txt")
            has_shp_dist_trv = any([!isnothing(s.shape_dist_traveled) for s in o.shapes])

            shapeit = Iterators.flatten(map(o.shapes) do shape
                if has_shp_dist_trv
                    if !isnothing(shape.shape_dist_traveled)
                        [(shape_id=shape.shape_id, shape_pt_lat=z[1], shape_pt_lon=z[2], shape_dist_traveled=z[3], shape_pt_sequence=z[4])
                            for z in zip(shape.shape_pt_lats, shape.shape_pt_lons, shape.shape_dist_traveled, eachindex(shape.shape_pt_lats))]
                    else
                        # leave column blank
                        [(shape_id=shape.shape_id, shape_pt_lat=z[1], shape_pt_lon=z[2], shape_dist_traveled=missing, shape_pt_sequence=z[3])
                            for z in zip(shape.shape_pt_lats, shape.shape_pt_lons, eachindex(shape.shape_pt_lats))]
                    end
                else
                    # no column at all
                    [(shape_id=shape.shape_id, shape_pt_lat=z[1], shape_pt_lon=z[2], shape_pt_sequence=z[3])
                        for z in zip(shape.shape_pt_lats, shape.shape_pt_lons, eachindex(shape.shape_pt_lats))]
                end
            end)

            CSV.write(f, shapeit)
        end

        close(w)

        func(path)
    end
end
