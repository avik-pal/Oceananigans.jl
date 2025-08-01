using Oceananigans.Operators

"""
    AnisotropicMinimumDissipation{FT} <: AbstractTurbulenceClosure

Parameters for the "anisotropic minimum dissipation" turbulence closure for large eddy simulation
proposed originally by [Rozema15](@citet) and [Abkar16](@citet), then modified by [Verstappen18](@citet),
and finally described and validated for by [Vreugdenhil18](@citet).
"""
struct AnisotropicMinimumDissipation{TD, PK, PN, PB} <: AbstractScalarDiffusivity{TD, ThreeDimensionalFormulation, 2}
    Cν :: PN
    Cκ :: PK
    Cb :: PB

    function AnisotropicMinimumDissipation{TD}(Cν::PN, Cκ::PK, Cb::PB) where {TD, PN, PK, PB}
        return new{TD, PK, PN, PB}(Cν, Cκ, Cb)
    end
end

const AMD = AnisotropicMinimumDissipation

@inline viscosity(::AMD, K) = K.νₑ
@inline diffusivity(::AMD, K, ::Val{id}) where id = K.κₑ[id]

Base.show(io::IO, closure::AMD{TD}) where TD =
    print(io, "AnisotropicMinimumDissipation{$TD} turbulence closure with:\n",
              "           Poincaré constant for momentum eddy viscosity Cν: ", closure.Cν, "\n",
              "    Poincaré constant for tracer(s) eddy diffusivit(ies) Cκ: ", closure.Cκ, "\n",
              "                        Buoyancy modification multiplier Cb: ", closure.Cb)

"""
    AnisotropicMinimumDissipation([time_discretization = ExplicitTimeDiscretization, FT = Float64;]
                                  C = 1/3, Cν = nothing, Cκ = nothing, Cb = nothing)

Return parameters of type `FT` for the `AnisotropicMinimumDissipation`
turbulence closure.

Arguments
=========

* `time_discretization`: Either `ExplicitTimeDiscretization()` or `VerticallyImplicitTimeDiscretization()`,
                         which integrates the terms involving only ``z``-derivatives in the
                         viscous and diffusive fluxes with an implicit time discretization.
                         Default `ExplicitTimeDiscretization()`.

* `FT`: Float type; default `Float64`.


Keyword arguments
=================
* `C`: Poincaré constant for both eddy viscosity and eddy diffusivities. `C` is overridden
       for eddy viscosity or eddy diffusivity if `Cν` or `Cκ` are set, respectively.

* `Cν`: Poincaré constant for momentum eddy viscosity.

* `Cκ`: Poincaré constant for tracer eddy diffusivities. If one number or function, the same
        number or function is applied to all tracers. If a `NamedTuple`, it must possess
        a field specifying the Poincaré constant for every tracer.

* `Cb`: Buoyancy modification multiplier (`Cb = nothing` turns it off, `Cb = 1` was used by
        [Abkar et al. (2016)](@cite Abkar16)). *Note*: that we _do not_ subtract the
        horizontally-average component before computing this buoyancy modification term.
        This implementation differs from that by [Abkar et al. (2016)](@cite Abkar16)'s proposal
        and the impact of this approximation has not been tested or validated.

By default: `C = Cν = Cκ = 1/3`, and `Cb = nothing`, which turns off the buoyancy modification term.
The default Poincaré constant is found by discretizing subgrid scale energy production, assuming a
second-order advection scheme. [Verstappen et al. (2014)](@cite Verstappen14) show that the Poincaré constant
should be 4 times larger than for straightforward (spectral) discretisation, resulting in `C = 1/3`
in our formulation. They also empirically demonstrated that this coefficient produces the correct
discrete production-dissipation balance. Further demonstration of this can be found at
[https://github.com/CliMA/Oceananigans.jl/issues/4367](https://github.com/CliMA/Oceananigans.jl/issues/4367).

`C`, `Cν` and `Cκ` may be numbers, or functions of `x, y, z`.

Examples
========

```jldoctest
julia> using Oceananigans

julia> pretty_diffusive_closure = AnisotropicMinimumDissipation(C=1/2)
AnisotropicMinimumDissipation{ExplicitTimeDiscretization} turbulence closure with:
           Poincaré constant for momentum eddy viscosity Cν: 0.5
    Poincaré constant for tracer(s) eddy diffusivit(ies) Cκ: 0.5
                        Buoyancy modification multiplier Cb: nothing
```

```jldoctest
julia> using Oceananigans

julia> const Δz = 0.5; # grid resolution at surface

julia> surface_enhanced_tracer_C(x, y, z) = 1/12 * (1 + exp((z + Δz/2) / 8Δz));

julia> fancy_closure = AnisotropicMinimumDissipation(Cκ=surface_enhanced_tracer_C)
AnisotropicMinimumDissipation{ExplicitTimeDiscretization} turbulence closure with:
           Poincaré constant for momentum eddy viscosity Cν: 0.3333333333333333
    Poincaré constant for tracer(s) eddy diffusivit(ies) Cκ: surface_enhanced_tracer_C
                        Buoyancy modification multiplier Cb: nothing
```

```jldoctest
julia> using Oceananigans

julia> tracer_specific_closure = AnisotropicMinimumDissipation(Cκ=(c₁=1/12, c₂=1/6))
AnisotropicMinimumDissipation{ExplicitTimeDiscretization} turbulence closure with:
           Poincaré constant for momentum eddy viscosity Cν: 0.3333333333333333
    Poincaré constant for tracer(s) eddy diffusivit(ies) Cκ: (c₁ = 0.08333333333333333, c₂ = 0.16666666666666666)
                        Buoyancy modification multiplier Cb: nothing
```

References
==========

Abkar, M., Bae, H. J., & Moin, P. (2016). Minimum-dissipation scalar transport model for
    large-eddy simulation of turbulent flows. Physical Review Fluids, 1(4), 041701.

Verstappen, R., Rozema, W., and Bae, J. H. (2014), "Numerical scale separation in large-eddy
    simulation", Center for Turbulence ResearchProceedings of the Summer Program 2014.

Vreugdenhil C., and Taylor J. (2018), "Large-eddy simulations of stratified plane Couette
    flow using the anisotropic minimum-dissipation model", Physics of Fluids 30, 085104.

Verstappen, R. (2018), "How much eddy dissipation is needed to counterbalance the nonlinear
    production of small, unresolved scales in a large-eddy simulation of turbulence?",
    Computers & Fluids 176, pp. 276-284.
"""
function AnisotropicMinimumDissipation(time_disc::TD = ExplicitTimeDiscretization(), FT = Oceananigans.defaults.FloatType;
                                       C = FT(1/3), Cν = nothing, Cκ = nothing, Cb = nothing) where TD

    Cν = Cν === nothing ? C : Cν
    Cκ = Cκ === nothing ? C : Cκ

    !isnothing(Cb) && @warn "AnisotropicMinimumDissipation with buoyancy modification is unvalidated."

    return AnisotropicMinimumDissipation{TD}(Cν, Cκ, Cb)
