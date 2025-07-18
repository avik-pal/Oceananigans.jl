include("dependencies_for_runtests.jl")

using TimesDates: TimeDate
using Oceananigans.Grids: topological_tuple_length, total_size
using Oceananigans.TimeSteppers: Clock
using Oceananigans.TurbulenceClosures: CATKEVerticalDiffusivity
using Oceananigans.TurbulenceClosures.Smagorinskys: LagrangianAveraging, DynamicSmagorinsky

function time_stepping_works_with_flat_dimensions(arch, topology)
    size = Tuple(1 for i = 1:topological_tuple_length(topology...))
    extent = Tuple(1 for i = 1:topological_tuple_length(topology...))
    grid = RectilinearGrid(arch; size, extent, topology)
    model = NonhydrostaticModel(; grid)
    time_step!(model, 1)
    return true # Test that no errors/crashes happen when time stepping.
end

function euler_time_stepping_doesnt_propagate_NaNs(arch)
    model = HydrostaticFreeSurfaceModel(grid=RectilinearGrid(arch, size=(1, 1, 1), extent=(1, 2, 3)),
                                        buoyancy = BuoyancyTracer(),
                                        tracers = :b)

    @allowscalar model.timestepper.G⁻.u[1, 1, 1] = NaN
    time_step!(model, 1, euler=true)
    u111 = @allowscalar model.velocities.u[1, 1, 1]

    return !isnan(u111)
end

function time_stepping_works_with_coriolis(arch, FT, Coriolis)
    grid = RectilinearGrid(arch, FT, size=(1, 1, 1), extent=(1, 2, 3))
    coriolis = Coriolis(FT, latitude=45)
    model = NonhydrostaticModel(; grid, coriolis)
    time_step!(model, 1)
    return true # Test that no errors/crashes happen when time stepping.
end

function time_stepping_works_with_closure(arch, FT, Closure; Model=NonhydrostaticModel, buoyancy=BuoyancyForce(SeawaterBuoyancy(FT)))
    # Add TKE tracer "e" to tracers when using CATKEVerticalDiffusivity
    tracers = [:T, :S]
    Closure === CATKEVerticalDiffusivity && push!(tracers, :e)

    # Use halos of size 3 to be conservative
    grid = RectilinearGrid(arch, FT; size=(3, 3, 3), halo=(3, 3, 3), extent=(1, 2, 3))
    closure = Closure === IsopycnalSkewSymmetricDiffusivity ? Closure(FT, κ_skew=1, κ_symmetric=1) : Closure(FT)
    model = Model(; grid, closure, tracers, buoyancy)
    time_step!(model, 1)

    return true  # Test that no errors/crashes happen when time stepping.
end

function time_stepping_works_with_advection_scheme(arch, advection)
    # Use halo=(3, 3, 3) to accomodate WENO-5 advection scheme
    grid = RectilinearGrid(arch, size=(3, 3, 3), halo=(3, 3, 3), extent=(1, 2, 3))
    model = NonhydrostaticModel(; grid, advection)
    time_step!(model, 1)
    return true  # Test that no errors/crashes happen when time stepping.
end

function time_stepping_works_with_stokes_drift(arch, stokes_drift)
    # Use halo=(3, 3, 3) to accomodate WENO-5 advection scheme
    grid = RectilinearGrid(arch, size=(3, 3, 3), halo=(3, 3, 3), extent=(1, 2, 3))
    model = NonhydrostaticModel(; grid, stokes_drift, advection=nothing)
    time_step!(model, 1)
    return true  # Test that no errors/crashes happen when time stepping.
end

function time_stepping_works_with_nothing_closure(arch, FT)
    grid = RectilinearGrid(arch, FT; size=(1, 1, 1), extent=(1, 2, 3))
    model = NonhydrostaticModel(; grid, closure=nothing)
    time_step!(model, 1)
    return true  # Test that no errors/crashes happen when time stepping.
end

function time_stepping_works_with_nonlinear_eos(arch, FT, EOS)
    grid = RectilinearGrid(arch, FT; size=(1, 1, 1), extent=(1, 2, 3))

    eos = EOS()
    b = SeawaterBuoyancy(equation_of_state=eos)
    model = NonhydrostaticModel(; grid, buoyancy=b, tracers=(:T, :S))
    time_step!(model, 1)

    return true  # Test that no errors/crashes happen when time stepping.
