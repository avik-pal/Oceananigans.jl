include("dependencies_for_runtests.jl")

using Statistics

using Oceananigans.Fields: ReducedField, has_velocities
using Oceananigans.Fields: VelocityFields, TracerFields, interpolate, interpolate!
using Oceananigans.Fields: reduced_location
using Oceananigans.Fields: FractionalIndices, interpolator, instantiate
using Oceananigans.Fields: convert_to_0_360, convert_to_λ₀_λ₀_plus360
using Oceananigans.Grids: ξnode, ηnode, rnode
using Oceananigans.Grids: total_length
using Oceananigans.Grids: λnode

using Random
using CUDA: @allowscalar

"""
    correct_field_size(grid, FieldType, Tx, Ty, Tz)

Test that the field initialized by the FieldType constructor on `grid`
has size `(Tx, Ty, Tz)`.
"""
correct_field_size(grid, loc, Tx, Ty, Tz) = size(parent(Field(instantiate(loc), grid))) == (Tx, Ty, Tz)

function run_similar_field_tests(f)
    g = similar(f)
    @test typeof(f) == typeof(g)
    @test f.grid == g.grid
    @test location(f) === location(g)
    @test !(f.data === g.data)
    return nothing
end

"""
     correct_field_value_was_set(N, L, ftf, val)

Test that the field initialized by the field type function `ftf` on the grid g
can be correctly filled with the value `val` using the `set!(f::AbstractField, v)`
function.
"""
function correct_field_value_was_set(grid, FieldType, val::Number)
    arch = architecture(grid)
    f = FieldType(grid)
    set!(f, val)
    return all(interior(f) .≈ val * on_architecture(arch, ones(size(f))))
end

function run_field_reduction_tests(FT, arch)
    N = 8
    topo = (Bounded, Bounded, Bounded)
    grid = RectilinearGrid(arch, FT, topology=topo, size=(N, N, N), x=(-1, 1), y=(0, 2π), z=(-1, 1))

    u = XFaceField(grid)
    v = YFaceField(grid)
    w = ZFaceField(grid)
    c = CenterField(grid)

    f(x, y, z) = 1 + exp(x) * sin(y) * tanh(z)

    ϕs = (u, v, w, c)
    [set!(ϕ, f) for ϕ in ϕs]

    u_vals = f.(nodes(u, reshape=true)...)
    v_vals = f.(nodes(v, reshape=true)...)
    w_vals = f.(nodes(w, reshape=true)...)
    c_vals = f.(nodes(c, reshape=true)...)

    # Convert to CuArray if needed.
    u_vals = on_architecture(arch, u_vals)
    v_vals = on_architecture(arch, v_vals)
    w_vals = on_architecture(arch, w_vals)
    c_vals = on_architecture(arch, c_vals)

    ϕs_vals = (u_vals, v_vals, w_vals, c_vals)

    dims_to_test = (1, 2, 3, (1, 2), (1, 3), (2, 3), (1, 2, 3))

    for (ϕ, ϕ_vals) in zip(ϕs, ϕs_vals)

        ε = eps(eltype(ϕ_vals)) * 10 * maximum(maximum.(ϕs_vals))
        @info "    Testing field reductions with tolerance $ε..."

        @test @allowscalar all(isapprox.(ϕ, ϕ_vals, atol=ε)) # if this isn't true, reduction tests can't pass

        # Important to make sure no CUDA scalar operations occur!
        CUDA.allowscalar(false)

        @test minimum(ϕ) ≈ minimum(ϕ_vals) atol=ε
        @test maximum(ϕ) ≈ maximum(ϕ_vals) atol=ε
        @test mean(ϕ) ≈ mean(ϕ_vals) atol=2ε
        @test minimum(∛, ϕ) ≈ minimum(∛, ϕ_vals) atol=ε
        @test maximum(abs, ϕ) ≈ maximum(abs, ϕ_vals) atol=ε
        @test mean(abs2, ϕ) ≈ mean(abs2, ϕ) atol=ε

        @test extrema(ϕ) == (minimum(ϕ), maximum(ϕ))
        @test extrema(∛, ϕ) == (minimum(∛, ϕ), maximum(∛, ϕ))

        for dims in dims_to_test
            @test all(isapprox(minimum(ϕ, dims=dims), minimum(ϕ_vals, dims=dims), atol=4ε))
            @test all(isapprox(maximum(ϕ, dims=dims), maximum(ϕ_vals, dims=dims), atol=4ε))
            @test all(isapprox(mean(ϕ, dims=dims), mean(ϕ_vals, dims=dims), atol=4ε))

            @test all(isapprox(minimum(sin, ϕ, dims=dims), minimum(sin, ϕ_vals, dims=dims), atol=4ε))
            @test all(isapprox(maximum(cos, ϕ, dims=dims), maximum(cos, ϕ_vals, dims=dims), atol=4ε))
            @test all(isapprox(mean(cosh, ϕ, dims=dims), mean(cosh, ϕ_vals, dims=dims), atol=5ε))
        end
    end

    return nothing
