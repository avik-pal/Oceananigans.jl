using KernelAbstractions: @index, @kernel, Event
using KernelAbstractions.Extras.LoopInfo: @unroll
using Oceananigans.Grids: topology
using Oceananigans.Utils
using Oceananigans.AbstractOperations: Δz  
using Oceananigans.BoundaryConditions
using Oceananigans.Operators

# Evolution Kernels
#=
∂t(η) = -∇⋅U
∂t(U) = - gH∇η + f
=#

# the free surface field η and its average η̄ are located on `Face`s at the surface (grid.Nz +1). All other intermediate variables
# (U, V, Ū, V̄) are barotropic fields (`ReducedField`) for which a k index is not defined

@inline ∂xᶠᶜᶠ_bound(i, j, k, grid, T, c) = δxᶠᵃᵃ_bound(i, j, k, grid, T, c) / Δxᶠᶜᶠ(i, j, k, grid)
@inline ∂yᶜᶠᶠ_bound(i, j, k, grid, T, c) = δyᵃᶠᵃ_bound(i, j, k, grid, T, c) / Δyᶜᶠᶠ(i, j, k, grid)

@inline δxᶠᵃᵃ_bound(i, j, k, grid, ::Type{Periodic}, f::Function, args...) = ifelse(i == 1, f(1, j, k, grid, args...) - f(grid.Nx, j, kgrid, args...), δxᶠᵃᵃ(i, j, k, grid, f, args...))
@inline δyᵃᶠᵃ_bound(i, j, k, grid, ::Type{Periodic}, f::Function, args...) = ifelse(j == 1, f(i, 1, k, grid, args...) - f(i, grid.Ny, kgrid, args...), δyᵃᶠᵃ(i, j, k, grid, f, args...))
@inline δxᶠᵃᵃ_bound(i, j, k, grid, ::Type{Bounded},  f::Function, args...) = ifelse(i == 1, 0.0, δxᶠᵃᵃ(i, j, k, grid, f, args...))
@inline δyᵃᶠᵃ_bound(i, j, k, grid, ::Type{Bounded},  f::Function, args...) = ifelse(j == 1, 0.0, δyᵃᶠᵃ(i, j, k, grid, f, args...))

@inline δxᶜᵃᵃ_bound(i, j, k, grid, ::Type{Periodic}, f::Function, args...) = ifelse(i == grid.Nx, f(1, j, k, grid, args...) - f(grid.Nx, j, k, grid, args...), δxᶜᵃᵃ(i, j, k, grid, f, args...))
@inline δyᵃᶜᵃ_bound(i, j, k, grid, ::Type{Periodic}, f::Function, args...) = ifelse(j == grid.Ny, f(i, 1, k, grid, args...) - f(i, grid.Ny, k, grid, args...), δyᵃᶜᵃ(i, j, k, grid, f, args...))
@inline δxᶜᵃᵃ_bound(i, j, k, grid, ::Type{Bounded},  f::Function, args...) = ifelse(i == grid.Nx, 0.0, δxᶜᵃᵃ(i, j, k, grid, f, args...))
@inline δyᵃᶜᵃ_bound(i, j, k, grid, ::Type{Bounded},  f::Function, args...) = ifelse(j == grid.Ny, 0.0, δyᵃᶜᵃ(i, j, k, grid, f, args...))

@inline δxᶠᵃᵃ_bound(i, j, k, grid, ::Type{Periodic}, c) = ifelse(i == 1, c[1, j, k] - c[grid.Nx, j, k], δxᶠᵃᵃ(i, j, k, grid, c))
@inline δyᵃᶠᵃ_bound(i, j, k, grid, ::Type{Periodic}, c) = ifelse(j == 1, c[i, 1, k] - c[i, grid.Ny, k], δyᵃᶠᵃ(i, j, k, grid, c))
@inline δxᶠᵃᵃ_bound(i, j, k, grid, ::Type{Bounded},  c) = ifelse(i == 1, 0.0, δxᶠᵃᵃ(i, j, k, grid, c))
@inline δyᵃᶠᵃ_bound(i, j, k, grid, ::Type{Bounded},  c) = ifelse(j == 1, 0.0, δyᵃᶠᵃ(i, j, k, grid, c))

@inline δxᶜᵃᵃ_bound(i, j, k, grid, ::Type{Periodic}, u) = ifelse(i == grid.Nx, u[1, j, k] - u[grid.Nx, j, k], δxᶜᵃᵃ(i, j, k, grid, u))
@inline δyᵃᶜᵃ_bound(i, j, k, grid, ::Type{Periodic}, v) = ifelse(j == grid.Ny, v[i, 1, k] - v[i, grid.Ny, k], δyᵃᶜᵃ(i, j, k, grid, v))
@inline δxᶜᵃᵃ_bound(i, j, k, grid, ::Type{Bounded},  u) = ifelse(i == grid.Nx, 0.0, δxᶜᵃᵃ(i, j, k, grid, u))
@inline δyᵃᶜᵃ_bound(i, j, k, grid, ::Type{Bounded},  v) = ifelse(j == grid.Ny, 0.0, δyᵃᶜᵃ(i, j, k, grid, v))