end

@inline add_ones(args...) = 1

function run_first_AB2_time_step_tests(arch, FT)

    # Weird grid size to catch https://github.com/CliMA/Oceananigans.jl/issues/780
    grid = RectilinearGrid(arch, FT, size=(13, 17, 19), extent=(1, 2, 3))

    model = NonhydrostaticModel(; grid,
                                timestepper = :QuasiAdamsBashforth2,
                                forcing = (; T=add_ones),
                                buoyancy = SeawaterBuoyancy(),
                                tracers = (:T, :S))

    # Test that GT = 0 after model construction
    # (note: model construction does not computes tendencies)
    @test all(interior(model.timestepper.Gⁿ.u) .≈ 0)
    @test all(interior(model.timestepper.Gⁿ.v) .≈ 0)
    @test all(interior(model.timestepper.Gⁿ.w) .≈ 0)
    @test all(interior(model.timestepper.Gⁿ.T) .≈ 0)
    @test all(interior(model.timestepper.Gⁿ.S) .≈ 0)

    # Test that T = 1 after 1 time step and that AB2 actually reduced to forward Euler.
    Δt = 1
    time_step!(model, Δt, euler=true)
    @test all(interior(model.velocities.u) .≈ 0)
    @test all(interior(model.velocities.v) .≈ 0)
    @test all(interior(model.velocities.w) .≈ 0)
    @test all(interior(model.tracers.T)    .≈ 1)
    @test all(interior(model.tracers.S)    .≈ 0)

    return nothing
end

"""
    This tests to make sure that the velocity field remains incompressible (or divergence-free) as the model is time
    stepped. It just initializes a cube shaped hot bubble perturbation in the center of the 3D domain to induce a
    velocity field.
"""
function incompressible_in_time(grid, Nt, timestepper)
    model = NonhydrostaticModel(grid=grid, timestepper=timestepper,
                                buoyancy=SeawaterBuoyancy(), tracers=(:T, :S))
    grid = model.grid
    u, v, w = model.velocities

    div_U = CenterField(grid)

    # Just add a temperature perturbation so we get some velocity field.
    @allowscalar interior(model.tracers.T)[8:24, 8:24, 8:24] .+= 0.01

    update_state!(model)
    for n in 1:Nt
        time_step!(model, 0.05)
    end

    arch = architecture(grid)
    launch!(arch, grid, :xyz, divergence!, grid, u.data, v.data, w.data, div_U.data)

    min_div = @allowscalar minimum(interior(div_U))
    max_div = @allowscalar maximum(interior(div_U))
    max_abs_div = @allowscalar maximum(abs, interior(div_U))
    sum_div = @allowscalar sum(interior(div_U))
    sum_abs_div = @allowscalar sum(abs, interior(div_U))

    @info "Velocity divergence after $Nt time steps [$(typeof(arch)), $(typeof(grid)), $timestepper]: " *
          "min=$min_div, max=$max_div, max_abs_div=$max_abs_div, sum=$sum_div, abs_sum=$sum_abs_div"

    # We are comparing with 0 so we use absolute tolerances. They are a bit larger than eps(Float64) and eps(Float32)
    # because we are summing over the absolute value of many machine epsilons. A better atol value may be
    # Nx*Ny*Nz*eps(eltype(grid)) but it's much higher than the observed max_abs_div, so out of a general abundance of caution
    # we manually insert a smaller tolerance than we might need for this test.
    return isapprox(max_abs_div, 0, atol=5e-8)
end

