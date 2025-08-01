using Oceananigans.Solvers
using Oceananigans.Operators
using Oceananigans.Architectures
using Oceananigans.Fields: Field

using Oceananigans.Models.HydrostaticFreeSurfaceModels: compute_vertically_integrated_lateral_areas!,
                                                        compute_matrix_coefficients,
                                                        flux_div_xyᶜᶜᶠ,
                                                        PCGImplicitFreeSurfaceSolver

import Oceananigans.Models.HydrostaticFreeSurfaceModels: build_implicit_step_solver,
                                                         compute_implicit_free_surface_right_hand_side!

import Oceananigans.Architectures: architecture, on_architecture
import Oceananigans.Solvers: solve!

struct UnifiedImplicitFreeSurfaceSolver{S, R, T}
    unified_pcg_solver :: S
    right_hand_side :: R
    storage :: T
end

architecture(solver::UnifiedImplicitFreeSurfaceSolver) =
    architecture(solver.preconditioned_conjugate_gradient_solver)

function UnifiedImplicitFreeSurfaceSolver(mrg::MultiRegionGrids, settings, gravitational_acceleration::Number; multiple_devices = false)

    # Initialize vertically integrated lateral face areas
    grid = reconstruct_global_grid(mrg)

    ∫ᶻ_Axᶠᶜᶜ = Field{Face, Center, Nothing}(grid)
    ∫ᶻ_Ayᶜᶠᶜ = Field{Center, Face, Nothing}(grid)

    vertically_integrated_lateral_areas = (xᶠᶜᶜ = ∫ᶻ_Axᶠᶜᶜ, yᶜᶠᶜ = ∫ᶻ_Ayᶜᶠᶜ)

    @apply_regionally compute_vertically_integrated_lateral_areas!(vertically_integrated_lateral_areas)

    Ax = vertically_integrated_lateral_areas.xᶠᶜᶜ
    Ay = vertically_integrated_lateral_areas.yᶜᶠᶜ
    fill_halo_regions!((Ax, Ay); signed=false)

    arch = architecture(mrg)
    right_hand_side = unified_array(arch, zeros(eltype(grid), grid.Nx * grid.Ny))
    storage = deepcopy(right_hand_side)

    # Set maximum iterations to Nx * Ny if not set
    settings = Dict{Symbol, Any}(settings)
    maximum_iterations = get(settings, :maximum_iterations, grid.Nx * grid.Ny)
    settings[:maximum_iterations] = maximum_iterations

    coeffs = compute_matrix_coefficients(vertically_integrated_lateral_areas, grid, gravitational_acceleration)

    reduced_dim = (false, false, true)
    solver = multiple_devices ? UnifiedDiagonalIterativeSolver(coeffs; reduced_dim, grid, mrg, settings...) :
                                HeptadiagonalIterativeSolver(coeffs; reduced_dim,
                                                             template = right_hand_side,
                                                             grid,
                                                             settings...)

    return UnifiedImplicitFreeSurfaceSolver(solver, right_hand_side, storage)
end

build_implicit_step_solver(::Val{:HeptadiagonalIterativeSolver}, grid::MultiRegionGrids, settings, gravitational_acceleration) =
    UnifiedImplicitFreeSurfaceSolver(grid, settings, gravitational_acceleration)
build_implicit_step_solver(::Val{:Default}, grid::MultiRegionGrids, settings, gravitational_acceleration) =
    UnifiedImplicitFreeSurfaceSolver(grid, settings, gravitational_acceleration)
build_implicit_step_solver(::Val{:PreconditionedConjugateGradient}, grid::MultiRegionGrids, settings, gravitational_acceleration) =
    throw(ArgumentError("Cannot use PCG solver with Multi-region grids!! Select :Default or :HeptadiagonalIterativeSolver as solver_method"))
build_implicit_step_solver(::Val{:Default}, grid::ConformalCubedSphereGridOfSomeKind, settings, gravitational_acceleration) =
    PCGImplicitFreeSurfaceSolver(grid, settings, gravitational_acceleration)
build_implicit_step_solver(::Val{:PreconditionedConjugateGradient}, grid::ConformalCubedSphereGridOfSomeKind, settings, gravitational_acceleration) =
    PCGImplicitFreeSurfaceSolver(grid, settings, gravitational_acceleration)
build_implicit_step_solver(::Val{:HeptadiagonalIterativeSolver}, grid::ConformalCubedSphereGridOfSomeKind, settings, gravitational_acceleration) =
    throw(ArgumentError("Cannot use Matrix solvers with ConformalCubedSphereGrid!! Select :Default or :PreconditionedConjugateGradient as solver_method"))

function compute_implicit_free_surface_right_hand_side!(rhs, implicit_solver::UnifiedImplicitFreeSurfaceSolver, g, Δt, ∫ᶻQ, η)
    grid = ∫ᶻQ.u.grid
    M = length(grid.partition)
    @apply_regionally compute_regional_rhs!(rhs, grid, g, Δt, ∫ᶻQ, η, Iterate(1:M), grid.partition)
    return nothing
end

compute_regional_rhs!(rhs, grid, g, Δt, ∫ᶻQ, η, region, partition) =
    launch!(architecture(grid), grid, :xy,
            implicit_linearized_unified_free_surface_right_hand_side!,
            rhs, grid, g, Δt, ∫ᶻQ, η, region, partition)

# linearized right hand side
@kernel function implicit_linearized_unified_free_surface_right_hand_side!(rhs, grid, g, Δt, ∫ᶻQ, η, region, partition)
    i, j = @index(Global, NTuple)
    Az   = Azᶜᶜᶜ(i, j, 1, grid)
    δ_Q  = flux_div_xyᶜᶜᶠ(i, j, 1, grid, ∫ᶻQ.u, ∫ᶻQ.v)
    t    = displaced_xy_index(i, j, grid, region, partition)
    @inbounds rhs[t] = (δ_Q - Az * η[i, j, grid.Nz+1] / Δt) / (g * Δt)
end

function solve!(η, implicit_free_surface_solver::UnifiedImplicitFreeSurfaceSolver, rhs, g, Δt)

    solver = implicit_free_surface_solver.unified_pcg_solver
    storage = implicit_free_surface_solver.storage

    sync_all_devices!(η.grid.devices)

    switch_device!(getdevice(solver.matrix_constructors[1]))
    solve!(storage, solver, rhs, Δt)

    arch = architecture(solver)
    grid = η.grid

    @apply_regionally redistribute_lhs!(η, storage, arch, grid, Iterate(1:length(grid)), grid.partition)

    fill_halo_regions!(η)

    return nothing
end

redistribute_lhs!(η, sol, arch, grid, region, partition) =
    launch!(arch, grid, :xy, _redistribute_lhs!, η, sol, region, grid, partition)

# linearized right hand side
@kernel function _redistribute_lhs!(η, sol, region, grid, partition)
    i, j = @index(Global, NTuple)
    t = displaced_xy_index(i, j, grid, region, partition)
    @inbounds η[i, j, grid.Nz+1] = sol[t]
end
