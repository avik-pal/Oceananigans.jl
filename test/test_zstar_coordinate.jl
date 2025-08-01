include("dependencies_for_runtests.jl")

using Random
using Oceananigans: initialize!
using Oceananigans.ImmersedBoundaries: PartialCellBottom
using Oceananigans.Grids: MutableVerticalDiscretization
using Oceananigans.Models: ZStar, ZCoordinate

function test_zstar_coordinate(model, Ni, Δt)

    bᵢ = deepcopy(model.tracers.b)
    cᵢ = deepcopy(model.tracers.c)

    ∫bᵢ = Field(Integral(bᵢ))
    ∫cᵢ = Field(Integral(cᵢ))
    compute!(∫bᵢ)
    compute!(∫cᵢ)

    w   = model.velocities.w
    Nz  = model.grid.Nz

    for step in 1:Ni
        time_step!(model, Δt)

        ∫b = Field(Integral(model.tracers.b))
        ∫c = Field(Integral(model.tracers.c))
        compute!(∫b)
        compute!(∫c)

        condition = interior(∫b, 1, 1, 1) ≈ interior(∫bᵢ, 1, 1, 1)
        @test condition
        if !condition
                @info "Stopping early: buoyancy not conserved at step $step"
            break
        end

        condition = interior(∫c, 1, 1, 1) ≈ interior(∫cᵢ, 1, 1, 1)
        @test condition
        if !condition
                @info "Stopping early: c tracer not conserved at step $step"
            break
        end

        condition = maximum(abs, interior(w, :, :, Nz+1)) < eps(eltype(w))
        @test condition
        if !condition
                @info "Stopping early: nonzero vertical velocity at top at step $step"
            break
        end

        # Constancy preservation test
        @test maximum(model.tracers.constant) ≈ 1
        @test minimum(model.tracers.constant) ≈ 1
    end

    return nothing
end

function info_message(grid, free_surface)
    msg1 = "$(typeof(architecture(grid))) "
    msg2 = string(getnamewrapper(grid))
    msg3 = grid isa ImmersedBoundaryGrid ? " on a " * string(getnamewrapper(grid.underlying_grid)) : ""
    msg4 = grid.z.Δᵃᵃᶠ isa Number ? " with uniform spacing" : " with stretched spacing"
    msg5 = grid isa ImmersedBoundaryGrid ? " and $(string(getnamewrapper(grid.immersed_boundary))) immersed boundary" : ""
    msg6 = " using a " * string(getnamewrapper(free_surface))
    return msg1 * msg2 * msg3 * msg4 * msg5 * msg6
end

const C = Center
const F = Face

@testset "MutableVerticalDiscretization tests" begin
    @info "testing the MutableVerticalDiscretization in ZCoordinate mode"

    z = MutableVerticalDiscretization((-20, 0))

    # A mutable immersed grid
    mutable_grid = RectilinearGrid(size=(2, 2, 20), x=(0, 2), y=(0, 1), z=z)
    mutable_grid = ImmersedBoundaryGrid(mutable_grid, GridFittedBottom((x, y) -> -10))

    # A static immersed grid
    static_grid = RectilinearGrid(size=(2, 2, 20), x=(0, 2), y=(0, 1), z=(-20, 0))
    static_grid = ImmersedBoundaryGrid(static_grid, GridFittedBottom((x, y) -> -10))

    # Make sure a model with a MutableVerticalDiscretization but ZCoordinate still runs and
    # the results are the same as a model with a static vertical discretization.
    kw = (; free_surface=ImplicitFreeSurface(), vertical_coordinate=ZCoordinate())
    mutable_model = HydrostaticFreeSurfaceModel(; grid=mutable_grid, kw...)
    static_model  = HydrostaticFreeSurfaceModel(; grid=static_grid, kw...)

    @test mutable_model.vertical_coordinate isa ZCoordinate
    @test static_model.vertical_coordinate isa ZCoordinate

    uᵢ = rand(size(mutable_model.velocities.u)...)
    vᵢ = rand(size(mutable_model.velocities.v)...)

    set!(mutable_model; u=uᵢ, v=vᵢ)
    set!(static_model;  u=uᵢ, v=vᵢ)

    static_sim  = Simulation(static_model;  Δt=1e-3, stop_iteration=100)
    mutable_sim = Simulation(mutable_model; Δt=1e-3, stop_iteration=100)

    run!(mutable_sim)
    run!(static_sim)

    # Check that fields are the same
    um, vm, wm = mutable_model.velocities
    us, vs, ws = static_model.velocities

    @test all(um.data .≈ us.data)
    @test all(vm.data .≈ vs.data)
    @test all(wm.data .≈ ws.data)
    @test all(um.data .≈ us.data)