"""
    tracer_conserved_in_channel(arch, FT, Nt)

Create a super-coarse eddying channel model with walls in the y and test that
temperature is conserved after `Nt` time steps.
"""
function tracer_conserved_in_channel(arch, FT, Nt)
    Nx, Ny, Nz = 16, 32, 16
    Lx, Ly, Lz = 160e3, 320e3, 1024

    α = (Lz/Nz)/(Lx/Nx) # Grid cell aspect ratio.
    νh, κh = 20.0, 20.0
    νz, κz = α*νh, α*κh

    topology = (Periodic, Bounded, Bounded)
    grid = RectilinearGrid(arch, size=(Nx, Ny, Nz), extent=(Lx, Ly, Lz))
    model = NonhydrostaticModel(grid = grid,
                                closure = (HorizontalScalarDiffusivity(ν=νh, κ=κh),
                                           VerticalScalarDiffusivity(ν=νz, κ=κz)),
                                buoyancy=SeawaterBuoyancy(), tracers=(:T, :S))

    Ty = 1e-4  # Meridional temperature gradient [K/m].
    Tz = 5e-3  # Vertical temperature gradient [K/m].

    # Initial temperature field [°C].
    T₀(x, y, z) = 10 + Ty*y + Tz*z + 0.0001*rand()
    set!(model, T=T₀)

    Tavg0 = @allowscalar mean(interior(model.tracers.T))

    update_state!(model)
    for n in 1:Nt
        time_step!(model, 600)
    end

    Tavg = @allowscalar mean(interior(model.tracers.T))
    @info "Tracer conservation after $Nt time steps [$(typeof(arch)), $FT]: " *
          "⟨T⟩-T₀=$(Tavg-Tavg0) °C"

    return isapprox(Tavg, Tavg0, atol=Nx*Ny*Nz*eps(FT))
end

function time_stepping_with_background_fields(arch)

    grid = RectilinearGrid(arch, size=(1, 1, 1), extent=(1, 1, 1))

    background_u(x, y, z, t) = π
    background_v(x, y, z, t) = sin(x) * cos(y) * exp(t)

    background_w_func(x, y, z, t, p) = p.α * x + p.β * exp(z / p.λ)
    background_w = BackgroundField(background_w_func, parameters=(α=1.2, β=0.2, λ=43))

    background_T(x, y, z, t) = background_u(x, y, z, t)

    background_S_func(x, y, z, t, α) = α * y
    background_S = BackgroundField(background_S_func, parameters=1.2)

    background_R = BackgroundField(1)

    background_fields = (u = background_u,
                         v = background_v,
                         w = background_w,
                         T = background_T,
                         S = background_S,
                         R = background_R)

    model = NonhydrostaticModel(; grid, background_fields,
                                buoyancy = SeawaterBuoyancy(),
                                tracers=(:T, :S, :R))

    time_step!(model, 1)

    return location(model.background_fields.velocities.u) === (Face, Center, Center) &&
           location(model.background_fields.velocities.v) === (Center, Face, Center) &&
           location(model.background_fields.velocities.w) === (Center, Center, Face) &&
           location(model.background_fields.tracers.T) === (Center, Center, Center) &&
           location(model.background_fields.tracers.S) === (Center, Center, Center) &&
           location(model.background_fields.tracers.R) === (Nothing, Nothing, Nothing)
end

Planes = (FPlane, ConstantCartesianCoriolis, BetaPlane, NonTraditionalBetaPlane)

BuoyancyModifiedAnisotropicMinimumDissipation(FT=Float64) = AnisotropicMinimumDissipation(FT, Cb=1.0)

ConstantSmagorinsky(FT=Float64) = Smagorinsky(FT, coefficient=0.16)
DirectionallyAveragedDynamicSmagorinsky(FT=Float64) =
    Smagorinsky(FT, coefficient=DynamicCoefficient(averaging=(1, 2)))
LagrangianAveragedDynamicSmagorinsky(FT=Float64) =
    Smagorinsky(FT, coefficient=DynamicCoefficient(averaging=LagrangianAveraging()))

Closures = (ScalarDiffusivity,
            ScalarBiharmonicDiffusivity,
            TwoDimensionalLeith,
            IsopycnalSkewSymmetricDiffusivity,
            ConstantSmagorinsky,
            SmagorinskyLilly,
            DirectionallyAveragedDynamicSmagorinsky,
            LagrangianAveragedDynamicSmagorinsky,
            AnisotropicMinimumDissipation,
            BuoyancyModifiedAnisotropicMinimumDissipation,
            CATKEVerticalDiffusivity)

advection_schemes = (nothing,
                     UpwindBiased(order=1),
                     Centered(order=2),
                     UpwindBiased(order=3),
                     Centered(order=4),
                     UpwindBiased(order=5),
                     WENO())

@inline ∂t_uˢ_uniform(z, t, h) = exp(z / h) * cos(t)
@inline ∂t_vˢ_uniform(z, t, h) = exp(z / h) * cos(t)
@inline ∂z_uˢ_uniform(z, t, h) = exp(z / h) / h * sin(t)
@inline ∂z_vˢ_uniform(z, t, h) = exp(z / h) / h * sin(t)