end

@inline interpolate_xyz(x, y, z, from_field, from_loc, from_grid) =
    interpolate((x, y, z), from_field, from_loc, from_grid)

# Choose a trilinear function so trilinear interpolation can return values that
# are exactly correct.
@inline func(x, y, z) = convert(typeof(x), exp(-1) + 3x - y/7 + z + 2x*y - 3x*z + 4y*z - 5x*y*z)

function run_field_interpolation_tests(grid)
    arch = architecture(grid)
    velocities = VelocityFields(grid)
    tracers = TracerFields((:c,), grid)

    (u, v, w), c = velocities, tracers.c

    # Maximum expected rounding error is the unit in last place of the maximum value
    # of func over the domain of the grid.

    # TODO: remove this allowscalar when `nodes` returns broadcastable object on GPU
    xf, yf, zf = nodes(grid, (Face(), Face(), Face()), reshape=true)
    f_max = @allowscalar maximum(func.(xf, yf, zf))
    ε_max = eps(f_max)
    tolerance = 10 * ε_max

    set!(u, func)
    set!(v, func)
    set!(w, func)
    set!(c, func)

    # Check that interpolating to the field's own grid points returns
    # the same value as the field itself.

    for f in (u, v, w, c)
        x, y, z = nodes(f, reshape=true)
        loc = Tuple(L() for L in location(f))

        @allowscalar begin
            ℑf = interpolate_xyz.(x, y, z, Ref(f.data), Ref(loc), Ref(f.grid))
        end

        ℑf_cpu = Array(ℑf)
        f_interior_cpu = Array(interior(f))
        @test all(isapprox.(ℑf_cpu, f_interior_cpu, atol=tolerance))
    end

    # Check that interpolating between grid points works as expected.

    xs = Array(reshape([0.3, 0.55, 0.73], (3, 1, 1)))
    ys = Array(reshape([-π/6, 0, 1+1e-7], (1, 3, 1)))
    zs = Array(reshape([-1.3, 1.23, 2.1], (1, 1, 3)))

    X = [(xs[i], ys[j], zs[k]) for i=1:3, j=1:3, k=1:3]
    X = on_architecture(arch, X)

    xs = on_architecture(arch, xs)
    ys = on_architecture(arch, ys)
    zs = on_architecture(arch, zs)

    @allowscalar begin
        for f in (u, v, w, c)
            loc = Tuple(L() for L in location(f))
            ℑf = interpolate_xyz.(xs, ys, zs, Ref(f.data), Ref(loc), Ref(f.grid))
            F = func.(xs, ys, zs)
            F = Array(F)
            ℑf = Array(ℑf)
            @test all(isapprox.(ℑf, F, atol=tolerance))

            # for the next test we first call fill_halo_regions! on the
            # original field `f`
            # note, that interpolate! will call fill_halo_regions! on
            # the interpolated field after the interpolation
            fill_halo_regions!(f)

            f_copy = deepcopy(f)
            fill!(f_copy, 0)
            interpolate!(f_copy, f)

            @test all(interior(f_copy) .≈ interior(f))
        end
    end

    @info "Testing the convert functions"
    for n in 1:30
        @test convert_to_0_360(- 10.e0^(-n)) > 359
        @test convert_to_0_360(- 10.f0^(-n)) > 359
        @test convert_to_0_360(10.e0^(-n))   < 1
        @test convert_to_0_360(10.f0^(-n))   < 1
    end

    # Generating a random longitude left bound between -1000 and 1000
    λs₀ = rand(1000) .* 2000 .- 1000

    # Generating a random interpolation longitude
    λsᵢ = rand(1000) .* 2000 .- 1000

    for λ₀ in λs₀, λᵢ in λsᵢ
        @test λ₀ ≤ convert_to_λ₀_λ₀_plus360(λᵢ, λ₀) ≤ λ₀ + 360
    end

    # Check interpolation on Windowed fields
    wf = ZFaceField(grid; indices=(:, :, grid.Nz+1))
    If = Field{Center, Center, Nothing}(grid)
    set!(If, (x, y)-> x * y)
    interpolate!(wf, If)

    @allowscalar begin
        @test all(interior(wf) .≈ interior(If))
    end

    # interpolation between fields on latitudelongitude grids with different longitudes
    grid1 = LatitudeLongitudeGrid(size=(10, 1, 1), longitude=(    0,       360), latitude=(-90, 90), z=(0, 1))
    grid2 = LatitudeLongitudeGrid(size=(10, 1, 1), longitude=( -180,       180), latitude=(-90, 90), z=(0, 1))
    grid3 = LatitudeLongitudeGrid(size=(10, 1, 1), longitude=(-1080, -1080+360), latitude=(-90, 90), z=(0, 1))
    grid4 = LatitudeLongitudeGrid(size=(10, 1, 1), longitude=(  180,       540), latitude=(-90, 90), z=(0, 1))

    f1 = CenterField(grid1)
    f2 = CenterField(grid2)
    f3 = CenterField(grid3)
    f4 = CenterField(grid4)

    set!(f1, (λ, y, z) -> λ)
    fill_halo_regions!(f1)
    interpolate!(f2, f1)
    interpolate!(f3, f1)
    interpolate!(f4, f1)

    @test all(interior(f2) .≈ map(convert_to_0_360, λnodes(grid2, Center())))
    @test all(interior(f3) .≈ map(convert_to_0_360, λnodes(grid3, Center())))
    @test all(interior(f4) .≈ map(convert_to_0_360, λnodes(grid4, Center())))

    # now interpolate back
    fill_halo_regions!(f2)
    fill_halo_regions!(f3)
    fill_halo_regions!(f4)

    interpolate!(f1, f2)
    @test all(interior(f1) .≈ λnodes(grid1, Center()))

    interpolate!(f1, f3)
    @test all(interior(f1) .≈ λnodes(grid1, Center()))

    interpolate!(f1, f4)
    @test all(interior(f1) .≈ λnodes(grid1, Center()))

    return nothing
