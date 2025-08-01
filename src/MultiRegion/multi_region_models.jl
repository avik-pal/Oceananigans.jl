using Oceananigans.Models: AbstractModel
using Oceananigans.Advection: WENO, VectorInvariant
using Oceananigans.Models.HydrostaticFreeSurfaceModels: AbstractFreeSurface
using Oceananigans.TimeSteppers: AbstractTimeStepper, QuasiAdamsBashforth2TimeStepper
using Oceananigans.Models: PrescribedVelocityFields
using Oceananigans.TurbulenceClosures: VerticallyImplicitTimeDiscretization
using Oceananigans.Advection: AbstractAdvectionScheme
using Oceananigans.Advection: OnlySelfUpwinding, CrossAndSelfUpwinding
using Oceananigans.ImmersedBoundaries: GridFittedBottom, PartialCellBottom, GridFittedBoundary
using Oceananigans.Solvers: ConjugateGradientSolver

import Oceananigans.Advection: WENO, cell_advection_timescale, adapt_advection_order
import Oceananigans.Models.HydrostaticFreeSurfaceModels: build_implicit_step_solver, validate_tracer_advection
import Oceananigans.TurbulenceClosures: implicit_diffusion_solver

const MultiRegionModel = HydrostaticFreeSurfaceModel{<:Any, <:Any, <:AbstractArchitecture, <:Any, <:MultiRegionGrids}

function adapt_advection_order(advection::MultiRegionObject, grid::MultiRegionGrids)
    @apply_regionally new_advection = adapt_advection_order(advection, grid)
    return new_advection
end

# Utility to generate the inputs to complex `getregion`s
function getregionalproperties(T, inner=true)
    type = getglobal(@__MODULE__, T)
    names = fieldnames(type)
    args  = Vector(undef, length(names))
    for (n, name) in enumerate(names)
        args[n] = inner ? :(_getregion(t.$name, r)) : :(getregion(t.$name, r))
    end
    return args
end

Types = (:HydrostaticFreeSurfaceModel,
         :ImplicitFreeSurface,
         :ExplicitFreeSurface,
         :QuasiAdamsBashforth2TimeStepper,
         :SplitExplicitFreeSurface,
         :PrescribedVelocityFields,
         :ConjugateGradientSolver,
         :CrossAndSelfUpwinding,
         :OnlySelfUpwinding,
         :GridFittedBoundary,
         :GridFittedBottom,
         :PartialCellBottom)

for T in Types
    @eval begin
        # This assumes a constructor of the form T(arg1, arg2, ...) exists,
        # which is not the case for all types.
        @inline  getregion(t::$T, r) = $T($(getregionalproperties(T, true)...))
        @inline _getregion(t::$T, r) = $T($(getregionalproperties(T, false)...))
    end
end

@inline isregional(pv::PrescribedVelocityFields) = isregional(pv.u) | isregional(pv.v) | isregional(pv.w)
@inline devices(pv::PrescribedVelocityFields)    = devices(pv[findfirst(isregional, (pv.u, pv.v, pv.w))])

validate_tracer_advection(tracer_advection::MultiRegionObject, grid::MultiRegionGrids) = tracer_advection, NamedTuple()

@inline isregional(mrm::MultiRegionModel)   = true
@inline devices(mrm::MultiRegionModel)      = devices(mrm.grid)
@inline getdevice(mrm::MultiRegionModel, d) = getdevice(mrm.grid, d)

implicit_diffusion_solver(time_discretization::VerticallyImplicitTimeDiscretization, mrg::MultiRegionGrid) =
    construct_regionally(implicit_diffusion_solver, time_discretization, mrg)

WENO(mrg::MultiRegionGrid, args...; kwargs...) = construct_regionally(WENO, mrg, args...; kwargs...)

@inline getregion(t::VectorInvariant{N, FT, Z, ZS, V, K, D, U, M}, r) where {N, FT, Z, ZS, V, K, D, U, M} =
    VectorInvariant{N, FT, M}(_getregion(t.vorticity_scheme, r),
                              _getregion(t.vorticity_stencil, r),
                              _getregion(t.vertical_advection_scheme, r),
                              _getregion(t.kinetic_energy_gradient_scheme, r),
                              _getregion(t.divergence_scheme, r),
                              _getregion(t.upwinding, r))

@inline _getregion(t::VectorInvariant{N, FT, Z, ZS, V, K, D, U, M}, r) where {N, FT, Z, ZS, V, K, D, U, M} =
    VectorInvariant{N, FT, M}(getregion(t.vorticity_scheme, r),
                              getregion(t.vorticity_stencil, r),
                              getregion(t.vertical_advection_scheme, r),
                              getregion(t.kinetic_energy_gradient_scheme, r),
                              getregion(t.divergence_scheme, r),
                              getregion(t.upwinding, r))

function cell_advection_timescale(grid::MultiRegionGrids, velocities)
    Δt = construct_regionally(cell_advection_timescale, grid, velocities)
    return minimum(Δt.regional_objects)
end
