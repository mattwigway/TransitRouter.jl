# Represents a stop time, which is only referenced in the transit network within trips
struct StopTime
    # NB possible optimization: stop is not even needed, as it's in the pattern
    # but that might not actually help, because by iterating over stop times, we are keeping everything memory locality
    stop::Int64
    # NB possible optimization - stop sequence is only needed before the graph is built
    stop_sequence::Int32
    arrival_time::Int32
    departure_time::Int32
end