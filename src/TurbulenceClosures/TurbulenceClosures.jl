module TurbulenceClosures

export
    AbstractEddyViscosityClosure,
    VerticalScalarDiffusivity,
    HorizontalScalarDiffusivity,
    HorizontalDivergenceScalarDiffusivity,
    ScalarDiffusivity,
    VerticalScalarBiharmonicDiffusivity,
    HorizontalScalarBiharmonicDiffusivity,
    HorizontalDivergenceScalarBiharmonicDiffusivity,
    ScalarBiharmonicDiffusivity,
    TwoDimensionalLeith,
    SmagorinskyLilly,
    Smagorinsky,
    LillyCoefficient,
    DynamicCoefficient,
    AnisotropicMinimumDissipation,
    ConvectiveAdjustmentVerticalDiffusivity,
    RiBasedVerticalDiffusivity,
    IsopycnalSkewSymmetricDiffusivity,
    CATKEVerticalDiffusivity,
    TKEDissipationVerticalDiffusivity,
    FluxTapering,

    ExplicitTimeDiscretization,
    VerticallyImplicitTimeDiscretization,

    build_diffusivity_fields,
    compute_diffusivities!,

    viscosity, diffusivity,

    ∇_dot_qᶜ,
    ∂ⱼ_τ₁ⱼ,
    ∂ⱼ_τ₂ⱼ,
    ∂ⱼ_τ₃ⱼ,

    cell_diffusion_timescale

using KernelAbstractions
using Adapt

import Oceananigans.Utils: with_tracers, prettysummary

using Oceananigans
using Oceananigans.Architectures
using Oceananigans.Grids
using Oceananigans.Operators
using Oceananigans.BoundaryConditions
using Oceananigans.Fields
using Oceananigans.BuoyancyFormulations
using Oceananigans.Utils

using Oceananigans.Architectures: AbstractArchitecture, device
using Oceananigans.Fields: FunctionField
using Oceananigans.ImmersedBoundaries
using Oceananigans.ImmersedBoundaries: AbstractGridFittedBottom

import Oceananigans.Grids: required_halo_size_x, required_halo_size_y, required_halo_size_z
import Oceananigans.Architectures: on_architecture

const VerticallyBoundedGrid{FT} = AbstractGrid{FT, <:Any, <:Any, <:Bounded}

#####
##### Abstract types
#####

"""
    AbstractTurbulenceClosure

Abstract supertype for turbulence closures.
"""
abstract type AbstractTurbulenceClosure{TimeDiscretization, RequiredHalo} end

# Fallbacks
validate_closure(closure) = closure
closure_summary(closure) = summary(closure)
with_tracers(tracers, closure::AbstractTurbulenceClosure) = closure
compute_diffusivities!(K, closure::AbstractTurbulenceClosure, args...; kwargs...) = nothing

# The required halo size to calculate diffusivities. Take care that if the diffusivity can
# be calculated from local information, still `B = 1`, because we need at least one additional
# point at each side to calculate viscous fluxes at the edge of the domain.
# If diffusivity itself requires one halo to be computed (e.g. κ = ℑxᶠᵃᵃ(i, j, k, grid, ℑxᶜᵃᵃ, T),
# or `AnisotropicMinimumDissipation` and `Smagorinsky`) then B = 2
@inline required_halo_size_x(::AbstractTurbulenceClosure{TD, B}) where {TD, B} = B
@inline required_halo_size_y(::AbstractTurbulenceClosure{TD, B}) where {TD, B} = B
@inline required_halo_size_z(::AbstractTurbulenceClosure{TD, B}) where {TD, B} = B

const ClosureKinda = Union{Nothing, AbstractTurbulenceClosure, AbstractArray{<:AbstractTurbulenceClosure}}
add_closure_specific_boundary_conditions(closure::ClosureKinda, bcs, args...) = bcs

# Interface for KE-based closures
function shear_production end
function buoyancy_flux end
function dissipation end
function hydrostatic_turbulent_kinetic_energy_tendency end

#####
##### Fallback: flux = 0
#####

for dir in (:x, :y, :z)
    diffusive_flux = Symbol(:diffusive_flux_, dir)
    viscous_flux_u = Symbol(:viscous_flux_u, dir)
    viscous_flux_v = Symbol(:viscous_flux_v, dir)
    viscous_flux_w = Symbol(:viscous_flux_w, dir)
    @eval begin
        @inline $diffusive_flux(i, j, k, grid, clo::AbstractTurbulenceClosure, args...) = zero(grid)
        @inline $viscous_flux_u(i, j, k, grid, clo::AbstractTurbulenceClosure, args...) = zero(grid)
        @inline $viscous_flux_v(i, j, k, grid, clo::AbstractTurbulenceClosure, args...) = zero(grid)
        @inline $viscous_flux_w(i, j, k, grid, clo::AbstractTurbulenceClosure, args...) = zero(grid)
    end
end

#####
##### The magic
#####