@inline div_xyᶜᶜᶠ_bound(i, j, k, grid, TX, TY, u, v) = 
    1 / Azᶜᶜᶠ(i, j, k, grid) * (δxᶜᵃᵃ_bound(i, j, k, grid, TX, Δy_qᶠᶜᶠ, u) +
                                δyᵃᶜᵃ_bound(i, j, k, grid, TY, Δx_qᶜᶠᶠ, v))

using Oceananigans.ImmersedBoundaries: conditional_∂x_f, conditional_∂x_c, conditional_∂y_f, conditional_∂y_c, IBG

@inline ∂xᶠᶜᶠ_bound(i, j, k, ibg::IBG, args...) = conditional_∂x_f(Center(), Face(), i, j, k, ibg, ∂xᶠᶜᶠ_bound, args...)
@inline ∂yᶜᶠᶠ_bound(i, j, k, ibg::IBG, args...) = conditional_∂y_f(Center(), Face(), i, j, k, ibg, ∂yᶜᶠᶠ_bound, args...)

@inline div_xyᶜᶜᶠ_bound(i, j, k, ibg::IBG, TX, TY, u, v) = 
    1 / Azᶜᶜᶠ(i, j, k, grid) * (conditional_∂x_c(Center(), Center(), i, j, k, ibg, δxᶜᵃᵃ_bound, TX, Δy_qᶠᶜᶠ, u) +
                                conditional_∂y_c(Center(), Center(), i, j, k, ibg, δyᵃᶜᵃ_bound, TY, Δx_qᶜᶠᶠ, v))

@kernel function split_explicit_free_surface_substep_kernel_1!(grid, Δτ, η, U, V, Gᵁ, Gⱽ, g, Hᶠᶜ, Hᶜᶠ)
    i, j = @index(Global, NTuple)
    k_top = grid.Nz+1

    TX, TY, _ = topology(grid)

    # ∂τ(U) = - ∇η + G
    @inbounds U[i, j, 1] +=  Δτ * (-g * Hᶠᶜ[i, j] * ∂xᶠᶜᶠ_bound(i, j, k_top, grid, TX, η) + Gᵁ[i, j, 1])
    @inbounds V[i, j, 1] +=  Δτ * (-g * Hᶜᶠ[i, j] * ∂yᶜᶠᶠ_bound(i, j, k_top, grid, TY, η) + Gⱽ[i, j, 1])
end

@kernel function split_explicit_free_surface_substep_kernel_2!(grid, Δτ, η, U, V, η̅, U̅, V̅, velocity_weight, free_surface_weight)
    i, j = @index(Global, NTuple)
    k_top = grid.Nz+1
    
    TX, TY, _ = topology(grid)

    # ∂τ(η) = - ∇⋅U
    @inbounds η[i, j, k_top] -=  Δτ * div_xyᶜᶜᶠ_bound(i, j, 1, grid, TX, TY, U, V)
    # time-averaging
    @inbounds U̅[i, j, 1]         +=  velocity_weight * U[i, j, 1]
    @inbounds V̅[i, j, 1]         +=  velocity_weight * V[i, j, 1]
    @inbounds η̅[i, j, k_top] +=  free_surface_weight * η[i, j, k_top]
end

function split_explicit_free_surface_substep!(η, state, auxiliary, settings, arch, grid, g, Δτ, substep_index)
    # unpack state quantities, parameters and forcing terms 
    U, V, η̅, U̅, V̅    = state.U, state.V, state.η̅, state.U̅, state.V̅
    Gᵁ, Gⱽ, Hᶠᶜ, Hᶜᶠ = auxiliary.Gᵁ, auxiliary.Gⱽ, auxiliary.Hᶠᶜ, auxiliary.Hᶜᶠ

    vel_weight = settings.velocity_weights[substep_index]
    η_weight   = settings.free_surface_weights[substep_index]

    event = launch!(arch, grid, :xy, split_explicit_free_surface_substep_kernel_1!, 
            grid, Δτ, η, U, V, Gᵁ, Gⱽ, g, Hᶠᶜ, Hᶜᶠ,
            dependencies=Event(device(arch)))

    wait(device(arch), event)

    event = launch!(arch, grid, :xy, split_explicit_free_surface_substep_kernel_2!, 
            grid, Δτ, η, U, V, η̅, U̅, V̅, vel_weight, η_weight,
            dependencies=Event(device(arch)))

    wait(device(arch), event)
end

# Barotropic Model Kernels
# u_Δz = u * Δz

@kernel function barotropic_mode_kernel!(U, V, grid, u, v)	
    i, j = @index(Global, NTuple)	

    # hand unroll first loop 	
    @inbounds U[i, j, 1] = Δzᶠᶜᶜ(i, j, 1, grid) * u[i, j, 1]	
    @inbounds V[i, j, 1] = Δzᶜᶠᶜ(i, j, 1, grid) * v[i, j, 1]	

    @unroll for k in 2:grid.Nz	
        @inbounds U[i, j, 1] += Δzᶠᶜᶜ(i, j, k, grid) * u[i, j, k]	
        @inbounds V[i, j, 1] += Δzᶜᶠᶜ(i, j, k, grid) * v[i, j, k]	
    end	
