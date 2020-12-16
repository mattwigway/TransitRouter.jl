# Build a network from a GTFS file name
using ZipFile
using CSV
using DataFrames

function build (gtfs_filenames...)
    stops = Array{Stop}

    for gtfs_filename in gtfs_filenames
        stop_number_for_stop_id::Dict{String,UInt16} = Dict()

        println("Reading $gtfs_filename...")

        # first read stops
        r = ZipFile.Reader(gtfs_filename)
        filename_map = Dict(f.name=>f for f in r.files)
        stop_df = DataFrame(CSV.File(read(filename_map["stops.txt"])))
        nstops = nrow(df)

        println("Read $nstops")
    end
end
