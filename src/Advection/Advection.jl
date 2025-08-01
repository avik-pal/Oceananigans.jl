module Advection

export
    div_𝐯u, div_𝐯v, div_𝐯w, div_Uc,

    momentum_flux_uu,
    momentum_flux_uv,
    momentum_flux_uw,
    momentum_flux_vu,
    momentum_flux_vv,
    momentum_flux_vw,
    momentum_flux_wu,
    momentum_flux_wv,
    momentum_flux_ww,
    advective_tracer_flux_x,
    advective_tracer_flux_y,
    advective_tracer_flux_z,

    AdvectionScheme,
    Centered, UpwindBiased, WENO,
    VectorInvariant, WENOVectorInvariant,
    FluxFormAdvection,
    EnergyConserving,
    EnstrophyConserving

using DocStringExtensions

using Base: @propagate_inbounds
using Adapt
using OffsetArrays
using MuladdMacro: @muladd

using Oceananigans
using Oceananigans.Grids
using Oceananigans.Operators

using Oceananigans: fully_supported_float_types
using Oceananigans.Architectures: architecture, CPU
using Oceananigans.Grids: with_halo
using Oceananigans.Operators: flux_div_xyᶜᶜᶜ, Γᶠᶠᶜ, ∂t_σ
using Oceananigans.Grids: XFlatGrid, YFlatGrid, ZFlatGrid

import Base: show, summary, Callable
import Oceananigans.Grids: required_halo_size_x, required_halo_size_y, required_halo_size_z
import Oceananigans.Architectures: on_architecture

abstract type AbstractAdvectionScheme{B, FT} end
abstract type AbstractCenteredAdvectionScheme{B, FT} <: AbstractAdvectionScheme{B, FT} end
abstract type AbstractUpwindBiasedAdvectionScheme{B, FT} <: AbstractAdvectionScheme{B, FT} end

# `advection_buffers` specifies the list of buffers for which advection schemes
# are constructed via metaprogramming. (The `advection_buffer` is the width of
# the halo region required for an advection scheme on a non-immersed-boundary grid.)
# An upper limit of `advection_buffer = 6` means we can build advection schemes up to
# `Centered(order=12`) and `UpwindBiased(order=11)`. The list can be extended in order to
# compile schemes with higher orders; for example `advection_buffers = [1, 2, 3, 4, 5, 6, 8]`
# will compile schemes for `advection_buffer=8` and thus `Centered(order=16)` and `UpwindBiased(order=15)`.
# Note that it is not possible to compile schemes for `advection_buffer = 41` or higher.
const advection_buffers = [1, 2, 3, 4, 5, 6]

@inline Base.eltype(::AbstractAdvectionScheme{<:Any, FT}) where FT = FT

@inline required_halo_size_x(::AbstractAdvectionScheme{B}) where B = B
@inline required_halo_size_y(::AbstractAdvectionScheme{B}) where B = B
@inline required_halo_size_z(::AbstractAdvectionScheme{B}) where B = B

include("centered_advective_fluxes.jl")
include("upwind_biased_advective_fluxes.jl")

include("reconstruction_coefficients.jl")
include("centered_reconstruction.jl")
include("upwind_biased_reconstruction.jl")
include("weno_reconstruction.jl")
include("weno_interpolants.jl")
include("stretched_weno_smoothness.jl")
include("multi_dimensional_reconstruction.jl")
include("vector_invariant_upwinding.jl")
include("vector_invariant_advection.jl")
include("vector_invariant_self_upwinding.jl")
include("vector_invariant_cross_upwinding.jl")
include("flux_form_advection.jl")

include("topologically_conditional_interpolation.jl")
include("flat_advective_fluxes.jl")
include("immersed_advective_fluxes.jl")
include("momentum_advection_operators.jl")
include("tracer_advection_operators.jl")
include("bounds_preserving_tracer_advection_operators.jl")
include("cell_advection_timescale.jl")
include("adapt_advection_order.jl")

end # module
