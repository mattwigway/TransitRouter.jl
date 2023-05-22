# basically what enumx does, but we roll our own so we can have a parse member function
module PickupDropoffType
    @enum T Scheduled=0 NotAvailable=1 PhoneAgency=2 CoordinateWithDriver=3

    function parse(x::Union{Integer, <:AbstractString, Nothing, Missing})
        if isnothing(x) || ismissing(x) || x == 0 || x == "0" || x == ""
            Scheduled
        elseif x == 1 || x == "1"
            NotAvailable
        elseif x == 2 || x == "2"
            PhoneAgency
        elseif x == 3 || x == "3"
            CoordinateWithDriver
        else
            @warn "Unknown pickup/dropoff type $x, assuming regularly scheduled"
            Scheduled
        end
    end
end

# Represents a stop time, which is only referenced in the transit network within trips
struct StopTime
    # NB possible optimization: stop is not even needed, as it's in the pattern
    # but that might not actually help, because by iterating over stop times, we are keeping everything memory locality
    stop::Int64
    # NB possible optimization - stop sequence is only needed before the graph is built
    stop_sequence::Int32
    arrival_time::Int32
    departure_time::Int32
    shape_dist_traveled::Union{Float64, Nothing}
    pickup_type::PickupDropoffType.T
    drop_off_type::PickupDropoffType.T
end