end

AnisotropicMinimumDissipation(FT::DataType; kw...) = AnisotropicMinimumDissipation(ExplicitTimeDiscretization(), FT; kw...)

function with_tracers(tracers, closure::AnisotropicMinimumDissipation{TD}) where TD
    Cκ = tracer_diffusivities(tracers, closure.Cκ)
    return AnisotropicMinimumDissipation{TD}(closure.Cν, Cκ, closure.Cb)
end

#####
##### Kernel functions
#####


@kernel function _compute_AMD_viscosity!(νₑ, grid, closure::AMD, buoyancy, velocities, tracers)
    i, j, k = @index(Global, NTuple)

    FT = eltype(grid)
    ijk = (i, j, k, grid)
    q = norm_tr_∇uᶜᶜᶜ(ijk..., velocities.u, velocities.v, velocities.w)
    Cb = closure.Cb

    if q == 0 # SGS viscosity is zero when strain is 0
        νˢᵍˢ = zero(FT)
    else
        r = norm_uᵢₐ_uⱼₐ_Σᵢⱼᶜᶜᶜ(ijk..., closure, velocities.u, velocities.v, velocities.w)

        # So-called buoyancy modification term:
        Cb_ζ = Cb_norm_wᵢ_bᵢᶜᶜᶜ(ijk..., Cb, closure, buoyancy, velocities.w, tracers) / Δᶠzᶜᶜᶜ(ijk...)

        δ² = 3 / (1 / Δᶠxᶜᶜᶜ(ijk...)^2 + 1 / Δᶠyᶜᶜᶜ(ijk...)^2 + 1 / Δᶠzᶜᶜᶜ(ijk...)^2)

        νˢᵍˢ = - closure_coefficient(i, j, k, grid, closure.Cν) * δ² * (r - Cb_ζ) / q
    end

    @inbounds νₑ[i, j, k] = max(zero(FT), νˢᵍˢ)
