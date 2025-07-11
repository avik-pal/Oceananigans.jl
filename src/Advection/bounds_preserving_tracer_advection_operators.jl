using Oceananigans.Grids: AbstractGrid

const _ω̂₁ = 5/18
const _ω̂ₙ = 5/18
const _ε₂ = 1e-20

# Note: this can probably be generalized to include UpwindBiased
const BoundsPreservingWENO = WENO{<:Any, <:Any, <:Any, <:Tuple}

@inline div_Uc(i, j, k, grid, advection::BoundsPreservingWENO, U, ::ZeroField) = zero(grid)

# Is this immersed-boundary safe without having to extend it in ImmersedBoundaries.jl? I think so... (velocity on immmersed boundaries is masked to 0)
@inline function div_Uc(i, j, k, grid, advection::BoundsPreservingWENO, U, c)

    div_x = bounded_tracer_flux_divergence_x(i, j, k, grid, advection, U.u, c)
    div_y = bounded_tracer_flux_divergence_y(i, j, k, grid, advection, U.v, c)
    div_z = bounded_tracer_flux_divergence_z(i, j, k, grid, advection, U.w, c)

    return 1/Vᶜᶜᶜ(i, j, k, grid) * (div_x + div_y + div_z)
end

# Support for Flat directions
@inline bounded_tracer_flux_divergence_x(i, j, k, ::AbstractGrid{FT, Flat, TY, TZ}, advection::BoundsPreservingWENO, args...) where {FT, TY, TZ} = zero(FT)
@inline bounded_tracer_flux_divergence_y(i, j, k, ::AbstractGrid{FT, TX, Flat, TZ}, advection::BoundsPreservingWENO, args...) where {FT, TX, TZ} = zero(FT)
@inline bounded_tracer_flux_divergence_z(i, j, k, ::AbstractGrid{FT, TX, TY, Flat}, advection::BoundsPreservingWENO, args...) where {FT, TX, TY} = zero(FT)

@inline function bounded_tracer_flux_divergence_x(i, j, k, grid, advection::BoundsPreservingWENO, u, c)


    lower_limit = @inbounds advection.bounds[1]
    upper_limit = @inbounds advection.bounds[2]

    cᵢⱼ = @inbounds c[i, j, k]

    c₊ᴸ = _biased_interpolate_xᶠᵃᵃ(i+1, j, k, grid, advection, LeftBias(),  c)
    c₊ᴿ = _biased_interpolate_xᶠᵃᵃ(i+1, j, k, grid, advection, RightBias(), c)
    c₋ᴸ = _biased_interpolate_xᶠᵃᵃ(i,   j, k, grid, advection, LeftBias(),  c)
    c₋ᴿ = _biased_interpolate_xᶠᵃᵃ(i,   j, k, grid, advection, RightBias(), c)

    FT = typeof(cᵢⱼ)
    ω̂₁ = convert(FT, _ω̂₁)
    ω̂ₙ = convert(FT, _ω̂ₙ)
    ε₂ = convert(FT, _ε₂)

    p̃ = (cᵢⱼ - ω̂₁ * c₋ᴿ - ω̂ₙ * c₊ᴸ) / (1 - 2ω̂₁)
    M = max(p̃, c₊ᴸ, c₋ᴿ)
    m = min(p̃, c₊ᴸ, c₋ᴿ)
    θ = min(abs((upper_limit - cᵢⱼ) / (M - cᵢⱼ + ε₂)), abs((lower_limit - cᵢⱼ) / (m - cᵢⱼ + ε₂)), one(grid))

    c₊ᴸ = θ * (c₊ᴸ - cᵢⱼ) + cᵢⱼ
    c₋ᴿ = θ * (c₋ᴿ - cᵢⱼ) + cᵢⱼ

    return @inbounds Axᶠᶜᶜ(i+1, j, k, grid) * upwind_biased_product(u[i+1, j, k], c₊ᴸ, c₊ᴿ) -
                     Axᶠᶜᶜ(i,   j, k, grid) * upwind_biased_product(u[i,   j, k], c₋ᴸ, c₋ᴿ)
end

