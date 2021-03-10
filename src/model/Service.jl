# represents a service - i.e. is a service running on a given day?
using Dates

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

