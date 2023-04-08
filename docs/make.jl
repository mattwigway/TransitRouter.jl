using Documenter, TransitRouter

makedocs(sitename="TransitRouter.jl")

if haskey(env, "CI")
    deploydocs(repo="github.com/mattwigway/TransitRouter.jl")
end