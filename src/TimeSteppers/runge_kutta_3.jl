using Oceananigans.Architectures: architecture
using Oceananigans: fields

"""
    RungeKutta3TimeStepper{FT, TG} <: AbstractTimeStepper

Hold parameters and tendency fields for a low storage, third-order Runge-Kutta-Wray
time-stepping scheme described by [Le and Moin (1991)](@cite LeMoin1991).

References
==========
Le, H. and Moin, P. (1991). An improvement of fractional step methods for the incompressible
    Navier–Stokes equations. Journal of Computational Physics, 92, 369–379.
"""
struct RungeKutta3TimeStepper{FT, TG, TI} <: AbstractTimeStepper
                 γ¹ :: FT
                 γ² :: FT
                 γ³ :: FT
                 ζ² :: FT
                 ζ³ :: FT
                 Gⁿ :: TG
                 G⁻ :: TG
    implicit_solver :: TI
end

"""
    RungeKutta3TimeStepper(grid, prognostic_fields;
                           implicit_solver = nothing,
                           Gⁿ = map(similar, prognostic_fields),
                           G⁻ = map(similar, prognostic_fields))

Return a 3rd-order Runge-Kutta timestepper (`RungeKutta3TimeStepper`) on `grid`
and with `prognostic_fields`. The tendency fields `Gⁿ` and `G⁻`, typically equal
to the `prognostic_fields` can be modified via the optional `kwargs`.

The scheme is described by [Le and Moin (1991)](@cite LeMoin1991). In a nutshell,
the 3rd-order Runge-Kutta timestepper steps forward the state `Uⁿ` by `Δt` via
3 substeps. A pressure correction step is applied after at each substep.

The state `U` after each substep `m` is

```julia
Uᵐ⁺¹ = Uᵐ + Δt * (γᵐ * Gᵐ + ζᵐ * Gᵐ⁻¹)
```

where `Uᵐ` is the state at the ``m``-th substep, `Gᵐ` is the tendency
at the ``m``-th substep, `Gᵐ⁻¹` is the tendency at the previous substep,
and constants `γ¹ = 8/15`, `γ² = 5/12`, `γ³ = 3/4`, `ζ¹ = 0`, `ζ² = -17/60`,
and `ζ³ = -5/12`.

The state at the first substep is taken to be the one that corresponds to
the ``n``-th timestep, `U¹ = Uⁿ`, and the state after the third substep is
then the state at the `Uⁿ⁺¹ = U⁴`.

References
==========
Le, H. and Moin, P. (1991). An improvement of fractional step methods for the incompressible
    Navier–Stokes equations. Journal of Computational Physics, 92, 369–379.
"""
function RungeKutta3TimeStepper(grid, prognostic_fields;
                                implicit_solver::TI = nothing,
                                Gⁿ::TG = map(similar, prognostic_fields),
                                G⁻     = map(similar, prognostic_fields)) where {TI, TG}

    !isnothing(implicit_solver) &&
        @warn("Implicit-explicit time-stepping with RungeKutta3TimeStepper is not tested. " *
              "\n implicit_solver: $(typeof(implicit_solver))")

    γ¹ = 8 // 15
    γ² = 5 // 12
    γ³ = 3 // 4

    ζ² = -17 // 60
    ζ³ = -5 // 12

    FT = eltype(grid)

    return RungeKutta3TimeStepper{FT, TG, TI}(γ¹, γ², γ³, ζ², ζ³, Gⁿ, G⁻, implicit_solver)
end

#####
##### Time steppping
#####

