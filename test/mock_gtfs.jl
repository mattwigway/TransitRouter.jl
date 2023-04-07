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
    service_id::String
}

const GTFSStopTime = @NamedTuple{
    trip_id::String,
    stop_id::String,
    arrival_time::String,
    departure_time::String,
    stop_sequence::Int64
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

struct MockGTFS
    stops::Vector{GTFSStop}
    routes::Vector{GTFSRoute}
    trips::Vector{GTFSTrip}
    stop_times::Vector{GTFSStopTime}
    calendar::Vector{GTFSCalendar}
    calendar_dates::Vector{GTFSCalendarDate}
    id_iterator::Any
end

MockGTFS() = MockGTFS(GTFSStop[], GTFSRoute[], GTFSTrip[], GTFSStopTime[], GTFSCalendar[], GTFSCalendarDate[], Iterators.Stateful(Iterators.countfrom(1)))
# clone constructor, uses same objects but new vectors so that modifications don't affect
# original.
MockGTFS(o::MockGTFS) = MockGTFS(
    copy(o.stops),
    copy(o.routes),
    copy(o.trips),
    copy(o.stop_times),
    copy(o.calendar),
    copy(o.calendar_dates),
    Iterators.Stateful(Iterators.countfrom(1))
)

nextid(o::MockGTFS) = string(popfirst!(o.id_iterator))

function add_stop!(o::MockGTFS, stop_lat::Float64, stop_lon::Float64; stop_name="", stop_id=nextid(o))
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
function add_trip!(o::MockGTFS, route_id, service_id, stops_and_times; trip_id=nextid(o))
    push!(o.trips, GTFSTrip((trip_id, route_id, service_id)))

    stop_seq = 1
    for stop_and_time in stops_and_times
        stop_id, arrival_time, departure_time = if length(stop_and_time) == 3
            stop_and_time
        else
            # arrival/departure the same
            stop_and_time[1], stop_and_time[2], stop_and_time[2]
        end

        push!(o.stop_times, GTFSStopTime((trip_id, stop_id, arrival_time, departure_time, stop_seq)))

        # make them monotonically increasing, but not consecutive, using minute field
        # from GTFS
        stop_seq += parse(Int64, arrival_time[end-4:end-3]) % 5 + 1
    end
    return trip_id
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

        close(w)

        func(path)
    end
end
