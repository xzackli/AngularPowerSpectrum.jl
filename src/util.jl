# utilities for power spectrum estimation

function binning_matrix(left_bins, right_bins, weight_function_ℓ; lmax=nothing)
    lmax = isnothing(lmax) ? right_bins[end] : lmax
    bincut = right_bins .≤ lmax
    left_bins = left_bins[bincut]
    right_bings = right_bins[bincut]

    nbins = length(left_bins)
    P = zeros(nbins, lmax+1)

    for b in 1:nbins
        weights = weight_function_ℓ.(left_bins[b]:right_bins[b])
        norm = sum(weights)
        P[b, left_bins[b]+1:right_bins[b]+1] .= weights ./ norm
    end
    return P
end


function read_commented_header(filename; delim=" ", strip_spaces=true)
    header = CSV.read(filename, DataFrame; header=false, delim=delim, ignorerepeated=true,
        limit=1, types=String)
    if strip_spaces
        headers = [String(strip(header[1,"Column$(i)"])) for i in 1:ncol(header)]

    else
        headers = [header[1,"Column$(i)"] for i in 1:ncol(header)]
    end
    if headers[1] == "#"   # skip the #
        headers = headers[2:end]
    elseif headers[1][1] == '#'
        headers[1] = String(strip(headers[1][2:end]))
    end

    table = CSV.read(filename, DataFrame; comment="#", header=headers, delim=delim,
        ignorerepeated=true)
    return table
end


@doc raw"""
    nside2lmax(nside)

Get the Nyquist frequency from nside, ``3n_{\mathrm{side}} - 1``.
"""
nside2lmax(nside) = 3nside - 1


"""A dictionary that always returns one thing, no matter what key."""
struct ConstantDict{K,V} <: AbstractDict{K,V}
    c::V
end
Base.getindex(d::ConstantDict, key) = d.c



@doc raw"""
    function fitdipole(m::HealpixMap{T}, [w::HealpixMap{T}=1]) where T

Fit the monopole and dipole of a map. 

# Arguments:
- `m::HealpixMap{T}`: map to fit
- `w::HealpixMap{T}`: weight map. Defaults to a FillArray of ones.

# Returns: 
- `Tuple{T, NTuple{3,T}}`: (monopole, (dipole x, dipole y, dipole z))
"""
fitdipole

# basic reference, from  https://healpix.jpl.nasa.gov/html/subroutinesnode86.htm
@refimpl function fitdipole(m::HealpixMap{T}, w::HealpixMap{T}) where T
    upA = zeros(T,4,4)  # upper triangular version of A
    b = zeros(T, 4)
    for p ∈ eachindex(m.pixels)
        x, y, z = pix2vecRing(m.resolution, p)
        s = SA[one(T), x, y, z]
        for i ∈ 1:4
            b[i] += s[i] * w.pixels[p] * m.pixels[p]
            for j ∈ i:4
                upA[i,j] += s[i] * w.pixels[p] * s[j]
            end
        end
    end
    f = Symmetric(upA) \ b
    return f[1], (f[2], f[3], f[4])  # monopole, dipole
end

# more accurate version using carry bits
function fitdipole(m::HealpixMap{T}, w::HealpixMap{T}) where T
    # A and b 
    upA = zeros(T,4,4)  # upper triangular version of A
    b = zeros(T, 4)

    # carry bits
    cA = zeros(T,4,4)
    cb = zeros(T,4)

    # using the Kahan-Babuska-Neumaier (KBN) algorithm for additional precision
    for p ∈ eachindex(m.pixels)
        x, y, z = pix2vecRing(m.resolution, p)
        s = SA[one(T), x, y, z]
        for i ∈ 1:4
            # sum the b vector
            inpb = s[i] * w.pixels[p] * m.pixels[p]
            sumb = b[i]
            tb = sumb + inpb
            if abs(sumb) ≥ abs(inpb)
                cb[i] += (sumb - tb) + inpb
            else
                cb[i] += (inpb - tb) + sumb
            end
            b[i] = tb

            for j ∈ i:4
                inpA = s[i] * w.pixels[p] * s[j]
                sumA = upA[i,j]
                tA = sumA + inpA
                if abs(sumA) ≥ abs(inpA)
                    cA[i,j] += (sumA - tA) + inpA
                else
                    cA[i,j] += (inpA - tA) + sumA
                end
                upA[i,j] = tA
            end
        end
    end
    f = Symmetric(upA .+ cA) \ (b .+ cb)
    return f[1], (f[2], f[3], f[4])  # monopole, dipole
end

function fitdipole(m::HealpixMap{T,O}) where {T,O}
    fitdipole(m, HealpixMap{T,O}(Ones(length(m.pixels))))
end


"""
    subtract_monopole_dipole!(map_in, monopole, dipole)

# Arguments:
- `map_in::HealpixMap`: the map to modify
- `monopole::T`: monopole value
- `dipole::NTuple{3,T}`: dipole value
"""
function subtract_monopole_dipole!(map_in::HealpixMap, 
        monopole::T, dipole::NTuple{3,T}) where T 
    res = map_in.resolution
    for p ∈ eachindex(map_in.pixels)
        x, y, z = pix2vecRing(res, p)
        t = monopole + dipole[1]*x + dipole[2]*y + dipole[3]*z
        map_in.pixels[p] -= t
    end
    map_in
