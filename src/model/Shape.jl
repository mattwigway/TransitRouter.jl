struct Shape
    geom::Vector{LatLon{Float64}} # not storing GDAL geometries, they get lost on serialization
    shape_dist_traveled::Vector{Float64}
    dist_traveled_imputed::Bool
end

"Get shape between two stop times"
function geom_between(shape::Shape, net, st1, st2)
    # shape_dist_traveled is always populated in stop_times, we snap during graph build
    reversed = st1.shape_dist_traveled > st2.shape_dist_traveled

    if reversed
        # reverse them but warn
        @warn "Stop $(st1.stop) and $(st2.stop) are out of order on shape"
        st2, st1 = st1, st2
    end

    # find first point
    first_offset = findfirst(shape.shape_dist_traveled .≥ st1.shape_dist_traveled)
    last_offset = findfirst(shape.shape_dist_traveled .> st2.shape_dist_traveled) - 1

    @info first_offset, last_offset, length(shape.shape_dist_traveled)

    # make the geometry
    geom = ArchGDAL.createlinestring()

    # first stop location (let's hope it's on the shape...)
    first_stop = net.stops[st1.stop]
    ArchGDAL.addpoint!(geom, first_stop.stop_lon, first_stop.stop_lat)

    # intermediate shape locations
    for ptidx in first_offset:last_offset
        point = shape.geom[ptidx]
        ArchGDAL.addpoint!(geom, point.lon, point.lat)
    end

    # last stop location
    last_stop = net.stops[st2.stop]
    ArchGDAL.addpoint!(geom, last_stop.stop_lon, last_stop.stop_lat)

    if reversed
        new_geom = ArchGDAL.createlinestring()
        for ptidx in (ArchGDAL.ngeom(geom) - 1):-1:0
            point = ArchGDAL.getpoint(geom, ptidx)
            ArchGDAL.addpoint!(new_geom, point[1], point[2])
        end
        geom = new_geom
    end

    return geom
end

function geom_between(trip, net, st1, st2)
    if !isnothing(trip.shape)
        geom_between(trip.shape, net, st1, st2)
    else
        stop_to_stop_geom(trip, net, st1, st2)
    end
end

"Return a stop-based geometry when there are no shapes"
function stop_to_stop_geom(trip, net, st1, st2)
    st1idx = findfirst(trip.stop_times .== st1)
    st2idx = findfirst(trip.stop_times .== st2)
    !isnothing(st1idx) && !isnothing(st2idx) || error("Stop time not found in trip!")
    geom = ArchGDAL.createlinestring()
    for stop_time in trip.stop_times[st1idx:st2idx]
        stop = net.stops[stop_time.stop]
        ArchGDAL.addpoint!(geom, stop.stop_lon, stop.stop_lat)
    end

    return geom
end

function infer_shape_dist_traveled(shape, lat, lon)
    # create the line string
    firstpt = ArchGDAL.getpoint(shape.geom, 0)
    coslat = cosd(firstpt[1])

    # create the linestring
    coords = map(0:(ArchGDAL.ngeom(shape.geom) - 1)) do idx
        pt = ArchGDAL.getpoint(shape.geom, idx)
        [pt[1] * coslat, pt[2]]
    end
    geosgeom = LibGEOS.createLineString(coords)

    projected_space_dist = LibGEOS.project(geosgeom, LibGEOS.createPoint(lon * coslat, lat))

    # figure out where it is on the line
    cumulative_projected_dist = 0.0
    prev_dist = 0.0
    prev, rest = Iterators.peel(coords)
    for (prev_idx, pt) in rest
        cumulative_projected_dist += sqrt((pt[1] - prev[1]) ^ 2 + (pt[2] - prev[2]) ^ 2)
        if cumulative_projected_dist ≥ projected_space_dist && prev_dist < projected_space_dist
            # we have found the segment, now find the fraction
            frac = (projected_space_dist - prev_dist) / (cumulative_projected_dist - prev_dist)
            return shape.shape_dist_traveled[prev_idx] + frac * (shape.shape_dist_traveled[prev_idx + 1] - shape.shape_dist_traveled[prev_idx])
        end
        prev = pt
        prev_dist = cumulative_projected_dist
    end
end