end

@testset "ZStar diffusion test" begin
    Random.seed!(1234)

    # Build a stretched vertical coordinate
    z_static = [i + rand() for i in -15:0]
    z_static[1] = -15
    z_static[end] = 0
    z_moving = MutableVerticalDiscretization(z_static ./ 1.5)

    for arch in archs
        c₀ = rand(15)

        grid_static = RectilinearGrid(arch; size=15, z=z_static, topology=(Flat, Flat, Bounded))
        grid_moving = RectilinearGrid(arch; size=15, z=z_moving, topology=(Flat, Flat, Bounded))

        fill!(grid_moving.z.ηⁿ,   5)
        fill!(grid_moving.z.σᶜᶜ⁻, 1.5)
        fill!(grid_moving.z.σᶜᶜⁿ, 1.5)
        fill!(grid_moving.z.σᶜᶠⁿ, 1.5)
        fill!(grid_moving.z.σᶠᶠⁿ, 1.5)
        fill!(grid_moving.z.σᶠᶜⁿ, 1.5)

        for TD in (ExplicitTimeDiscretization, VerticallyImplicitTimeDiscretization)
            for timestepper in (:QuasiAdamsBashforth2, :SplitRungeKutta3)
                for c_bcs in (NoFluxBoundaryCondition(), FluxBoundaryCondition(0.01), ValueBoundaryCondition(0.01))
                    @info "testing ZStar diffusion on $(typeof(arch)) with $TD, $timestepper, and $c_bcs at the top"

                    model_static = HydrostaticFreeSurfaceModel(; grid = grid_static,
                                                                tracers = :c,
                                                                timestepper,
                                                                boundary_conditions = (; c = FieldBoundaryConditions(top=c_bcs)),
                                                                closure = VerticalScalarDiffusivity(TD(), κ=0.1))

                    model_moving = HydrostaticFreeSurfaceModel(; grid = grid_moving,
                                                                tracers = :c,
                                                                timestepper,
                                                                boundary_conditions = (; c = FieldBoundaryConditions(top=c_bcs)),
                                                                closure = VerticalScalarDiffusivity(TD(), κ=0.1))

                    set!(model_static, c = c₀)
                    set!(model_moving, c = c₀)

                    for _ in 1:1000
                        time_step!(model_static, 1.0)
                        time_step!(model_moving, 1.0)
                    end

                    @test all(Array(interior(model_static.tracers.c)) .≈ Array(interior(model_moving.tracers.c)))
                end
            end
        end
    end
end

