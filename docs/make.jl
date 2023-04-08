using Documenter, TransitRouter

makedocs(sitename="TransitRouter.jl")

if haskey(ENV, "CI")
    deploydocs(repo="github.com/mattwigway/TransitRouter.jl")
end