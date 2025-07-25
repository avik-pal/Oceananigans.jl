include("dependencies_for_runtests.jl")

@testset "Field broadcasting" begin
    @info "  Testing broadcasting with fields..."

    for arch in archs

        #####
        ##### Basic functionality tests
        #####

        grid = RectilinearGrid(arch, size=(1, 1, 1), extent=(1, 1, 1))
        a, b, c = [CenterField(grid) for i = 1:3]

        Nx, Ny, Nz = size(a)

        a .= 1
        @test @allowscalar all(a .== 1)

        b .= 2

        c .= a .+ b
        @test @allowscalar all(c .== 3)

        c .= a .+ b .+ 1
        @test @allowscalar all(c .== 4)

        # Halo regions
        fill_halo_regions!(c) # Does not happen by default in broadcasting now

        @allowscalar begin
            @test c[1, 1, 0] == 4
            @test c[1, 1, Nz+1] == 4
        end

        #####
        ##### Broadcasting with interpolation
        #####

        three_point_grid = RectilinearGrid(arch, size=(1, 1, 3), extent=(1, 1, 1))

        a2 = CenterField(three_point_grid)

        b2_bcs = FieldBoundaryConditions(grid, (Center, Center, Face), top=OpenBoundaryCondition(0), bottom=OpenBoundaryCondition(0))
        b2 = ZFaceField(three_point_grid, boundary_conditions=b2_bcs)

        b2 .= 1
        fill_halo_regions!(b2) # sets b2[1, 1, 1] = b[1, 1, 4] = 0

        @allowscalar begin
            @test b2[1, 1, 1] == 0
            @test b2[1, 1, 2] == 1
            @test b2[1, 1, 3] == 1
            @test b2[1, 1, 4] == 0
        end

        a2 .= b2

        @allowscalar begin
            @test a2[1, 1, 1] == 0.5
            @test a2[1, 1, 2] == 1.0
            @test a2[1, 1, 3] == 0.5
        end

        a2 .= b2 .+ 1

        @allowscalar begin
            @test a2[1, 1, 1] == 1.5
            @test a2[1, 1, 2] == 2.0
            @test a2[1, 1, 3] == 1.5
        end

        #####
        ##### Broadcasting with ReducedField
        #####

        for Loc in [
                    (Nothing, Center, Center),
                    (Center, Nothing, Center),
                    (Center, Center, Nothing),
                    (Center, Nothing, Nothing),
                    (Nothing, Center, Nothing),
                    (Nothing, Nothing, Center),
                    (Nothing, Nothing, Nothing),
                   ]

            @info "    Testing broadcasting to location $Loc..."

            r, p, q = [Field{Loc...}(grid) for i = 1:3]

            r .= 2
            @test @allowscalar all(r .== 2)

            p .= 3

            q .= r .* p
            @test @allowscalar all(q .== 6)

            q .= r .* p .+ 1
            @test @allowscalar all(q .== 7)
        end


        #####
        ##### Broadcasting with arrays
        #####

        two_two_two_grid = RectilinearGrid(arch, size=(2, 2, 2), extent=(1, 1, 1))

        c = CenterField(two_two_two_grid)
        random_column = on_architecture(arch, reshape(rand(2), 1, 1, 2))

        c .= random_column # broadcast to every horizontal column in c

        c_cpu = Array(interior(c))
        random_column_cpu = Array(random_column)

        @test all(c_cpu[1, 1, :] .== random_column_cpu[:])
        @test all(c_cpu[2, 1, :] .== random_column_cpu[:])
        @test all(c_cpu[1, 2, :] .== random_column_cpu[:])
        @test all(c_cpu[2, 2, :] .== random_column_cpu[:])
    end
end
