# This testset tests the range-RAPTOR functionality in two ways:
# first, it makes sure that the appropriate trips are found over time,
# and second, it makes sure that "transfer compression" works. 
# The network looks like this:


@testset "Range-RAPTOR" begin
    include("range-raptor/test-empirical.jl")
end