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