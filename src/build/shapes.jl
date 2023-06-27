# Threshold above which we warn for out-of-order shapes
# units are unspecified, but should be a small value consistent with rounding errors
const SHAPE_DIST_ϵ = 1e-6

function parse_shapes(shapestxt)
    df = CSV.read(shapestxt, DataFrame, types=Dict(:shape_id => String))
   
    # group by shape ID
    grouped = groupby(df, :shape_id)

    shapes = Dict{String, Shape}()

    for shapedf in grouped
        # sort the shape
        shapedf = sort(shapedf, :shape_pt_sequence)

        if "shape_dist_traveled" ∈ names(df) && !issorted(shapedf.shape_dist_traveled)
            @error "shape_dist_traveled is nonmonotonic for shape $(first(shapedf.shape_id)), skipping shape_dist_traveled for this shape"
            select!(shapedf, Not(:shape_dist_traveled))
        end

        geom = LatLon{Float64}[]

        for (lat, lon) in zip(shapedf.shape_pt_lat::Vector{Float64}, shapedf.shape_pt_lon::Vector{Float64})
            push!(geom, LatLon(lat, lon))
        end

        if "shape_dist_traveled" ∈ names(df)
            shape_dist_traveled = shapedf.shape_dist_traveled
            imputed = false
        else
            shape_dist_traveled = Float64[]
            sizehint!(shape_dist_traveled, nrow(shapedf))

            cumulative_dist = 0.0
            push!(shape_dist_traveled, cumulative_dist)
            firstp, rest = Iterators.peel(zip(shapedf.shape_pt_lat, shapedf.shape_pt_lon))

            prev_point = LatLon(firstp...)

            for row in rest
                point = LatLon(row...)
                cumulative_dist += euclidean_distance(prev_point, point)
                push!(shape_dist_traveled, cumulative_dist)
                prev_point = point
            end

            @assert length(shape_dist_traveled) == nrow(shapedf)

            imputed = true
        end

        shapes[first(shapedf.shape_id)] = Shape(geom, shape_dist_traveled, imputed)
    end

    return shapes
end

"""
Make sure shape points are in order, warn otherwise
"""
function check_and_warn_for_out_of_order_shape_points(trip_id, stop_times, net)
    for (st1, st2) in zip(stop_times[begin:end-1], stop_times[begin+1:end])
        if st1.shape_dist_traveled - st2.shape_dist_traveled > SHAPE_DIST_ϵ
            stopid1 = net.stops[st1.stop].stop_id
            stopid2 = net.stops[st2.stop].stop_id
            @warn "In trip $trip_id, stops $stopid1 and $stopid2 are out of order on shape"
        end
    end
end