end

# may need to do Val(Nk) since it may not be known at compile
function barotropic_mode!(U, V, grid, u, v)

    arch  = architecture(grid)
    event = launch!(arch, grid, :xy, barotropic_mode_kernel!, U, V, grid, u, v,
                   dependencies=Event(device(arch)))

    wait(device(arch), event)
    
    fill_halo_regions!((U, V))
end

function set_average_to_zero!(free_surface_state)
    fill!(free_surface_state.η̅, 0.0)
    fill!(free_surface_state.U̅, 0.0)
    fill!(free_surface_state.V̅, 0.0)     
end

@kernel function barotropic_split_explicit_corrector_kernel!(u, v, U̅, V̅, U, V, Hᶠᶜ, Hᶜᶠ)
    i, j, k = @index(Global, NTuple)
    @inbounds begin
        u[i, j, k] = u[i, j, k] + (-U[i, j] + U̅[i, j]) / Hᶠᶜ[i, j]
        v[i, j, k] = v[i, j, k] + (-V[i, j] + V̅[i, j]) / Hᶜᶠ[i, j]
    end
end

# may need to do Val(Nk) since it may not be known at compile. Also figure out where to put H
function barotropic_split_explicit_corrector!(u, v, free_surface, grid)
    sefs       = free_surface.state
    U, V, U̅, V̅ = sefs.U, sefs.V, sefs.U̅, sefs.V̅
    Hᶠᶜ, Hᶜᶠ   = free_surface.auxiliary.Hᶠᶜ, free_surface.auxiliary.Hᶜᶠ
    arch       = architecture(grid)

    # take out "bad" barotropic mode, 
    # !!!! reusing U and V for this storage since last timestep doesn't matter
    barotropic_mode!(U, V, grid, u, v)
    # add in "good" barotropic mode

    event = launch!(arch, grid, :xyz, barotropic_split_explicit_corrector_kernel!,
        u, v, U̅, V̅, U, V, Hᶠᶜ, Hᶜᶠ,
        dependencies = Event(device(arch)))

    wait(device(arch), event)
end

@kernel function _calc_ab2_tendencies!(G⁻, Gⁿ, χ)
    i, j, k = @index(Global, NTuple)
    @inbounds G⁻[i, j, k] = (1.5 + χ) *  Gⁿ[i, j, k] - G⁻[i, j, k] * (0.5 + χ)
end

"""
Explicitly step forward η in substeps.
"""
ab2_step_free_surface!(free_surface::SplitExplicitFreeSurface, model, Δt, χ, prognostic_field_events) =
    split_explicit_free_surface_step!(free_surface, model, Δt, χ, prognostic_field_events)

function split_explicit_free_surface_step!(free_surface::SplitExplicitFreeSurface, model, Δt, χ, prognostic_field_events)

    grid = model.grid
    arch = architecture(grid)

    # we start the time integration of η from the average ηⁿ     
    η         = free_surface.η
    state     = free_surface.state
    auxiliary = free_surface.auxiliary
    settings  = free_surface.settings
    g         = free_surface.gravitational_acceleration

    Gu⁻ = model.timestepper.G⁻.u
    Gv⁻ = model.timestepper.G⁻.v

    Δτ = 2 * Δt / settings.substeps  # we evolve for two times the Δt 

    event_Gu = launch!(arch, grid, :xyz, _calc_ab2_tendencies!, Gu⁻, model.timestepper.Gⁿ.u, χ)
    event_Gv = launch!(arch, grid, :xyz, _calc_ab2_tendencies!, Gv⁻, model.timestepper.Gⁿ.v, χ)

    # Wait for predictor velocity update step to complete and mask it if immersed boundary.
    @apply_regionally prognostic_field_events = wait_velocity_event(arch,  prognostic_field_events)

    masking_events = Tuple(mask_immersed_field!(q) for q in model.velocities)
    wait(device(arch), MultiEvent(tuple(masking_events..., event_Gu, event_Gv)))

    barotropic_mode!(auxiliary.Gᵁ, auxiliary.Gⱽ, grid, Gu⁻, Gv⁻)

    # reset free surface averages
    set_average_to_zero!(state)

    # Solve for the free surface at tⁿ⁺¹
    start_time = time_ns()

    for substep in 1:settings.substeps
        split_explicit_free_surface_substep!(η, state, auxiliary, settings, arch, grid, g, Δτ, substep)
    end
        
    # Reset eta for the next timestep
    # this is the only way in which η̅ is used: as a smoother for the 
    # substepped η field
    set!(η, free_surface.state.η̅)

    @debug "Split explicit step solve took $(prettytime((time_ns() - start_time) * 1e-9))."

    fill_halo_regions!(η)

    return prognostic_field_events
end