end

@kernel function _compute_AMD_diffusivity!(κₑ, grid, closure::AMD, tracer, ::Val{tracer_index}, velocities) where {tracer_index}
    i, j, k = @index(Global, NTuple)

    FT = eltype(grid)
    ijk = (i, j, k, grid)

    @inbounds Cκ = closure.Cκ[tracer_index]

    σ = norm_θᵢ²ᶜᶜᶜ(i, j, k, grid, tracer)

    if σ == 0 # denominator is zero: short-circuit computations and set subfilter diffusivity to zero.
        κˢᵍˢ = zero(FT)
    else
        ϑ =  norm_uᵢⱼ_cⱼ_cᵢᶜᶜᶜ(ijk..., closure, velocities.u, velocities.v, velocities.w, tracer)
        δ² = 3 / (1 / Δᶠxᶜᶜᶜ(ijk...)^2 + 1 / Δᶠyᶜᶜᶜ(ijk...)^2 + 1 / Δᶠzᶜᶜᶜ(ijk...)^2)
        κˢᵍˢ = - closure_coefficient(i, j, k, grid, Cκ) * δ² * ϑ / σ
    end

    @inbounds κₑ[i, j, k] = max(zero(FT), κˢᵍˢ)
end

function compute_diffusivities!(diffusivity_fields, closure::AnisotropicMinimumDissipation, model; parameters = :xyz)
    grid = model.grid
    arch = model.architecture
    velocities = model.velocities
    tracers = model.tracers
    buoyancy = model.buoyancy

    launch!(arch, grid, parameters, _compute_AMD_viscosity!,
            diffusivity_fields.νₑ, grid, closure, buoyancy, velocities, tracers)

    for (tracer_index, κₑ) in enumerate(diffusivity_fields.κₑ)
        @inbounds tracer = tracers[tracer_index]
        launch!(arch, grid, parameters, _compute_AMD_diffusivity!,
                κₑ, grid, closure, tracer, Val(tracer_index), velocities)
    end

    return nothing
end


#####
##### Filter width at various locations
#####

# Recall that filter widths are 2x the grid spacing in AMD
@inline Δᶠxᶜᶜᶜ(i, j, k, grid) = 2 * Δxᶜᶜᶜ(i, j, k, grid)
@inline Δᶠyᶜᶜᶜ(i, j, k, grid) = 2 * Δyᶜᶜᶜ(i, j, k, grid)
@inline Δᶠzᶜᶜᶜ(i, j, k, grid) = 2 * Δzᶜᶜᶜ(i, j, k, grid)

for loc in (:ccf, :fcc, :cfc, :ffc, :cff, :fcf), ξ in (:x, :y, :z)
    Δ_loc = Symbol(:Δᶠ, ξ, :_, loc)
    Δᶜᶜᶜ = Symbol(:Δᶠ, ξ, :ᶜᶜᶜ)
    @eval begin
        const $Δ_loc = $Δᶜᶜᶜ
    end
end

#####
##### The *** 30 terms *** of AMD
#####