parameterized_uniform_stokes_drift = UniformStokesDrift(∂t_uˢ = ∂t_uˢ_uniform,
                                                        ∂t_vˢ = ∂t_vˢ_uniform,
                                                        ∂z_uˢ = ∂z_uˢ_uniform,
                                                        ∂z_vˢ = ∂z_vˢ_uniform,
                                                        parameters = 20)

@inline ∂t_uˢ(x, y, z, t, h) = exp(z / h) * cos(t)
@inline ∂t_vˢ(x, y, z, t, h) = exp(z / h) * cos(t)
@inline ∂t_wˢ(x, y, z, t, h) = 0
@inline ∂x_vˢ(x, y, z, t, h) = 0
@inline ∂x_wˢ(x, y, z, t, h) = 0
@inline ∂y_uˢ(x, y, z, t, h) = 0
@inline ∂y_wˢ(x, y, z, t, h) = 0
@inline ∂z_uˢ(x, y, z, t, h) = exp(z / h) / h * sin(t)
@inline ∂z_vˢ(x, y, z, t, h) = exp(z / h) / h * sin(t)

parameterized_stokes_drift = StokesDrift(∂t_uˢ = ∂t_uˢ,
                                         ∂t_vˢ = ∂t_vˢ,
                                         ∂t_wˢ = ∂t_wˢ,
                                         ∂x_vˢ = ∂x_vˢ,
                                         ∂x_wˢ = ∂x_wˢ,
                                         ∂y_uˢ = ∂y_uˢ,
                                         ∂y_wˢ = ∂y_wˢ,
                                         ∂z_uˢ = ∂z_uˢ,
                                         ∂z_vˢ = ∂z_vˢ,
                                         parameters = 20)

stokes_drifts = (UniformStokesDrift(),
                 StokesDrift(),
                 parameterized_uniform_stokes_drift,
                 parameterized_stokes_drift)

timesteppers = (:QuasiAdamsBashforth2, :RungeKutta3)

