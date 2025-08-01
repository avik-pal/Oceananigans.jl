include("dependencies_for_runtests.jl")

using Oceananigans.Grids: required_halo_size_x, required_halo_size_y, required_halo_size_z

@testset "Models" begin
    @info "Testing models..."

    grids = (RectilinearGrid(CPU(), size=(1, 1, 1), extent=(1, 1, 1)),
             LatitudeLongitudeGrid(CPU(), size=(1, 1, 1), longitude=(-180, 180), latitude=(-20, 20), z=(-1, 0)))

    for grid in grids
        @testset "$grid grid construction" begin
            @info "  Testing $grid grid construction..."
                @test_throws TypeError NonhydrostaticModel(; grid, boundary_conditions=1)
                @test_throws TypeError NonhydrostaticModel(; grid, forcing=2)
                @test_throws TypeError NonhydrostaticModel(; grid, background_fields=3)

        end
    end

    topos = ((Periodic, Periodic, Periodic),
             (Periodic, Periodic,  Bounded),
             (Periodic,  Bounded,  Bounded),
             (Bounded,   Bounded,  Bounded))

    for topo in topos
        @testset "$topo model construction" begin
            @info "  Testing $topo model construction..."
            for arch in archs, FT in float_types
                arch isa GPU && topo == (Bounded, Bounded, Bounded) && continue

                grid = RectilinearGrid(arch, FT, topology=topo, size=(16, 16, 2), extent=(1, 2, 3))
                model = NonhydrostaticModel(; grid)

                @test model isa NonhydrostaticModel
            end
        end
    end

    @testset "Adjustment of halos in NonhydrostaticModel constructor" begin
        @info "  Testing adjustment of halos in NonhydrostaticModel constructor..."

        minimal_grid = RectilinearGrid(size=(4, 4, 4), extent=(1, 2, 3), halo=(1, 1, 1))
          funny_grid = RectilinearGrid(size=(4, 4, 4), extent=(1, 2, 3), halo=(1, 3, 4))

        # Model ensures that halos are at least of size 1
        model = NonhydrostaticModel(grid=minimal_grid)
        @test model.grid.Hx == 1 && model.grid.Hy == 1 && model.grid.Hz == 1

        model = NonhydrostaticModel(grid=funny_grid)
        @test model.grid.Hx == 1 && model.grid.Hy == 3 && model.grid.Hz == 4

        # Model ensures that halos are at least of size 2
        for scheme in (Centered(order=4), UpwindBiased(order=3))
            model = NonhydrostaticModel(advection=scheme, grid=minimal_grid)
            @test model.grid.Hx == 2 && model.grid.Hy == 2 && model.grid.Hz == 2

            model = NonhydrostaticModel(advection=scheme, grid=funny_grid)
            @test model.grid.Hx == 2 && model.grid.Hy == 3 && model.grid.Hz == 4
        end

        # Model ensures that halos are at least of size 3
        for scheme in (WENO(), UpwindBiased(order=5))
            model = NonhydrostaticModel(advection=scheme, grid=minimal_grid)
            @test model.grid.Hx == 3 && model.grid.Hy == 3 && model.grid.Hz == 3

            model = NonhydrostaticModel(advection=scheme, grid=funny_grid)
            @test model.grid.Hx == 3 && model.grid.Hy == 3 && model.grid.Hz == 4
        end

        # Model ensures that halos are at least of size 2 with ScalarBiharmonicDiffusivity
        model = NonhydrostaticModel(closure=ScalarBiharmonicDiffusivity(), grid=minimal_grid)
        @test model.grid.Hx == 2 && model.grid.Hy == 2 && model.grid.Hz == 2

        model = NonhydrostaticModel(closure=ScalarBiharmonicDiffusivity(), grid=funny_grid)
        @test model.grid.Hx == 2 && model.grid.Hy == 3 && model.grid.Hz == 4

        @info "  Testing adjustment of advection schemes in NonhydrostaticModel constructor..."
        small_grid = RectilinearGrid(size=(4, 2, 4), extent=(1, 2, 3), halo=(1, 1, 1))

        # Model ensures that halos are at least of size 1
        model = NonhydrostaticModel(grid=small_grid, advection=WENO())
        @test model.advection isa FluxFormAdvection
        @test required_halo_size_x(model.advection) == 3
        @test required_halo_size_y(model.advection) == 2
        @test required_halo_size_z(model.advection) == 3

        model = NonhydrostaticModel(grid=small_grid, advection=UpwindBiased(; order = 9))
        @test model.advection isa FluxFormAdvection
        @test required_halo_size_x(model.advection) == 4
        @test required_halo_size_y(model.advection) == 2
        @test required_halo_size_z(model.advection) == 4

        model = NonhydrostaticModel(grid=small_grid, advection=Centered(; order = 10))
        @test model.advection isa FluxFormAdvection
        @test required_halo_size_x(model.advection) == 4
        @test required_halo_size_y(model.advection) == 2
        @test required_halo_size_z(model.advection) == 4
    end

    @testset "Model construction with single tracer and nothing tracer" begin
        @info "  Testing model construction with single tracer and nothing tracer..."
        for arch in archs
            for grid in grids
                model = NonhydrostaticModel(; grid, tracers=:c, buoyancy=nothing)
                @test model isa NonhydrostaticModel

                model = NonhydrostaticModel(; grid, tracers=nothing, buoyancy=nothing)
                @test model isa NonhydrostaticModel
            end
        end
    end

    @testset "Setting model fields" begin
        @info "  Testing setting model fields..."
        for arch in archs, FT in float_types
            N = (4, 4, 4)
            L = (2π, 3π, 5π)

            rectilinear_grid = RectilinearGrid(arch, FT, size=N, extent=L,
                                               topology = (Periodic, Bounded, Bounded))
            latlon_grid = LatitudeLongitudeGrid(arch, FT; size=N, latitude=(-1, 1), longitude=(-1, 1), z=(-100, 0),
                                                topology = (Periodic, Bounded, Bounded))
            
            for grid in (rectilinear_grid, latlon_grid)
                model = NonhydrostaticModel(; grid, buoyancy=SeawaterBuoyancy(), tracers=(:T, :S))

                u, v, w = model.velocities
                T, S = model.tracers

                # Test setting an array
                T₀_array = rand(FT, size(grid)...)
                T_answer = deepcopy(T₀_array)

                set!(model; enforce_incompressibility=false, T=T₀_array)

                @test Array(interior(T)) ≈ T_answer

                # Test setting functions
                u₀(x, y, z) = 1 + x + y + z
                v₀(x, y, z) = 2 + sin(x * y * z)
                w₀(x, y, z) = 3 + y * z
                T₀(x, y, z) = 4 + tanh(x + y - z)
                S₀(x, y, z) = 5

                set!(model, enforce_incompressibility=false, u=u₀, v=v₀, w=w₀, T=T₀, S=S₀)

                xC, yC, zC = nodes(model.grid, (Center(), Center(), Center()), reshape=true)
                xF, yF, zF = nodes(model.grid, (Face(),   Face(),   Face()), reshape=true)

                # Form solution arrays
                u_answer = u₀.(xF, yC, zC) |> Array
                v_answer = v₀.(xC, yF, zC) |> Array
                w_answer = w₀.(xC, yC, zF) |> Array
                T_answer = T₀.(xC, yC, zC) |> Array
                S_answer = S₀.(xC, yC, zC) |> Array

                Nx, Ny, Nz = size(model.grid)

                cpu_grid = on_architecture(CPU(), grid)

                u_cpu = XFaceField(cpu_grid)
                v_cpu = YFaceField(cpu_grid)
                w_cpu = ZFaceField(cpu_grid)
                T_cpu = CenterField(cpu_grid)
                S_cpu = CenterField(cpu_grid)

                set!(u_cpu, u)
                set!(v_cpu, v)
                set!(w_cpu, w)
                set!(T_cpu, T)
                set!(S_cpu, S)

                values_match = [
                                all(u_answer .≈ interior(u_cpu)),
                                all(v_answer[:, 2:Ny, :] .≈ interior(v_cpu)[:, 2:Ny, :]),
                                all(w_answer[:, :, 2:Nz] .≈ interior(w_cpu)[:, :, 2:Nz]),
                                all(T_answer .≈ interior(T_cpu)),
                                all(S_answer .≈ interior(S_cpu)),
                               ]

                @test all(values_match)

                # Test whether set! copies boundary conditions
                # Note: we need to cleanup broadcasting for this -- see https://github.com/CliMA/Oceananigans.jl/pull/2786/files#r1008955571
                @test u_cpu[1, 1, 1] == u_cpu[Nx+1, 1, 1]  # x-periodicity
                @test all(u_cpu[1:Nx, 1:Ny, 1] .== u_cpu[1:Nx, 1:Ny, 0])     # free slip at bottom
                @test all(u_cpu[1:Nx, 1:Ny, Nz] .== u_cpu[1:Nx, 1:Ny, Nz+1]) # free slip at top

                # Test that enforce_incompressibility works
                set!(model, u=0, v=0, w=1, T=0, S=0)
                ϵ = 10 * eps(FT)
                set!(w_cpu, w)
                @test all(abs.(interior(w_cpu)) .< ϵ)

                # Test setting the background_fields to a Field
                U_field = XFaceField(grid)
                U_field .= 1
                model = NonhydrostaticModel(; grid, background_fields = (u=U_field,))
                @test model.background_fields.velocities.u isa Field

                U_field = CenterField(grid)
                @test_throws ArgumentError NonhydrostaticModel(; grid, background_fields = (u=U_field,))
            end
        end
    end
end