# Closure ensemble util
@inline getclosure(i, j, closure::AbstractMatrix{<:AbstractTurbulenceClosure}) = @inbounds closure[i, j]
@inline getclosure(i, j, closure::AbstractVector{<:AbstractTurbulenceClosure}) = @inbounds closure[i]
@inline getclosure(i, j, closure::AbstractTurbulenceClosure) = closure

@inline clip(x) = max(zero(x), x)

#####
##### Height, Depth and Bottom interfaces
#####

const c = Center()
const f = Face()

const AGFBIBG = ImmersedBoundaryGrid{<:Any, <:Any, <:Any, <:Any, <:Any, <:AbstractGridFittedBottom}

@inline z_top(i, j, grid) = znode(i, j, grid.Nz+1, grid, c, c, f)
@inline z_bottom(i, j, grid) = znode(i, j, 1, grid, c, c, f)
@inline z_bottom(i, j, ibg::AGFBIBG) = @inbounds ibg.immersed_boundary.bottom_height[i, j, 1]

@inline depthᶜᶜᶠ(i, j, k, grid) = clip(z_top(i, j, grid) - znode(i, j, k, grid, c, c, f))
@inline depthᶜᶜᶜ(i, j, k, grid) = clip(z_top(i, j, grid) - znode(i, j, k, grid, c, c, c))

@inline function height_above_bottomᶜᶜᶠ(i, j, k, grid)
    h = znode(i, j, k, grid, c, c, f) - z_bottom(i, j, grid)

    # Limit by thickness of cell below
    Δz = Δzᶜᶜᶜ(i, j, k-1, grid)
    return max(Δz, h)
end

@inline function height_above_bottomᶜᶜᶜ(i, j, k, grid)
    Δz = Δzᶜᶜᶜ(i, j, k, grid)
    h = znode(i, j, k, grid, c, c, c) - z_bottom(i, j, grid)
    return max(Δz/2, h)
end

@inline wall_vertical_distanceᶜᶜᶠ(i, j, k, grid) = min(depthᶜᶜᶠ(i, j, k, grid), height_above_bottomᶜᶜᶠ(i, j, k, grid))
@inline wall_vertical_distanceᶜᶜᶜ(i, j, k, grid) = min(depthᶜᶜᶜ(i, j, k, grid), height_above_bottomᶜᶜᶜ(i, j, k, grid))

include("discrete_diffusion_function.jl")
include("implicit_explicit_time_discretization.jl")
include("turbulence_closure_utils.jl")
include("closure_kernel_operators.jl")
include("velocity_tracer_gradients.jl")
include("abstract_scalar_diffusivity_closure.jl")
include("abstract_scalar_biharmonic_diffusivity_closure.jl")
include("closure_tuples.jl")
include("isopycnal_rotation_tensor_components.jl")
include("immersed_diffusive_fluxes.jl")

# Implicit closure terms (diffusion + linear terms)
include("vertically_implicit_diffusion_solver.jl")

# Implementations:
include("turbulence_closure_implementations/nothing_closure.jl")

# AbstractScalarDiffusivity closures:
include("turbulence_closure_implementations/scalar_diffusivity.jl")
include("turbulence_closure_implementations/scalar_biharmonic_diffusivity.jl")

# Dispatch on the type of the user-provided AMD model constant.
# Only numbers, arrays, and functions supported now.
@inline closure_coefficient(i, j, k, grid, C::Number) = C
@inline closure_coefficient(i, j, k, grid, C::AbstractArray) = @inbounds C[i, j, k]

include("turbulence_closure_implementations/anisotropic_minimum_dissipation.jl")
include("turbulence_closure_implementations/Smagorinskys/Smagorinskys.jl")
include("turbulence_closure_implementations/convective_adjustment_vertical_diffusivity.jl")
include("turbulence_closure_implementations/TKEBasedVerticalDiffusivities/TKEBasedVerticalDiffusivities.jl")
include("turbulence_closure_implementations/ri_based_vertical_diffusivity.jl")

# Special non-abstracted diffusivities:
# TODO: introduce abstract typing for these
include("turbulence_closure_implementations/isopycnal_skew_symmetric_diffusivity.jl")
include("turbulence_closure_implementations/isopycnal_skew_symmetric_diffusivity_with_triads.jl")
include("turbulence_closure_implementations/advective_skew_diffusion.jl")
include("turbulence_closure_implementations/leith_enstrophy_diffusivity.jl")

using .TKEBasedVerticalDiffusivities: CATKEVerticalDiffusivity, TKEDissipationVerticalDiffusivity
using .Smagorinskys: Smagorinsky, DynamicSmagorinsky, SmagorinskyLilly
using .Smagorinskys: LillyCoefficient, DynamicCoefficient, LagrangianAveraging

# Miscellaneous utilities
include("diffusivity_fields.jl")
include("turbulence_closure_diagnostics.jl")

#####
##### Some value judgements here
#####

end # module