@inline function norm_uᵢₐ_uⱼₐ_Σᵢⱼᶜᶜᶜ(i, j, k, grid, closure, u, v, w)
    ijk = (i, j, k, grid)
    uvw = (u, v, w)
    ijkuvw = (i, j, k, grid, u, v, w)

    uᵢ₁_uⱼ₁_Σ₁ⱼ = (
         norm_Σ₁₁(ijkuvw...) * norm_∂x_u(ijk..., u)^2
      +  norm_Σ₂₂(ijkuvw...) * ℑxyᶜᶜᵃ(ijk..., norm_∂x_v², uvw...)
      +  norm_Σ₃₃(ijkuvw...) * ℑxzᶜᵃᶜ(ijk..., norm_∂x_w², uvw...)

      +  2 * norm_∂x_u(ijkuvw...) * ℑxyᶜᶜᵃ(ijk..., norm_∂x_v_Σ₁₂, uvw...)
      +  2 * norm_∂x_u(ijkuvw...) * ℑxzᶜᵃᶜ(ijk..., norm_∂x_w_Σ₁₃, uvw...)
      +  2 * ℑxyᶜᶜᵃ(ijk..., norm_∂x_v, uvw...) * ℑxzᶜᵃᶜ(ijk..., norm_∂x_w, uvw...)
           * ℑyzᵃᶜᶜ(ijk..., norm_Σ₂₃, uvw...)
    )

    uᵢ₂_uⱼ₂_Σ₂ⱼ = (
      + norm_Σ₁₁(ijkuvw...) * ℑxyᶜᶜᵃ(ijk..., norm_∂y_u², uvw...)
      + norm_Σ₂₂(ijkuvw...) * norm_∂y_v(ijk..., v)^2
      + norm_Σ₃₃(ijkuvw...) * ℑyzᵃᶜᶜ(ijk..., norm_∂y_w², uvw...)

      +  2 * norm_∂y_v(ijkuvw...) * ℑxyᶜᶜᵃ(ijk..., norm_∂y_u_Σ₁₂, uvw...)
      +  2 * ℑxyᶜᶜᵃ(ijk..., norm_∂y_u, uvw...) * ℑyzᵃᶜᶜ(ijk..., norm_∂y_w, uvw...)
           * ℑxzᶜᵃᶜ(ijk..., norm_Σ₁₃, uvw...)
      +  2 * norm_∂y_v(ijkuvw...) * ℑyzᵃᶜᶜ(ijk..., norm_∂y_w_Σ₂₃, uvw...)
    )

    uᵢ₃_uⱼ₃_Σ₃ⱼ = (
      + norm_Σ₁₁(ijkuvw...) * ℑxzᶜᵃᶜ(ijk..., norm_∂z_u², uvw...)
      + norm_Σ₂₂(ijkuvw...) * ℑyzᵃᶜᶜ(ijk..., norm_∂z_v², uvw...)
      + norm_Σ₃₃(ijkuvw...) * norm_∂z_w(ijk..., w)^2

      +  2 * ℑxzᶜᵃᶜ(ijk..., norm_∂z_u, uvw...) * ℑyzᵃᶜᶜ(ijk..., norm_∂z_v, uvw...)
           * ℑxyᶜᶜᵃ(ijk..., norm_Σ₁₂, uvw...)
      +  2 * norm_∂z_w(ijkuvw...) * ℑxzᶜᵃᶜ(ijk..., norm_∂z_u_Σ₁₃, uvw...)
      +  2 * norm_∂z_w(ijkuvw...) * ℑyzᵃᶜᶜ(ijk..., norm_∂z_v_Σ₂₃, uvw...)
    )

    return uᵢ₁_uⱼ₁_Σ₁ⱼ + uᵢ₂_uⱼ₂_Σ₂ⱼ + uᵢ₃_uⱼ₃_Σ₃ⱼ
end

#####
##### trace(∇u) = uᵢⱼ uᵢⱼ
#####

@inline function norm_tr_∇uᶜᶜᶜ(i, j, k, grid, uvw...)
    ijk = (i, j, k, grid)

    return (
        # ccc
        norm_∂x_u²(ijk..., uvw...)
      + norm_∂y_v²(ijk..., uvw...)
      + norm_∂z_w²(ijk..., uvw...)

        # ffc
      + ℑxyᶜᶜᵃ(ijk..., norm_∂x_v², uvw...)
      + ℑxyᶜᶜᵃ(ijk..., norm_∂y_u², uvw...)

        # fcf
      + ℑxzᶜᵃᶜ(ijk..., norm_∂x_w², uvw...)
      + ℑxzᶜᵃᶜ(ijk..., norm_∂z_u², uvw...)

        # cff
      + ℑyzᵃᶜᶜ(ijk..., norm_∂y_w², uvw...)
      + ℑyzᵃᶜᶜ(ijk..., norm_∂z_v², uvw...)
    )
end

@inline Cb_norm_wᵢ_bᵢᶜᶜᶜ(i, j, k, grid::AbstractGrid{FT}, ::Nothing, args...) where FT = zero(FT)