@inline function bounded_tracer_flux_divergence_y(i, j, k, grid, advection::BoundsPreservingWENO, v, c)

    lower_limit = @inbounds advection.bounds[1]
    upper_limit = @inbounds advection.bounds[2]

    cᵢⱼ = @inbounds c[i, j, k]

    c₊ᴸ = _biased_interpolate_yᵃᶠᵃ(i, j+1, k, grid, advection, LeftBias(),  c)
    c₊ᴿ = _biased_interpolate_yᵃᶠᵃ(i, j+1, k, grid, advection, RightBias(), c)
    c₋ᴸ = _biased_interpolate_yᵃᶠᵃ(i, j,   k, grid, advection, LeftBias(),  c)
    c₋ᴿ = _biased_interpolate_yᵃᶠᵃ(i, j,   k, grid, advection, RightBias(), c)

    FT = typeof(cᵢⱼ)
    ω̂₁ = convert(FT, _ω̂₁)
    ω̂ₙ = convert(FT, _ω̂ₙ)
    ε₂ = convert(FT, _ε₂)

    p̃ = (cᵢⱼ - ω̂₁ * c₋ᴿ - ω̂ₙ * c₊ᴸ) / (1 - 2ω̂₁)
    M = max(p̃, c₊ᴸ, c₋ᴿ)
    m = min(p̃, c₊ᴸ, c₋ᴿ)
    θ = min(abs((upper_limit - cᵢⱼ) / (M - cᵢⱼ + ε₂)), abs((lower_limit - cᵢⱼ) / (m - cᵢⱼ + ε₂)), one(grid))

    c₊ᴸ = θ * (c₊ᴸ - cᵢⱼ) + cᵢⱼ
    c₋ᴿ = θ * (c₋ᴿ - cᵢⱼ) + cᵢⱼ

    return @inbounds Ayᶜᶠᶜ(i, j+1, k, grid) * upwind_biased_product(v[i, j+1, k], c₊ᴸ, c₊ᴿ) -
                     Ayᶜᶠᶜ(i, j,   k, grid) * upwind_biased_product(v[i, j,   k], c₋ᴸ, c₋ᴿ)
end

@inline function bounded_tracer_flux_divergence_z(i, j, k, grid, advection::BoundsPreservingWENO, w, c)

    lower_limit = @inbounds advection.bounds[1]
    upper_limit = @inbounds advection.bounds[2]

    cᵢⱼ = @inbounds c[i, j, k]

    c₊ᴸ = _biased_interpolate_zᵃᵃᶠ(i, j, k+1, grid, advection, LeftBias(),  c)
    c₊ᴿ = _biased_interpolate_zᵃᵃᶠ(i, j, k+1, grid, advection, RightBias(), c)
    c₋ᴸ = _biased_interpolate_zᵃᵃᶠ(i, j, k,   grid, advection, LeftBias(),  c)
    c₋ᴿ = _biased_interpolate_zᵃᵃᶠ(i, j, k,   grid, advection, RightBias(), c)

    FT = typeof(cᵢⱼ)
    ω̂₁ = convert(FT, _ω̂₁)
    ω̂ₙ = convert(FT, _ω̂ₙ)
    ε₂ = convert(FT, _ε₂)

    p̃ = (cᵢⱼ - ω̂₁ * c₋ᴿ - ω̂ₙ * c₊ᴸ) / (1 - 2ω̂₁)
    M = max(p̃, c₊ᴸ, c₋ᴿ)
    m = min(p̃, c₊ᴸ, c₋ᴿ)
    θ = min(abs((upper_limit - cᵢⱼ) / (M - cᵢⱼ + ε₂)), abs((lower_limit - cᵢⱼ) / (m - cᵢⱼ + ε₂)), one(grid))

    c₊ᴸ = θ * (c₊ᴸ - cᵢⱼ) + cᵢⱼ
    c₋ᴿ = θ * (c₋ᴿ - cᵢⱼ) + cᵢⱼ

    return @inbounds Azᶜᶜᶠ(i, j, k+1, grid) * upwind_biased_product(w[i, j, k+1], c₊ᴸ, c₊ᴿ) -
                     Azᶜᶜᶠ(i, j, k,   grid) * upwind_biased_product(w[i, j, k],   c₋ᴸ, c₋ᴿ)
end