end

#####
#####
#####

@testset "Fields" begin
    @info "Testing Fields..."

    @testset "Field initialization" begin
        @info "  Testing Field initialization..."

        N = (4, 6, 8)
        L = (2π, 3π, 5π)
        H = (1, 1, 1)

        for arch in archs, FT in float_types
            grid = RectilinearGrid(arch, FT, size=N, extent=L, halo=H, topology=(Periodic, Periodic, Periodic))
            @test correct_field_size(grid, (Center, Center, Center), N[1] + 2 * H[1], N[2] + 2 * H[2], N[3] + 2 * H[3])
            @test correct_field_size(grid, (Face,   Center, Center), N[1] + 2 * H[1], N[2] + 2 * H[2], N[3] + 2 * H[3])
            @test correct_field_size(grid, (Center, Face,   Center), N[1] + 2 * H[1], N[2] + 2 * H[2], N[3] + 2 * H[3])
            @test correct_field_size(grid, (Center, Center, Face),   N[1] + 2 * H[1], N[2] + 2 * H[2], N[3] + 2 * H[3])

            grid = RectilinearGrid(arch, FT, size=N, extent=L, halo=H, topology=(Periodic, Periodic, Bounded))
            @test correct_field_size(grid, (Center, Center, Center), N[1] + 2 * H[1], N[2] + 2 * H[2], N[3] + 2 * H[3])
            @test correct_field_size(grid, (Face, Center, Center),   N[1] + 2 * H[1], N[2] + 2 * H[2], N[3] + 2 * H[3])
            @test correct_field_size(grid, (Center, Face, Center),   N[1] + 2 * H[1], N[2] + 2 * H[2], N[3] + 2 * H[3])
            @test correct_field_size(grid, (Center, Center, Face),   N[1] + 2 * H[1], N[2] + 2 * H[2], N[3] + 2 * H[3] + 1)

            grid = RectilinearGrid(arch, FT, size=N, extent=L, halo=H, topology=(Periodic, Bounded, Bounded))
            @test correct_field_size(grid, (Center, Center, Center), N[1] + 2 * H[1], N[2] + 2 * H[2], N[3] + 2 * H[3])
            @test correct_field_size(grid, (Face, Center, Center),   N[1] + 2 * H[1], N[2] + 2 * H[2], N[3] + 2 * H[3])
            @test correct_field_size(grid, (Center, Face, Center),   N[1] + 2 * H[1], N[2] + 1 + 2 * H[2], N[3] + 2 * H[3])
            @test correct_field_size(grid, (Center, Center, Face),   N[1] + 2 * H[1], N[2] + 2 * H[2], N[3] + 1 + 2 * H[3])

            grid = RectilinearGrid(arch, FT, size=N, extent=L, halo=H, topology=(Bounded, Bounded, Bounded))
            @test correct_field_size(grid, (Center, Center, Center), N[1] + 2 * H[1], N[2] + 2 * H[2], N[3] + 2 * H[3])
            @test correct_field_size(grid, (Face, Center, Center),   N[1] + 1 + 2 * H[1], N[2] + 2 * H[2], N[3] + 2 * H[3])
            @test correct_field_size(grid, (Center, Face, Center),   N[1] + 2 * H[1], N[2] + 1 + 2 * H[2], N[3] + 2 * H[3])
            @test correct_field_size(grid, (Center, Center, Face),   N[1] + 2 * H[1], N[2] + 2 * H[2], N[3] + 1 + 2 * H[3])

            # Reduced fields
            @test correct_field_size(grid, (Nothing, Center,  Center),  1,               N[2] + 2 * H[2],     N[3] + 2 * H[3])
            @test correct_field_size(grid, (Nothing, Center,  Center),  1,               N[2] + 2 * H[2],     N[3] + 2 * H[3])
            @test correct_field_size(grid, (Nothing, Face,    Center),  1,               N[2] + 2 * H[2] + 1, N[3] + 2 * H[3])
            @test correct_field_size(grid, (Nothing, Face,    Face),    1,               N[2] + 2 * H[2] + 1, N[3] + 2 * H[3] + 1)
            @test correct_field_size(grid, (Center,  Nothing, Center),  N[1] + 2 * H[1], 1,                   N[3] + 2 * H[3])
            @test correct_field_size(grid, (Center,  Nothing, Center),  N[1] + 2 * H[1], 1,                   N[3] + 2 * H[3])
            @test correct_field_size(grid, (Center,  Center,  Nothing), N[1] + 2 * H[1], N[2] + 2 * H[2],     1)
            @test correct_field_size(grid, (Nothing, Nothing, Center),  1,               1,                   N[3] + 2 * H[3])
            @test correct_field_size(grid, (Center,  Nothing, Nothing), N[1] + 2 * H[1], 1,                   1)
            @test correct_field_size(grid, (Nothing, Nothing, Nothing), 1,               1,                   1)

            # "View" fields
            for f in [CenterField(grid), XFaceField(grid), YFaceField(grid), ZFaceField(grid)]

                test_indices = [(:, :, :), (1:2, 3:4, 5:6), (1, 1:6, :)]
                test_field_sizes  = [size(f), (2, 2, 2), (1, 6, size(f, 3))]
                test_parent_sizes = [size(parent(f)), (2, 2, 2), (1, 6, size(parent(f), 3))]

                for (t, indices) in enumerate(test_indices)
                    field_sz = test_field_sizes[t]
                    parent_sz = test_parent_sizes[t]
                    f_view = view(f, indices...)
                    f_sliced = Field(f; indices)
                    @test size(f_view) == field_sz
                    @test size(parent(f_view)) == parent_sz
                end
            end

            grid = RectilinearGrid(arch, FT, size=N, extent=L, halo=H, topology=(Periodic, Periodic, Periodic))
            for side in (:east, :west, :north, :south, :top, :bottom)
                for wrong_bc in (ValueBoundaryCondition(0),
                                 FluxBoundaryCondition(0),
                                 GradientBoundaryCondition(0))

                    wrong_kw = Dict(side => wrong_bc)
                    wrong_bcs = FieldBoundaryConditions(grid, (Center(), Center(), Center()); wrong_kw...)
                    @test_throws ArgumentError CenterField(grid, boundary_conditions=wrong_bcs)
                end
            end

            grid = RectilinearGrid(arch, FT, size=N[2:3], extent=L[2:3], halo=H[2:3], topology=(Flat, Periodic, Periodic))
            for side in (:east, :west)
                for wrong_bc in (ValueBoundaryCondition(0),
                                 FluxBoundaryCondition(0),
                                 GradientBoundaryCondition(0))

                    wrong_kw = Dict(side => wrong_bc)
                    wrong_bcs = FieldBoundaryConditions(grid, (Center(), Center(), Center()); wrong_kw...)
                    @test_throws ArgumentError CenterField(grid, boundary_conditions=wrong_bcs)
                end
            end

            grid = RectilinearGrid(arch, FT, size=N, extent=L, halo=H, topology=(Periodic, Bounded, Bounded))
            for side in (:east, :west, :north, :south)
                for wrong_bc in (ValueBoundaryCondition(0),
                                 FluxBoundaryCondition(0),
                                 GradientBoundaryCondition(0))

                    wrong_kw = Dict(side => wrong_bc)
                    wrong_bcs = FieldBoundaryConditions(grid, (Center(), Face(), Face()); wrong_kw...)

                    @test_throws ArgumentError Field{Center, Face, Face}(grid, boundary_conditions=wrong_bcs)
                end
            end

            if arch isa GPU
                wrong_bcs = FieldBoundaryConditions(grid, (Center(), Center(), Center()),
                                                    top=FluxBoundaryCondition(zeros(FT, N[1], N[2])))
                @test_throws ArgumentError CenterField(grid, boundary_conditions=wrong_bcs)
            end
        end
    end

    @testset "Setting fields" begin
        @info "  Testing field setting..."

        FieldTypes = (CenterField, XFaceField, YFaceField, ZFaceField)

        N = (4, 6, 8)
        L = (2π, 3π, 5π)
        H = (1, 1, 1)

        int_vals = Any[0, Int8(-1), Int16(2), Int32(-3), Int64(4)]
        uint_vals = Any[6, UInt8(7), UInt16(8), UInt32(9), UInt64(10)]
        float_vals = Any[0.0, -0.0, 6e-34, 1.0f10]
        rational_vals = Any[1//11, -23//7]
        other_vals = Any[π]
        vals = vcat(int_vals, uint_vals, float_vals, rational_vals, other_vals)

        for arch in archs, FT in float_types
            ArrayType = array_type(arch)
            grid = RectilinearGrid(arch, FT, size=N, extent=L, topology=(Periodic, Periodic, Bounded))

            for FieldType in FieldTypes, val in vals
                @test correct_field_value_was_set(grid, FieldType, val)
            end

            for loc in ((Center, Center, Center),
                        (Face, Center, Center),
                        (Center, Face, Center),
                        (Center, Center, Face),
                        (Nothing, Center, Center),
                        (Center, Nothing, Center),
                        (Center, Center, Nothing),
                        (Nothing, Nothing, Center),
                        (Nothing, Nothing, Nothing))

                field = Field(instantiate(loc), grid)
                sz = size(field)
                A = rand(FT, sz...)
                set!(field, A)
                @test @allowscalar field.data[1, 1, 1] == A[1, 1, 1]
            end

            Nx = 8
            topo = (Bounded, Bounded, Bounded)
            grid = RectilinearGrid(arch, FT, topology=topo, size=(Nx, Nx, Nx), x=(-1, 1), y=(0, 2π), z=(-1, 1))

            u = XFaceField(grid)
            v = YFaceField(grid)
            w = ZFaceField(grid)
            c = CenterField(grid)

            f(x, y, z) = exp(x) * sin(y) * tanh(z)

            ϕs = (u, v, w, c)
            [set!(ϕ, f) for ϕ in ϕs]

            xu, yu, zu = nodes(u)
            xv, yv, zv = nodes(v)
            xw, yw, zw = nodes(w)
            xc, yc, zc = nodes(c)

            @test @allowscalar u[1, 2, 3] ≈ f(xu[1], yu[2], zu[3])
            @test @allowscalar v[1, 2, 3] ≈ f(xv[1], yv[2], zv[3])
            @test @allowscalar w[1, 2, 3] ≈ f(xw[1], yw[2], zw[3])
            @test @allowscalar c[1, 2, 3] ≈ f(xc[1], yc[2], zc[3])

            # Test for Field-to-Field setting on same architecture, and cross architecture.
            # The behavior depends on halo size: if the halos of two fields are the same, we can
            # (easily) copy halo data over.
            # Otherwise, we take the easy way out (for now) and only copy interior data.
            big_halo = (3, 3, 3)
            small_halo = (1, 1, 1)
            domain = (; x=(0, 1), y=(0, 1), z=(0, 1))
            sz = (3, 3, 3)

            grid = RectilinearGrid(arch, FT; halo=big_halo, size=sz, domain...)
            a = CenterField(grid)
            b = CenterField(grid)
            parent(a) .= 1
            set!(b, a)
            @test parent(b) == parent(a)

            grid_with_smaller_halo = RectilinearGrid(arch, FT; halo=small_halo, size=sz, domain...)
            c = CenterField(grid_with_smaller_halo)
            set!(c, a)
            @test interior(c) == interior(a)

            # Cross-architecture setting should have similar behavior
            if arch isa GPU
                cpu_grid = RectilinearGrid(CPU(), FT; halo=big_halo, size=sz, domain...)
                d = CenterField(cpu_grid)
                set!(d, a)
                @test parent(d) == Array(parent(a))

                cpu_grid_with_smaller_halo = RectilinearGrid(CPU(), FT; halo=small_halo, size=sz, domain...)
                e = CenterField(cpu_grid_with_smaller_halo)
                set!(e, a)
                @test Array(interior(e)) == Array(interior((a)))
            end
        end
    end

    @testset "Field reductions" begin
        @info "  Testing field reductions..."

        for arch in archs, FT in float_types
            run_field_reduction_tests(FT, arch)
        end

        for arch in archs, FT in float_types
            @info "    Test reductions on WindowedFields [$(typeof(arch)), $FT]..."

            grid = RectilinearGrid(arch, FT, size=(2, 3, 4), x=(0, 1), y=(0, 1), z=(0, 1))
            c = CenterField(grid)
            Random.seed!(42)
            set!(c, rand(size(c)...))

            windowed_c = view(c, :, 2:3, 1:2)

            for fun in (sum, maximum, minimum)
                @test fun(c) ≈ fun(interior(c))
                @test fun(windowed_c) ≈ fun(interior(windowed_c))
            end

            @test mean(c) ≈ @allowscalar mean(interior(c))
            @test mean(windowed_c) ≈ @allowscalar mean(interior(windowed_c))
        end
    end

    @testset "Unit interpolation" begin
        for arch in archs
            hu = (-1, 1)
            hs = range(-1, 1, length=21)
            zu = (-100, 0)
            zs = range(-100, 0, length=33)

            for latitude in (hu, hs), longitude in (hu, hs), z in (zu, zs), loc in (Center(), Face())
                @info "    Testing interpolation for $(latitude) latitude and longitude, $(z) z on $(typeof(loc))s..."
                grid = LatitudeLongitudeGrid(arch; size = (20, 20, 32), longitude, latitude, z, halo = (5, 5, 5))

                # Test random positions,
                # set seed for reproducibility
                Random.seed!(1234)
                Xs = [(2rand()-1, 2rand()-1, -100rand()) for p in 1:20]

                for X in Xs
                    (x, y, z)  = X
                    fi = @allowscalar FractionalIndices(X, grid, loc, loc, loc)

                    i⁻, i⁺, _ = interpolator(fi.i)
                    j⁻, j⁺, _ = interpolator(fi.j)
                    k⁻, k⁺, _ = interpolator(fi.k)

                    x⁻ = @allowscalar ξnode(i⁻, j⁻, k⁻, grid, loc, loc, loc)
                    y⁻ = @allowscalar ηnode(i⁻, j⁻, k⁻, grid, loc, loc, loc)
                    z⁻ = @allowscalar rnode(i⁻, j⁻, k⁻, grid, loc, loc, loc)

                    x⁺ = @allowscalar ξnode(i⁺, j⁺, k⁺, grid, loc, loc, loc)
                    y⁺ = @allowscalar ηnode(i⁺, j⁺, k⁺, grid, loc, loc, loc)
                    z⁺ = @allowscalar rnode(i⁺, j⁺, k⁺, grid, loc, loc, loc)

                    @test x⁻ ≤ x ≤ x⁺
                    @test y⁻ ≤ y ≤ y⁺
                    @test z⁻ ≤ z ≤ z⁺
                end
            end
        end
    end

    @testset "Field interpolation" begin
        @info "  Testing field interpolation..."

        for arch in archs, FT in float_types
            reg_grid = RectilinearGrid(arch, FT, size=(4, 5, 7), x=(0, 1), y=(-π, π), z=(-5.3, 2.7), halo=(1, 1, 1))

            # Choose points z points to be rounded values of `reg_grid` z nodes so that interpolation matches tolerance
            stretched_grid = RectilinearGrid(arch,
                                             size = (4, 5, 7),
                                             halo = (1, 1, 1),
                                             x = [0.0, 0.26, 0.49, 0.78, 1.0],
                                             y = [-3.1, -1.9, -0.6, 0.6, 1.9, 3.1],
                                             z = [-5.3, -4.2, -3.0, -1.9, -0.7, 0.4, 1.6, 2.7])

            grids = [reg_grid, stretched_grid]

            for grid in grids
                run_field_interpolation_tests(grid)
            end
        end
    end

    @testset "Field utils" begin
        @info "  Testing field utils..."

        @test has_velocities(()) == false
        @test has_velocities((:u,)) == false
        @test has_velocities((:u, :v)) == false
        @test has_velocities((:u, :v, :w)) == true

        @info "    Testing similar(f) for f::Union(Field, ReducedField)..."

        grid = RectilinearGrid(CPU(), size=(1, 1, 1), extent=(1, 1, 1))

        for X in (Center, Face), Y in (Center, Face), Z in (Center, Face)
            for arch in archs
                f = Field{X, Y, Z}(grid)
                run_similar_field_tests(f)

                for dims in (3, (1, 2), (1, 2, 3))
                    loc = reduced_location((X(), Y(), Z()); dims)
                    f = Field(loc, grid)
                    run_similar_field_tests(f)
                end
            end
        end
    end

    @testset "Views of field views" begin
        @info "  Testing views of field views..."

        Nx, Ny, Nz = 1, 1, 7

        FieldTypes = (CenterField, XFaceField, YFaceField, ZFaceField)
        ZTopologies = (Periodic, Bounded)

        for arch in archs, FT in float_types, FieldType in FieldTypes, ZTopology in ZTopologies
            grid = RectilinearGrid(arch, FT, size=(Nx, Ny, Nz), x=(0, 1), y=(0, 1), z=(0, 1), topology = (Periodic, Periodic, ZTopology))
            Hx, Hy, Hz = halo_size(grid)

            c = FieldType(grid)
            set!(c, (x, y, z) -> rand())

            k_top = total_length(location(c, 3)(), topology(c, 3)(), size(grid, 3))

            # First test that the regular view is correct
            cv = view(c, :, :, 1+1:k_top-1)
            @test size(cv) == (Nx, Ny, k_top-2)
            @test size(parent(cv)) == (Nx+2Hx, Ny+2Hy, k_top-2)
            @allowscalar @test all(cv[i, j, k] == c[i, j, k] for k in 1+1:k_top-1, j in 1:Ny, i in 1:Nx)

            # Now test the views of views
            cvv = view(cv, :, :, 1+2:k_top-2)
            @test size(cvv) == (Nx, Ny, k_top-4)
            @test size(parent(cvv)) == (Nx+2Hx, Ny+2Hy, k_top-4)
            @allowscalar @test all(cvv[i, j, k] == cv[i, j, k] for k in 1+2:k_top-2, j in 1:Ny, i in 1:Nx)

            cvvv = view(cvv, :, :, 1+3:k_top-3)
            @test size(cvvv) == (1, 1, k_top-6)
            @test size(parent(cvvv)) == (Nx+2Hx, Ny+2Hy, k_top-6)
            @allowscalar @test all(cvvv[i, j, k] == cvv[i, j, k] for k in 1+3:k_top-3, j in 1:Ny, i in 1:Nx)

            @test_throws ArgumentError view(cv, :, :, 1)
            @test_throws ArgumentError view(cv, :, :, k_top)
            @test_throws ArgumentError view(cvv, :, :, 1:1+1)
            @test_throws ArgumentError view(cvv, :, :, k_top-1:k_top)
            @test_throws ArgumentError view(cvvv, :, :, 1:1+2)
            @test_throws ArgumentError view(cvvv, :, :, k_top-2:k_top)

            @test_throws BoundsError cv[:, :, 1]
            @test_throws BoundsError cv[:, :, k_top]
            @test_throws BoundsError cvv[:, :, 1:1+1]
            @test_throws BoundsError cvv[:, :, k_top-1:k_top]
            @test_throws BoundsError cvvv[:, :, 1:1+2]
            @test_throws BoundsError cvvv[:, :, k_top-2:k_top]
        end
    end
end