@inline function Cb_norm_wᵢ_bᵢᶜᶜᶜ(i, j, k, grid, Cb, closure, buoyancy, w, tracers)
    ijk = (i, j, k, grid)

    wx_bx = (ℑxzᶜᵃᶜ(ijk..., norm_∂x_w, w)
             * Δᶠxᶜᶜᶜ(ijk...) * ℑxᶜᵃᵃ(ijk..., ∂xᶠᶜᶜ, buoyancy_perturbationᶜᶜᶜ, buoyancy.formulation, tracers))

    wy_by = (ℑyzᵃᶜᶜ(ijk..., norm_∂y_w, w)
             * Δᶠyᶜᶜᶜ(ijk...) * ℑyᵃᶜᵃ(ijk..., ∂yᶜᶠᶜ, buoyancy_perturbationᶜᶜᶜ, buoyancy.formulation, tracers))

    wz_bz = (norm_∂z_w(ijk..., w)
             * Δᶠzᶜᶜᶜ(ijk...) * ℑzᵃᵃᶜ(ijk..., ∂zᶜᶜᶠ, buoyancy_perturbationᶜᶜᶜ, buoyancy.formulation, tracers))

    return Cb * (wx_bx + wy_by + wz_bz)
end

@inline function norm_uᵢⱼ_cⱼ_cᵢᶜᶜᶜ(i, j, k, grid, closure, u, v, w, c)
    ijk = (i, j, k, grid)

    cx_ux = (
                  norm_∂x_u(ijk..., u) * ℑxᶜᵃᵃ(ijk..., norm_∂x_c², c)
        + ℑxyᶜᶜᵃ(ijk..., norm_∂x_v, v) * ℑxᶜᵃᵃ(ijk..., norm_∂x_c, c) * ℑyᵃᶜᵃ(ijk..., norm_∂y_c, c)
        + ℑxzᶜᵃᶜ(ijk..., norm_∂x_w, w) * ℑxᶜᵃᵃ(ijk..., norm_∂x_c, c) * ℑzᵃᵃᶜ(ijk..., norm_∂z_c, c)
    )

    cy_uy = (
          ℑxyᶜᶜᵃ(ijk..., norm_∂y_u, u) * ℑyᵃᶜᵃ(ijk..., norm_∂y_c, c) * ℑxᶜᵃᵃ(ijk..., norm_∂x_c, c)
        +         norm_∂y_v(ijk..., v) * ℑyᵃᶜᵃ(ijk..., norm_∂y_c², c)
        + ℑxzᶜᵃᶜ(ijk..., norm_∂y_w, w) * ℑyᵃᶜᵃ(ijk..., norm_∂y_c, c) * ℑzᵃᵃᶜ(ijk..., norm_∂z_c, c)
    )

    cz_uz = (
          ℑxzᶜᵃᶜ(ijk..., norm_∂z_u, u) * ℑzᵃᵃᶜ(ijk..., norm_∂z_c, c) * ℑxᶜᵃᵃ(ijk..., norm_∂x_c, c)
        + ℑyzᵃᶜᶜ(ijk..., norm_∂z_v, v) * ℑzᵃᵃᶜ(ijk..., norm_∂z_c, c) * ℑyᵃᶜᵃ(ijk..., norm_∂y_c, c)
        +         norm_∂z_w(ijk..., w) * ℑzᵃᵃᶜ(ijk..., norm_∂z_c², c)
    )

    return cx_ux + cy_uy + cz_uz
end

@inline norm_θᵢ²ᶜᶜᶜ(i, j, k, grid, c) = ℑxᶜᵃᵃ(i, j, k, grid, norm_∂x_c², c) +
                                        ℑyᵃᶜᵃ(i, j, k, grid, norm_∂y_c², c) +
                                        ℑzᵃᵃᶜ(i, j, k, grid, norm_∂z_c², c)

#####
##### build_diffusivity_fields
#####

function build_diffusivity_fields(grid, clock, tracer_names, user_bcs, ::AMD)

    default_diffusivity_bcs = FieldBoundaryConditions(grid, (Center(), Center(), Center()))
    default_κₑ_bcs = NamedTuple(c => default_diffusivity_bcs for c in tracer_names)
    κₑ_bcs = :κₑ ∈ keys(user_bcs) ? merge(default_κₑ_bcs, user_bcs.κₑ) : default_κₑ_bcs

    bcs = merge((; νₑ = default_diffusivity_bcs, κₑ = κₑ_bcs), user_bcs)

    νₑ = CenterField(grid, boundary_conditions=bcs.νₑ)
    κₑ = NamedTuple(c => CenterField(grid, boundary_conditions=bcs.κₑ[c]) for c in tracer_names)

    return (; νₑ, κₑ)
end
