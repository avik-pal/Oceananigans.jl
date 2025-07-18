include("dependencies_for_runtests.jl")

using Oceananigans.Fields: TracerFields

using Oceananigans.BuoyancyFormulations:
    required_tracers, ρ′, ∂x_b, ∂y_b,
    thermal_expansionᶜᶜᶜ, thermal_expansionᶠᶜᶜ, thermal_expansionᶜᶠᶜ, thermal_expansionᶜᶜᶠ,
    haline_contractionᶜᶜᶜ, haline_contractionᶠᶜᶜ, haline_contractionᶜᶠᶜ, haline_contractionᶜᶜᶠ

function instantiate_linear_equation_of_state(FT, α, β)
    eos = LinearEquationOfState(FT, thermal_expansion=α, haline_contraction=β)
    return eos.thermal_expansion == FT(α) && eos.haline_contraction == FT(β)
end

function instantiate_seawater_buoyancy(FT, EquationOfState; kwargs...)
    buoyancy = SeawaterBuoyancy(FT, equation_of_state=EquationOfState(FT); kwargs...)
    return typeof(buoyancy.gravitational_acceleration) == FT
end

function density_perturbation_works(arch, FT, eos)
    grid = RectilinearGrid(arch, FT, size=(3, 3, 3), extent=(1, 1, 1))
    C = TracerFields((:T, :S), grid)
    density_anomaly = @allowscalar ρ′(2, 2, 2, grid, eos, C.T, C.S)
    return true
end

function ∂x_b_works(arch, FT, buoyancy)
    grid = RectilinearGrid(arch, FT, size=(3, 3, 3), extent=(1, 1, 1))
    C = TracerFields(required_tracers(buoyancy), grid)
    dbdx = @allowscalar ∂x_b(2, 2, 2, grid, buoyancy, C)
    return true
end

function ∂y_b_works(arch, FT, buoyancy)
    grid = RectilinearGrid(arch, FT, size=(3, 3, 3), extent=(1, 1, 1))
    C = TracerFields(required_tracers(buoyancy), grid)
    dbdy = @allowscalar ∂y_b(2, 2, 2, grid, buoyancy, C)
    return true
end

function ∂z_b_works(arch, FT, buoyancy)
    grid = RectilinearGrid(arch, FT, size=(3, 3, 3), extent=(1, 1, 1))
    C = TracerFields(required_tracers(buoyancy), grid)
    dbdz = @allowscalar ∂z_b(2, 2, 2, grid, buoyancy, C)
    return true
end

function thermal_expansion_works(arch, FT, eos)
    grid = RectilinearGrid(arch, FT, size=(3, 3, 3), extent=(1, 1, 1))
    C = TracerFields((:T, :S), grid)
    α = @allowscalar thermal_expansionᶜᶜᶜ(2, 2, 2, grid, eos, C.T, C.S)
    α = @allowscalar thermal_expansionᶠᶜᶜ(2, 2, 2, grid, eos, C.T, C.S)
    α = @allowscalar thermal_expansionᶜᶠᶜ(2, 2, 2, grid, eos, C.T, C.S)
    α = @allowscalar thermal_expansionᶜᶜᶠ(2, 2, 2, grid, eos, C.T, C.S)
    return true
end

function haline_contraction_works(arch, FT, eos)
    grid = RectilinearGrid(arch, FT, size=(3, 3, 3), extent=(1, 1, 1))
    C = TracerFields((:T, :S), grid)
    β = @allowscalar haline_contractionᶜᶜᶜ(2, 2, 2, grid, eos, C.T, C.S)
    β = @allowscalar haline_contractionᶠᶜᶜ(2, 2, 2, grid, eos, C.T, C.S)
    β = @allowscalar haline_contractionᶜᶠᶜ(2, 2, 2, grid, eos, C.T, C.S)
    β = @allowscalar haline_contractionᶜᶜᶠ(2, 2, 2, grid, eos, C.T, C.S)
    return true
end

EquationsOfState = (LinearEquationOfState, SeawaterPolynomials.RoquetEquationOfState, SeawaterPolynomials.TEOS10EquationOfState)
buoyancy_kwargs = (Dict(), Dict(:constant_salinity=>35.0), Dict(:constant_temperature=>20.0))

@testset "BuoyancyFormulations" begin
    @info "Testing buoyancy..."

    @testset "Equations of State" begin
        @info "  Testing equations of state..."
        for FT in float_types
            @test instantiate_linear_equation_of_state(FT, 0.1, 0.3)

            for EOS in EquationsOfState
                for kwargs in buoyancy_kwargs
                    @test instantiate_seawater_buoyancy(FT, EOS; kwargs...)
                end
            end

            for arch in archs
                @test density_perturbation_works(arch, FT, SeawaterPolynomials.RoquetEquationOfState())
            end

            buoyancies = (nothing, BuoyancyForce(BuoyancyTracer()), BuoyancyForce(SeawaterBuoyancy(FT)),
                          (BuoyancyForce(SeawaterBuoyancy(FT, equation_of_state=eos(FT))) for eos in EquationsOfState)...)

            for arch in archs
                for buoyancy in buoyancies
                    @test ∂x_b_works(arch, FT, buoyancy)
                    @test ∂y_b_works(arch, FT, buoyancy)
                    @test ∂z_b_works(arch, FT, buoyancy)
                end
            end

            for arch in archs
                for EOS in EquationsOfState
                    @test thermal_expansion_works(arch, FT, EOS())
                    @test haline_contraction_works(arch, FT, EOS())
                end
            end
        end
    end
end
