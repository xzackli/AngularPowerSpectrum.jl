using Test

@show Threads.nthreads()
include("test_spectralarray.jl")
include("test_mcm.jl")
include("test_covmat.jl")
include("test_util.jl")
include("test_mcm_planck.jl")
