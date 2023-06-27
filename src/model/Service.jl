# represents a service - i.e. is a service running on a given day?
struct Service
    monday::Bool
    tuesday::Bool
    wednesday::Bool
    thursday::Bool
    friday::Bool
    saturday::Bool
    sunday::Bool
    start_date::Date
    end_date::Date
    added_dates::Array{Date}
    removed_dates::Array{Date}
end

function is_service_running(service::Service, date::Date)::Bool
    # first check calendar_dates
    if date ∈ service.added_dates
        return true
    elseif date ∈ service.removed_dates
        return false
    else
        dow = Dates.dayofweek(date)
        # first check calendar
        return (
            date >= service.start_date &&
            date <= service.end_date && (
                (dow == 1 && service.monday) ||
                (dow == 2 && service.tuesday) ||
                (dow == 3 && service.wednesday) ||
                (dow == 4 && service.thursday) ||
                (dow == 5 && service.friday) ||
                (dow == 6 && service.saturday) ||
                (dow == 7 && service.sunday)
            )
        )
    end
end