end


"""
    synalm([rng=GLOBAL_RNG], Cl::AbstractArray{T,3}, nside::Int) where T

# Arguments:
- `Cl::AbstractArray{T,3}`: array with dimensions of comp, comp, ℓ
- `nside::Int`: healpix resolution

# Returns:
- `Vector{Alm{T}}`: spherical harmonics realizations for each component

# Examples
```julia
nside = 16
C0 = [3.  2.;  2.  5.]
Cl = repeat(C0, 1, 1, 3nside)  # spectra constant with ℓ
alms = synalm(Cl, nside)
```
"""
function synalm(rng::AbstractRNG, Cl::AbstractArray{T,3}, nside::Int) where T
    ncomp = size(Cl,1)
    @assert ncomp > 0
    alms = [Alm{Complex{T}}(3nside-1, 3nside-1) for i in 1:ncomp]
    synalm!(rng, Cl, alms)
    return alms
end
synalm(Cl::AbstractArray{T,3}, nside::Int) where T = synalm(Random.default_rng(), Cl, nside)


"""
    synalm!([rng=GLOBAL_RNG], Cl::AbstractArray{T,3}, alms::Vector{Alm{Complex{T}}}) where T

In-place synthesis of spherical harmonic coefficients, given spectra.

# Arguments:
- `Cl::AbstractArray{T,3}`: array with dimensions of comp, comp, ℓ
- `alms::Vector`: array of Alm to fill

# Examples
```julia
nside = 16
C0 = [3.  2.;  2.  5.]
Cl = repeat(C0, 1, 1, 3nside)  # spectra constant with ℓ
alms = [Alm{Complex{Float64}}(3nside-1, 3nside-1) for i in 1:2]
synalm!(Cl, alms)
```
"""
function synalm!(rng::AbstractRNG, Cl::AbstractArray{T,3}, alms::Vector) where {T}
    # This implementation could be 1.2x faster by storing the cholesky factorization, but
    # typically you also perform two SHTs with each synalm, which dominates the cost.

    ncomp = size(Cl,1)
    @assert ncomp > 0
    @assert size(Cl,1) == size(Cl,2)
    @assert size(alms,1) > 0
    lmax = alms[1].lmax

    # first we synthesize just a unit normal for alms. we'll adjust the magnitudes later
    for comp in 1:ncomp
        randn!(rng, alms[comp].alm)
    end
    𝐂 = Array{T,2}(undef, (ncomp, ncomp))  # covariance for this given ℓ
    h𝐂 = Hermitian(Array{T,2}(undef, (ncomp, ncomp)))  # hermitian buffer
    alm_out = zeros(Complex{T}, ncomp)
    alm_in = zeros(Complex{T}, ncomp)

    for ℓ in 0:lmax
        # build the 𝐂 matrix for ℓ
        for cᵢ in 1:ncomp, cⱼ in 1:ncomp
            𝐂[cᵢ, cⱼ] = Cl[cᵢ, cⱼ, ℓ+1]
        end

        if iszero(𝐂)
            for m in 0:ℓ
                i_alm = almIndex(alms[1], ℓ, m)  # compute alm index
                for comp in 1:ncomp  # copy buffer back into the alms
                    alms[comp].alm[i_alm] = zero(T)
                end
            end
        else
            h𝐂 .= Hermitian(𝐂)
            cholesky_factorizable = isposdef!(h𝐂)
            if !cholesky_factorizable
                𝐂 .= sqrt(𝐂)
                for m in 0:ℓ
                    i_alm = almIndex(alms[1], ℓ, m)  # compute alm index
                    for comp in 1:ncomp  # copy over the random variates into buffer
                        alm_in[comp] = alms[comp].alm[i_alm]
                    end
                    mul!(alm_out, 𝐂, alm_in)
                    for comp in 1:ncomp  # copy buffer back into the alms
                        alms[comp].alm[i_alm] = alm_out[comp]
                    end
                end
            else
                # cholesky!(h𝐂)  # we already cholesky'd by calling isposdef!
                for m in 0:ℓ
                    i_alm = almIndex(alms[1], ℓ, m)  # compute alm index
                    for comp in 1:ncomp  # copy over the random variates into buffer
                        alm_in[comp] = alms[comp].alm[i_alm]
                    end
                    lmul!(LowerTriangular(h𝐂'), alm_in)  # transform
                    for comp in 1:ncomp  # copy buffer back into the alms
                        alms[comp].alm[i_alm] = alm_in[comp]
                    end
                end
            end
        end
    end
end
synalm!(Cl::AbstractArray{T,3}, alms::Vector) where T = synalm!(Random.default_rng(), Cl, alms)


# Healpix parent 
Base.parent(x::HealpixMap) = x.pixels