@testset "ZStar tracer conservation testset" begin
    z_stretched = MutableVerticalDiscretization(collect(-20:0))
    topologies  = ((Periodic, Periodic, Bounded),
                   (Periodic, Bounded, Bounded),
                   (Bounded, Periodic, Bounded),
                   (Bounded, Bounded, Bounded))

    for arch in archs
        for topology in topologies
            Random.seed!(1234)

            rtgv = RectilinearGrid(arch; size = (10, 10, 20), x = (0, 100kilometers), y = (-10kilometers, 10kilometers), topology, z = z_stretched)
            irtgv = ImmersedBoundaryGrid(deepcopy(rtgv),  GridFittedBottom((x, y) -> rand() - 10))
            prtgv = ImmersedBoundaryGrid(deepcopy(rtgv), PartialCellBottom((x, y) -> rand() - 10))

            if topology[2] == Bounded
                llgv = LatitudeLongitudeGrid(arch; size = (10, 10, 20), latitude = (0, 1), longitude = (0, 1), topology, z = z_stretched)

                illgv = ImmersedBoundaryGrid(deepcopy(llgv),  GridFittedBottom((x, y) -> rand() - 10))
                pllgv = ImmersedBoundaryGrid(deepcopy(llgv), PartialCellBottom((x, y) -> rand() - 10))

                # TODO: Partial cell bottom are broken at the moment and do not account for the Δz in the volumes
                # and vertical areas (see https://github.com/CliMA/Oceananigans.jl/issues/3958)
                # When this is issue is fixed we can add the partial cells to the testing.
                grids = [llgv, rtgv, illgv, irtgv] # , pllgv, prtgv]
            else
                grids = [rtgv, irtgv] #, prtgv]
            end

            for grid in grids
                split_free_surface    = SplitExplicitFreeSurface(grid; cfl = 0.75)
                implicit_free_surface = ImplicitFreeSurface()
                explicit_free_surface = ExplicitFreeSurface()

                for free_surface in [split_free_surface, implicit_free_surface, explicit_free_surface]

                    # TODO: There are parameter space issues with ImplicitFreeSurface and a immersed LatitudeLongitudeGrid
                    # For the moment we are skipping these tests.
                    if (arch isa GPU) &&
                       (free_surface isa ImplicitFreeSurface) &&
                       (grid isa ImmersedBoundaryGrid) &&
                       (grid.underlying_grid isa LatitudeLongitudeGrid)

                        @info "  Skipping $(info_message(grid, free_surface)) because of parameter space issues"
                        continue
                    end

                    info_msg = info_message(grid, free_surface)
                    @testset "$info_msg" begin
                        @info "  Testing a $info_msg"
                        model = HydrostaticFreeSurfaceModel(; grid,
                                                            free_surface,
                                                            tracers = (:b, :c, :constant),
                            				                buoyancy = BuoyancyTracer(),
                                                            vertical_coordinate = ZStar())

                        bᵢ(x, y, z) = x < grid.Lx / 2 ? 0.06 : 0.01

                        set!(model, c = (x, y, z) -> rand(), b = bᵢ, constant = 1)

                        Δt = free_surface isa ExplicitFreeSurface ? 10 : 2minutes
                        test_zstar_coordinate(model, 100, Δt)
                    end
                end
            end
        end

        @info "  Testing a ZStar and Runge-Kutta 3rd order time stepping"

        topology = topologies[2]
        rtg  = RectilinearGrid(arch; size=(10, 10, 20), x=(0, 100kilometers), y=(-10kilometers, 10kilometers), topology, z=z_stretched)
        llg  = LatitudeLongitudeGrid(arch; size=(10, 10, 20), latitude=(0, 1), longitude=(0, 1), topology, z=z_stretched)
        irtg = ImmersedBoundaryGrid(deepcopy(rtg), GridFittedBottom((x, y) -> rand()-10))
        illg = ImmersedBoundaryGrid(deepcopy(llg), GridFittedBottom((x, y) -> rand()-10))

        for grid in [rtg, llg, irtg, illg]
            split_free_surface = SplitExplicitFreeSurface(grid; substeps=50)
            model = HydrostaticFreeSurfaceModel(; grid,
                                                free_surface = split_free_surface,
                                                tracers = (:b, :c, :constant),
                                                timestepper = :SplitRungeKutta3,
                                                buoyancy = BuoyancyTracer(),
                                                vertical_coordinate = ZStar())

            bᵢ(x, y, z) = x < grid.Lx / 2 ? 0.06 : 0.01

            set!(model, c = (x, y, z) -> rand(), b = bᵢ, constant = 1)

            Δt = 2minutes
            test_zstar_coordinate(model, 100, Δt)
        end

        @testset "TripolarGrid ZStar tracer conservation tests" begin
            @info "Testing a ZStar coordinate with a Tripolar grid on $(arch)..."

            grid = TripolarGrid(arch; size = (20, 20, 20), z = z_stretched)

            # Code credit:
            # https://github.com/PRONTOLab/GB-25/blob/682106b8487f94da24a64d93e86d34d560f33ffc/src/model_utils.jl#L65
            function mtn₁(λ, φ)
                λ₁ = 70
                φ₁ = 55
                dφ = 5
                return exp(-((λ - λ₁)^2 + (φ - φ₁)^2) / 2dφ^2)
            end

            function mtn₂(λ, φ)
                λ₁ = 70
                λ₂ = λ₁ + 180
                φ₂ = 55
                dφ = 5
                return exp(-((λ - λ₂)^2 + (φ - φ₂)^2) / 2dφ^2)
            end

            zb = - 20
            h  = - zb + 10
            gaussian_islands(λ, φ) = zb + h * (mtn₁(λ, φ) + mtn₂(λ, φ))

            grid = ImmersedBoundaryGrid(grid, GridFittedBottom(gaussian_islands))
            free_surface = SplitExplicitFreeSurface(grid; substeps=10)

            model = HydrostaticFreeSurfaceModel(; grid,
                                                  free_surface,
                                                  tracers = (:b, :c, :constant),
                                                  buoyancy = BuoyancyTracer(),
                                                  vertical_coordinate = ZStar())

            bᵢ(x, y, z) = y < 0 ? 0.06 : 0.01

            # Instead of initializing with random velocities, infer them from a random initial streamfunction
            # to ensure the velocity field is divergence-free at initialization.
            ψ = Field{Center, Center, Center}(grid)
            set!(ψ, rand(size(ψ)...))
            uᵢ = ∂y(ψ)
            vᵢ = -∂x(ψ)

            set!(model, c = (x, y, z) -> rand(), u = uᵢ, v = vᵢ, b = bᵢ, constant = 1)

            Δt = 2minutes
            test_zstar_coordinate(model, 300, Δt)
        end
    end
end