"""
    time_step!(model::AbstractModel{<:RungeKutta3TimeStepper}, Δt)

Step forward `model` one time step `Δt` with a 3rd-order Runge-Kutta method.
The 3rd-order Runge-Kutta method takes three intermediate substep stages to
achieve a single timestep. A pressure correction step is applied at each intermediate
stage.
"""
function time_step!(model::AbstractModel{<:RungeKutta3TimeStepper}, Δt; callbacks=[])
    Δt == 0 && @warn "Δt == 0 may cause model blowup!"

    # Be paranoid and update state at iteration 0, in case run! is not used:
    model.clock.iteration == 0 && update_state!(model, callbacks; compute_tendencies = true)

    γ¹ = model.timestepper.γ¹
    γ² = model.timestepper.γ²
    γ³ = model.timestepper.γ³

    ζ¹ = nothing
    ζ² = model.timestepper.ζ²
    ζ³ = model.timestepper.ζ³

    first_stage_Δt  = stage_Δt(Δt, γ¹, ζ¹)      # =  γ¹ * Δt
    second_stage_Δt = stage_Δt(Δt, γ², ζ²)      # = (γ² + ζ²) * Δt
    third_stage_Δt  = stage_Δt(Δt, γ³, ζ³)      # = (γ³ + ζ³) * Δt

    # Compute the next time step a priori to reduce floating point error accumulation
    tⁿ⁺¹ = next_time(model.clock, Δt)

    #
    # First stage
    #

    rk3_substep!(model, Δt, γ¹, nothing)

    tick!(model.clock, first_stage_Δt; stage=true)

    compute_pressure_correction!(model, first_stage_Δt)
    make_pressure_correction!(model, first_stage_Δt)

    cache_previous_tendencies!(model)
    update_state!(model, callbacks; compute_tendencies = true)
    step_lagrangian_particles!(model, first_stage_Δt)

    #
    # Second stage
    #

    rk3_substep!(model, Δt, γ², ζ²)

    tick!(model.clock, second_stage_Δt; stage=true)

    compute_pressure_correction!(model, second_stage_Δt)
    make_pressure_correction!(model, second_stage_Δt)

    cache_previous_tendencies!(model)
    update_state!(model, callbacks; compute_tendencies = true)
    step_lagrangian_particles!(model, second_stage_Δt)

    #
    # Third stage
    #

    rk3_substep!(model, Δt, γ³, ζ³)

    # This adjustment of the final time-step reduces the accumulation of
    # round-off error when Δt is added to model.clock.time. Note that we still use
    # third_stage_Δt for the substep, pressure correction, and Lagrangian particles step.
    corrected_third_stage_Δt = tⁿ⁺¹ - model.clock.time
    tick!(model.clock, third_stage_Δt)
    # now model.clock.last_Δt = clock.last_stage_Δt = third_stage_Δt
    # we correct those below
    model.clock.last_stage_Δt = corrected_third_stage_Δt
    model.clock.last_Δt = Δt

    compute_pressure_correction!(model, third_stage_Δt)
    make_pressure_correction!(model, third_stage_Δt)

    update_state!(model, callbacks; compute_tendencies = true)
    step_lagrangian_particles!(model, third_stage_Δt)

    return nothing
end

#####
##### Time stepping in each substep
#####

stage_Δt(Δt, γⁿ, ζⁿ) = Δt * (γⁿ + ζⁿ)
stage_Δt(Δt, γⁿ, ::Nothing) = Δt * γⁿ

function rk3_substep!(model, Δt, γⁿ, ζⁿ)

    grid = model.grid
    arch = architecture(grid)
    model_fields = prognostic_fields(model)

    for (i, field) in enumerate(model_fields)
        kernel_args = (field, Δt, γⁿ, ζⁿ, model.timestepper.Gⁿ[i], model.timestepper.G⁻[i])
        launch!(arch, grid, :xyz, rk3_substep_field!, kernel_args...; exclude_periphery=true)

        # TODO: function tracer_index(model, field_index) = field_index - 3, etc...
        tracer_index = Val(i - 3) # assumption

        implicit_step!(field,
                       model.timestepper.implicit_solver,
                       model.closure,
                       model.diffusivity_fields,
                       tracer_index,
                       model.clock,
                       stage_Δt(Δt, γⁿ, ζⁿ))
    end

    return nothing
end

"""
Time step velocity fields via the 3rd-order Runge-Kutta method

    Uᵐ⁺¹ = Uᵐ + Δt * (γᵐ * Gᵐ + ζᵐ * Gᵐ⁻¹)

where `m` denotes the substage.
"""
@kernel function rk3_substep_field!(U, Δt, γⁿ::FT, ζⁿ, Gⁿ, G⁻) where FT
    i, j, k = @index(Global, NTuple)

    @inbounds begin
        U[i, j, k] += convert(FT, Δt) * (γⁿ * Gⁿ[i, j, k] + ζⁿ * G⁻[i, j, k])
    end
end

@kernel function rk3_substep_field!(U, Δt, γ¹::FT, ::Nothing, G¹, G⁰) where FT
    i, j, k = @index(Global, NTuple)

    @inbounds begin
        U[i, j, k] += convert(FT, Δt) * γ¹ * G¹[i, j, k]
    end
end