@testset "Time stepping" begin
    @info "Testing time stepping..."

    for arch in archs, FT in float_types
        @testset "Time stepping with DateTimes [$(typeof(arch)), $FT]" begin
            @info "  Testing time stepping with datetime clocks [$(typeof(arch)), $FT]"

            grid = RectilinearGrid(arch, size=(1, 1, 1), extent=(1, 1, 1))
            clock = Clock(time=DateTime(2020))
            model = NonhydrostaticModel(; grid, clock, timestepper=:QuasiAdamsBashforth2)

            time_step!(model, 7.883)
            @test model.clock.time == DateTime("2020-01-01T00:00:07.883")

            model = NonhydrostaticModel(grid = RectilinearGrid(arch, size=(1, 1, 1), extent=(1, 1, 1)),
                                        timestepper = :QuasiAdamsBashforth2,
                                        clock = Clock(time=TimeDate(2020)))

            time_step!(model, 123e-9)  # 123 nanoseconds
            @test model.clock.time == TimeDate("2020-01-01T00:00:00.000000123")
        end
    end

    @testset "Flat dimensions" begin
        for arch in archs
            for topology in ((Flat, Periodic, Periodic),
                             (Periodic, Flat, Periodic),
                             (Periodic, Periodic, Flat),
                             (Flat, Flat, Bounded))

                TX, TY, TZ = topology
                @info "  Testing that time stepping works with flat dimensions [$(typeof(arch)), $TX, $TY, $TZ]..."
                @test time_stepping_works_with_flat_dimensions(arch, topology)
            end
        end
    end

    @testset "Coriolis" begin
        for arch in archs, FT in [Float64], Coriolis in Planes
            @info "  Testing that time stepping works with Coriolis [$(typeof(arch)), $FT, $Coriolis]..."
            @test time_stepping_works_with_coriolis(arch, FT, Coriolis)
        end
    end

    @testset "Advection schemes" begin
        for arch in archs, advection_scheme in advection_schemes
            @info "  Testing time stepping with advection schemes [$(typeof(arch)), $(typeof(advection_scheme))]"
            @test time_stepping_works_with_advection_scheme(arch, advection_scheme)
        end
    end

    @testset "Stokes drift" begin
        for arch in archs, stokes_drift in stokes_drifts
            @info "  Testing time stepping with stokes drift schemes [$(typeof(arch)), $(typeof(stokes_drift))]"
            @test time_stepping_works_with_stokes_drift(arch, stokes_drift)
        end
    end


    @testset "BackgroundFields" begin
        for arch in archs
            @info "  Testing that time stepping works with background fields [$(typeof(arch))]..."
            @test time_stepping_with_background_fields(arch)
        end
    end

    @testset "Euler time stepping propagate NaNs in previous tendency G⁻" begin
        for arch in archs
            @info "  Testing that Euler time stepping doesn't propagate NaNs found in previous tendency G⁻ [$(typeof(arch))]..."
            @test euler_time_stepping_doesnt_propagate_NaNs(arch)
        end
    end

    @testset "Turbulence closures" begin
        for arch in archs, FT in [Float64]

            @info "  Testing that time stepping works [$(typeof(arch)), $FT, nothing]..."
            @test time_stepping_works_with_nothing_closure(arch, FT)

            for Closure in Closures
                @info "  Testing that time stepping works [$(typeof(arch)), $FT, $Closure]..."
                if Closure === CATKEVerticalDiffusivity || Closure === IsopycnalSkewSymmetricDiffusivity
                    # CATKE isn't supported with NonhydrostaticModel yet
                    @test time_stepping_works_with_closure(arch, FT, Closure; Model=HydrostaticFreeSurfaceModel)
                elseif Closure() isa DynamicSmagorinsky
                    @test_skip time_stepping_works_with_closure(arch, FT, Closure)
                else
                    @test time_stepping_works_with_closure(arch, FT, Closure)
                end
            end

            # AnisotropicMinimumDissipation can depend on buoyancy...
            @test time_stepping_works_with_closure(arch, FT, AnisotropicMinimumDissipation; buoyancy=nothing)
        end
    end

    @testset "UniformStokesDrift" begin
        for arch in archs
            grid = RectilinearGrid(arch, size=(1, 1, 1), extent=(1, 1, 1))
            # Cover three cases:
            stokes_drift = UniformStokesDrift(grid, ∂z_vˢ=nothing, ∂t_uˢ= (z, t) -> exp(z/20))
            model = NonhydrostaticModel(; grid, stokes_drift)
            time_step!(model, 1)
            @test true
        end
    end

    @testset "Idealized nonlinear equation of state" begin
        for arch in archs, FT in [Float64]
            for eos_type in (SeawaterPolynomials.RoquetEquationOfState, SeawaterPolynomials.TEOS10EquationOfState)
                @info "  Testing that time stepping works with " *
                        "RoquetIdealizedNonlinearEquationOfState [$(typeof(arch)), $FT, $eos_type]"
                @test time_stepping_works_with_nonlinear_eos(arch, FT, eos_type)
            end
        end
    end

    @testset "2nd-order Adams-Bashforth" begin
        @info "  Testing 2nd-order Adams-Bashforth..."
        for arch in archs, FT in float_types
            run_first_AB2_time_step_tests(arch, FT)
        end
    end

    @testset "Incompressibility" begin
        for FT in float_types, arch in archs
            Nx, Ny, Nz = 32, 32, 32

            regular_grid = RectilinearGrid(arch, FT, size=(Nx, Ny, Nz), x=(0, 1), y=(0, 1), z=(-1, 1))

            S = 1.3 # Stretching factor
            hyperbolically_spaced_nodes(k) = tanh(S * (2 * (k - 1) / Nz - 1)) / tanh(S)
            hyperbolic_vs_grid = RectilinearGrid(arch, FT,
                                             size = (Nx, Ny, Nz),
                                                x = (0, 1),
                                                y = (0, 1),
                                                z = hyperbolically_spaced_nodes)

            regular_vs_grid = RectilinearGrid(arch, FT,
                                             size = (Nx, Ny, Nz),
                                                x = (0, 1),
                                                y = (0, 1),
                                                z = collect(range(0, stop=1, length=Nz+1)))

            for grid in (regular_grid, hyperbolic_vs_grid, regular_vs_grid)
                @info "  Testing incompressibility [$FT, $(typeof(grid).name.wrapper)]..."

                for Nt in [1, 10, 100], timestepper in timesteppers
                    @test incompressible_in_time(grid, Nt, timestepper)
                end
            end
        end
    end

    @testset "Tracer conservation in channel" begin
        @info "  Testing tracer conservation in channel..."
        for arch in archs, FT in float_types
            @test tracer_conserved_in_channel(arch, FT, 10)
        end
    end
end
