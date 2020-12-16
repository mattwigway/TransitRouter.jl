push!(LOAD_PATH, pwd())  # TODO should be relative to soource file not working
using TransitRouter

build(ARGS...)
