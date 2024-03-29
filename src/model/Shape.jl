struct Shape
    geom::Vector{LatLon{Float64}} # not storing GDAL geometries, they get lost on serialization
    shape_dist_traveled::Vector{Float64}
    dist_traveled_imputed::Bool
end

"Get shape between two stop times"
function geom_between(shape::Shape, net, st1, st2)
    # shape_dist_traveled is always populated in stop_times, we snap during graph build
    reversed = st1.shape_dist_traveled > st2.shape_dist_traveled

    # first stop location (let's hope it's on the shape...)
    first_stop = net.stops[st1.stop]
    first_stop_ll = LatLon(first_stop.stop_lat, first_stop.stop_lon)

    # last stop location
    last_stop = net.stops[st2.stop]
    last_stop_ll = LatLon(last_stop.stop_lat, last_stop.stop_lon)

    if reversed
        # reverse them, warning handled at build time
        st2, st1 = st1, st2
    end

    # find first point
    first_offset = findfirst(shape.shape_dist_traveled .≥ st1.shape_dist_traveled)
    last_offset = findfirst(shape.shape_dist_traveled .> st2.shape_dist_traveled)

    # handle stops at or past the final point of the shape
    if !isnothing(last_offset)
        last_offset -= 1
    else
        last_offset = lastindex(shape.shape_dist_traveled)
    end

    # make the geometry
    geom = LatLon{Float64}[]

    # avoid duplicates, don't add it if the point is in the shape
    if !(first_stop_ll ≈ shape.geom[first_offset])
        push!(geom, first_stop_ll)
    end

    # intermediate shape locations
    for ptidx in first_offset:last_offset
        point = shape.geom[ptidx]
        push!(geom, point)
    end

    if !(last_stop_ll ≈ last(geom))
        push!(geom, last_stop_ll)
    end

    if reversed
        reverse!(geom)
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
    st1idx = findfirst(trip.stop_times .== Ref(st1))
    st2idx = findfirst(trip.stop_times .== Ref(st2))
    !isnothing(st1idx) && !isnothing(st2idx) || error("Stop time not found in trip!")
    geom = LatLon{Float64}[]
    for stop_time in trip.stop_times[st1idx:st2idx]
        stop = net.stops[stop_time.stop]
        push!(geom, LatLon(stop.stop_lat, stop.stop_lon))
    end

    return geom
end

function infer_shape_dist_traveled(shape, lat, lon)
    # create the line string
    firstpt = first(shape.geom)
    coslat = cosd(firstpt.lat)

    # create the linestring
    coords = map(shape.geom) do coord
        [coord.lon * coslat, coord.lat]
    end
    geosgeom = LibGEOS.LineString(coords)

    projected_space_dist = LibGEOS.project(geosgeom, LibGEOS.Point(lon * coslat, lat))

    # short circuit here in case it's a little less than 0
    if projected_space_dist ≈ 0.0
        return first(shape.shape_dist_traveled)
    end

    # figure out where it is on the line
    cumulative_projected_dist = 0.0
    prev_dist = 0.0
    prev, rest = Iterators.peel(coords)
    for (prev_idx, pt) in enumerate(rest)
        cumulative_projected_dist += sqrt((pt[1] - prev[1]) ^ 2 + (pt[2] - prev[2]) ^ 2)
        if cumulative_projected_dist ≥ projected_space_dist && prev_dist ≤ projected_space_dist
            # we have found the segment, now find the fraction
            frac = (projected_space_dist - prev_dist) / (cumulative_projected_dist - prev_dist)
            return shape.shape_dist_traveled[prev_idx] + frac * (shape.shape_dist_traveled[prev_idx + 1] - shape.shape_dist_traveled[prev_idx])
        end
        prev = pt
        prev_dist = cumulative_projected_dist
    end

    # handle stop at/past end of shape
    return cumulative_projected_dist

end