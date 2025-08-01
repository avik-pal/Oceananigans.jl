include("dependencies_for_runtests.jl")
include("data_dependencies.jl")

using Oceananigans.Grids: φnode, λnode, halo_size
using Oceananigans.OrthogonalSphericalShellGrids: ConformalCubedSpherePanelGrid
using Oceananigans.Utils: Iterate, getregion
using Oceananigans.MultiRegion: number_of_regions, fill_halo_regions!

function get_range_of_indices(operation, index, Nx, Ny)
    if operation == :endpoint && index == :first
        range_x = 1
        range_y = 1
    elseif operation == :endpoint && index == :last
        range_x = Nx
        range_y = Ny
    elseif operation == :subset && index == :first # here index is the index to skip
        range_x = 2:Nx
        range_y = 2:Ny
    elseif operation == :subset && index == :last # here index is the index to skip
        range_x = 1:Nx-1
        range_y = 1:Ny-1
    else
        range_x = 1:Nx
        range_y = 1:Ny
    end

    return range_x, range_y
end

function get_halo_data(field, ::West, k_index=1; operation=nothing, index=:all)
    Nx, Ny, _ = size(field)
    Hx, Hy, _ = halo_size(field.grid)

    _, range_y = get_range_of_indices(operation, index, Nx, Ny)

    return field.data[-Hx+1:0, range_y, k_index]
end

function get_halo_data(field, ::East, k_index=1; operation=nothing, index=:all)
    Nx, Ny, _ = size(field)
    Hx, Hy, _ = halo_size(field.grid)

    _, range_y = get_range_of_indices(operation, index, Nx, Ny)

    return field.data[Nx+1:Nx+Hx, range_y, k_index]
end

function get_halo_data(field, ::North, k_index=1; operation=nothing, index=:all)
    Nx, Ny, _ = size(field)
    Hx, Hy, _ = halo_size(field.grid)

    range_x, _ = get_range_of_indices(operation, index, Nx, Ny)

    return field.data[range_x, Ny+1:Ny+Hy, k_index]
end

function get_halo_data(field, ::South, k_index=1; operation=nothing, index=:all)
    Nx, Ny, _ = size(field)
    Hx, Hy, _ = halo_size(field.grid)

    range_x, _ = get_range_of_indices(operation, index, Nx, Ny)

    return field.data[range_x, -Hy+1:0, k_index]
end

function get_boundary_indices(Nx, Ny, Hx, Hy, ::West; operation=nothing, index=:all)
    _, range_y = get_range_of_indices(operation, index, Nx, Ny)

    return 1:Hx, range_y
end

function get_boundary_indices(Nx, Ny, Hx, Hy, ::South; operation=nothing, index=:all)
    range_x, _ = get_range_of_indices(operation, index, Nx, Ny)

    return range_x, 1:Hy
end

function get_boundary_indices(Nx, Ny, Hx, Hy, ::East; operation=nothing, index=:all)
    _, range_y = get_range_of_indices(operation, index, Nx, Ny)

    return Nx-Hx+1:Nx, range_y
end

function get_boundary_indices(Nx, Ny, Hx, Hy, ::North; operation=nothing, index=:all)
    range_x, _ = get_range_of_indices(operation, index, Nx, Ny)

    return range_x, Ny-Hy+1:Ny
end

# Solid body rotation
R = 1        # sphere's radius
U = 1        # velocity scale
φʳ = 0       # Latitude pierced by the axis of rotation
α  = 90 - φʳ # Angle between axis of rotation and north pole (degrees)
ψᵣ(λ, φ, z) = - U * R * (sind(φ) * cosd(α) - cosd(λ) * cosd(φ) * sind(α))

"""
    create_test_data(grid, region)

Create an array with integer values of the form, e.g., 541 corresponding to region=5, i=4, j=2.
If `trailing_zeros > 0` then all values are multiplied with `10^trailing_zeros`, e.g., for
`trailing_zeros = 2` we have that 54100 corresponds to region=5, i=4, j=2.
"""
function create_test_data(grid, region; trailing_zeros=0)
    Nx, Ny, Nz = size(grid)
    (Nx > 9 || Ny > 9) && error("you provided (Nx, Ny) = ($Nx, $Ny); use a grid with Nx, Ny ≤ 9.")
    !(trailing_zeros isa Integer) && error("trailing_zeros has to be an integer")
    factor = 10^(trailing_zeros)

    return factor .* [100region + 10i + j for i in 1:Nx, j in 1:Ny, k in 1:Nz]
end

create_c_test_data(grid, region) = create_test_data(grid, region; trailing_zeros=0)
create_ψ_test_data(grid, region) = create_test_data(grid, region; trailing_zeros=1)

create_u_test_data(grid, region) = create_test_data(grid, region; trailing_zeros=2)
create_v_test_data(grid, region) = create_test_data(grid, region; trailing_zeros=3)

"""
    same_longitude_at_poles!(grid_1, grid_2)

Change the longitude values in `grid_1` that correspond to points situated _exactly_
at the poles so that they match the corresponding longitude values of `grid_2`.
"""
function same_longitude_at_poles!(grid_1::ConformalCubedSphereGrid, grid_2::ConformalCubedSphereGrid)
    number_of_regions(grid_1) == number_of_regions(grid_2) || error("grid_1 and grid_2 must have same number of regions")

    for region in 1:number_of_regions(grid_1)
        grid_1[region].λᶠᶠᵃ[grid_2[region].φᶠᶠᵃ .== +90]= grid_2[region].λᶠᶠᵃ[grid_2[region].φᶠᶠᵃ .== +90]
        grid_1[region].λᶠᶠᵃ[grid_2[region].φᶠᶠᵃ .== -90]= grid_2[region].λᶠᶠᵃ[grid_2[region].φᶠᶠᵃ .== -90]
    end

    return nothing
end

"""
    zero_out_corner_halos!(array::OffsetArray, N, H)

Zero out the values at the corner halo regions of the two-dimensional `array`.
It is expected that the interior of the offset `array` is `(Nx, Ny) = (N, N)` and
the halo region is `H` in both dimensions.
"""
function zero_out_corner_halos!(array::OffsetArray, N, H)
    size(array) == (N+2H, N+2H)

    Nx = Ny = N
    Hx = Hy = H

    array[-Hx+1:0, -Hy+1:0] .= 0
    array[-Hx+1:0, Ny+1:Ny+Hy] .= 0
    array[Nx+1:Nx+Hx, -Hy+1:0] .= 0
    array[Nx+1:Nx+Hx, Ny+1:Ny+Hy] .= 0

    return nothing
end

function compare_grid_vars(var1, var2, N, H)
    zero_out_corner_halos!(var1, N, H)
    zero_out_corner_halos!(var2, N, H)
    return isapprox(var1, var2)
end

@testset "Testing conformal cubed sphere partitions..." begin
    for n = 1:4
        @test length(CubedSpherePartition(; R=n)) == 6n^2
    end
end

@testset "Testing conformal cubed sphere grid from file" begin
    Nz = 1
    z = (-1, 0)

    cs32_filepath = datadep"cubed_sphere_32_grid/cubed_sphere_32_grid_with_4_halos.jld2"

    for panel in 1:6
        grid = ConformalCubedSpherePanelGrid(cs32_filepath; panel, Nz, z)
        @test grid isa OrthogonalSphericalShellGrid
    end

    for arch in archs
        @info "  Testing conformal cubed sphere grid from file [$(typeof(arch))]..."

        # read cs32 grid from file
        grid_cs32 = ConformalCubedSphereGrid(cs32_filepath, arch; Nz, z)

        radius = first(grid_cs32).radius
        Nx, Ny, Nz = size(grid_cs32)
        Hx, Hy, Hz = halo_size(grid_cs32)

        Nx !== Ny && error("Nx must be same as Ny")
        N = Nx
        Hx !== Hy && error("Hx must be same as Hy")
        H = Hy

        # construct a ConformalCubedSphereGrid similar to cs32
        grid = ConformalCubedSphereGrid(arch; z, panel_size=(Nx, Ny, Nz), radius,
                                        horizontal_direction_halo = Hx, z_halo = Hz)

        for panel in 1:6
            @allowscalar begin
                # Test only on cca and ffa; fca and cfa are all zeros on grid_cs32!
                # Only test interior points since halo regions are not filled for grid_cs32!

                @test compare_grid_vars(getregion(grid, panel).φᶜᶜᵃ, getregion(grid_cs32, panel).φᶜᶜᵃ, N, H)
                @test compare_grid_vars(getregion(grid, panel).λᶜᶜᵃ, getregion(grid_cs32, panel).λᶜᶜᵃ, N, H)

                # before we test, make sure we don't consider +180 and -180 longitudes as being "different"
                getregion(grid, panel).λᶠᶠᵃ[getregion(grid, panel).λᶠᶠᵃ .≈ -180] .= 180

                # and if poles are included, they have the same longitude.
                same_longitude_at_poles!(grid, grid_cs32)

                @test compare_grid_vars(getregion(grid, panel).φᶠᶠᵃ, getregion(grid_cs32, panel).φᶠᶠᵃ, N, H)
                @test compare_grid_vars(getregion(grid, panel).λᶠᶠᵃ, getregion(grid_cs32, panel).λᶠᶠᵃ, N, H)

                @test compare_grid_vars(getregion(grid, panel).φᶠᶠᵃ, getregion(grid_cs32, panel).φᶠᶠᵃ, N, H)
                @test compare_grid_vars(getregion(grid, panel).λᶠᶠᵃ, getregion(grid_cs32, panel).λᶠᶠᵃ, N, H)
            end
        end
    end
end

panel_sizes = ((8, 8, 1), (9, 9, 2))

@testset "Testing area metrics" begin
    for FT in float_types
        for arch in archs
            for panel_size in panel_sizes
                Nx, Ny, Nz = panel_size

                grid = ConformalCubedSphereGrid(arch, FT; panel_size = (Nx, Ny, Nz), z = (0, 1), radius = 1)

                areaᶜᶜᵃ = areaᶠᶜᵃ = areaᶜᶠᵃ = areaᶠᶠᵃ = 0

                for region in 1:number_of_regions(grid)
                    @allowscalar begin
                        areaᶜᶜᵃ += sum(getregion(grid, region).Azᶜᶜᵃ[1:Nx, 1:Ny])
                        areaᶠᶜᵃ += sum(getregion(grid, region).Azᶠᶜᵃ[1:Nx, 1:Ny])
                        areaᶜᶠᵃ += sum(getregion(grid, region).Azᶜᶠᵃ[1:Nx, 1:Ny])
                        areaᶠᶠᵃ += sum(getregion(grid, region).Azᶠᶠᵃ[1:Nx, 1:Ny])
                    end
                end

                @test areaᶜᶜᵃ ≈ areaᶠᶜᵃ ≈ areaᶜᶠᵃ ≈ areaᶠᶠᵃ ≈ 4π * grid.radius^2
            end
        end
    end
end

@testset "Immersed cubed sphere construction" begin
    for FT in float_types
        for arch in archs
            Nx, Ny, Nz = 9, 9, 9

            @info "  Testing immersed cubed sphere grid [$FT, $(typeof(arch))]..."

            underlying_grid = ConformalCubedSphereGrid(arch, FT; panel_size = (Nx, Ny, Nz), z = (-1, 0), radius = 1)
            @inline bottom(x, y) = ifelse(abs(y) < 30, - 2, 0)
            immersed_grid = ImmersedBoundaryGrid(underlying_grid, GridFittedBottom(bottom); active_cells_map = true)

            # Test that the grid is constructed correctly
            for panel in 1:6
                grid = getregion(immersed_grid, panel)

                if panel == 3 || panel == 6 # North and South panels should be completely immersed
                    @test isempty(grid.interior_active_cells)
                else # Other panels should have some active cells
                    @test !isempty(grid.interior_active_cells)
                end
            end
        end
    end
end

@testset "Testing conformal cubed sphere fill halos for tracers" begin
    for FT in float_types
        for arch in archs
            @info "  Testing fill halos for tracers [$FT, $(typeof(arch))]..."

            Nx, Ny, Nz = 9, 9, 1

            underlying_grid = ConformalCubedSphereGrid(arch, FT; panel_size = (Nx, Ny, Nz), z = (0, 1), radius = 1,
                                                       horizontal_direction_halo = 3)
            @inline bottom(x, y) = ifelse(abs(y) < 30, - 2, 0)
            immersed_grid = ImmersedBoundaryGrid(underlying_grid, GridFittedBottom(bottom); active_cells_map = true)

            grids = (underlying_grid, immersed_grid)

            for grid in grids
                c = CenterField(grid)

                region = Iterate(1:6)
                @apply_regionally data = create_c_test_data(grid, region)
                set!(c, data)
                fill_halo_regions!(c)

                Hx, Hy, Hz = halo_size(c.grid)

                west_indices  = 1:Hx, 1:Ny
                south_indices = 1:Nx, 1:Hy
                east_indices  = Nx-Hx+1:Nx, 1:Ny
                north_indices = 1:Nx, Ny-Hy+1:Ny

                # Confirm that the tracer halos were filled according to connectivity described at ConformalCubedSphereGrid docstring.
                @allowscalar begin
                    switch_device!(grid, 1)
                    @test get_halo_data(getregion(c, 1), West())  == reverse(create_c_test_data(grid, 5)[north_indices...], dims=1)'
                    @test get_halo_data(getregion(c, 1), East())  ==         create_c_test_data(grid, 2)[west_indices...]
                    @test get_halo_data(getregion(c, 1), South()) ==         create_c_test_data(grid, 6)[north_indices...]
                    @test get_halo_data(getregion(c, 1), North()) == reverse(create_c_test_data(grid, 3)[west_indices...], dims=2)'

                    switch_device!(grid, 2)
                    @test get_halo_data(getregion(c, 2), West())  ==         create_c_test_data(grid, 1)[east_indices...]
                    @test get_halo_data(getregion(c, 2), East())  == reverse(create_c_test_data(grid, 4)[south_indices...], dims=1)'
                    @test get_halo_data(getregion(c, 2), South()) == reverse(create_c_test_data(grid, 6)[east_indices...], dims=2)'
                    @test get_halo_data(getregion(c, 2), North()) ==         create_c_test_data(grid, 3)[south_indices...]

                    switch_device!(grid, 3)
                    @test get_halo_data(getregion(c, 3), West())  == reverse(create_c_test_data(grid, 1)[north_indices...], dims=1)'
                    @test get_halo_data(getregion(c, 3), East())  ==         create_c_test_data(grid, 4)[west_indices...]
                    @test get_halo_data(getregion(c, 3), South()) ==         create_c_test_data(grid, 2)[north_indices...]
                    @test get_halo_data(getregion(c, 3), North()) == reverse(create_c_test_data(grid, 5)[west_indices...], dims=2)'

                    switch_device!(grid, 4)
                    @test get_halo_data(getregion(c, 4), West())  ==         create_c_test_data(grid, 3)[east_indices...]
                    @test get_halo_data(getregion(c, 4), East())  == reverse(create_c_test_data(grid, 6)[south_indices...], dims=1)'
                    @test get_halo_data(getregion(c, 4), South()) == reverse(create_c_test_data(grid, 2)[east_indices...], dims=2)'
                    @test get_halo_data(getregion(c, 4), North()) ==         create_c_test_data(grid, 5)[south_indices...]

                    switch_device!(grid, 5)
                    @test get_halo_data(getregion(c, 5), West())  == reverse(create_c_test_data(grid, 3)[north_indices...], dims=1)'
                    @test get_halo_data(getregion(c, 5), East())  ==         create_c_test_data(grid, 6)[west_indices...]
                    @test get_halo_data(getregion(c, 5), South()) ==         create_c_test_data(grid, 4)[north_indices...]
                    @test get_halo_data(getregion(c, 5), North()) == reverse(create_c_test_data(grid, 1)[west_indices...], dims=2)'

                    switch_device!(grid, 6)
                    @test get_halo_data(getregion(c, 6), West())  ==         create_c_test_data(grid, 5)[east_indices...]
                    @test get_halo_data(getregion(c, 6), East())  == reverse(create_c_test_data(grid, 2)[south_indices...], dims=1)'
                    @test get_halo_data(getregion(c, 6), South()) == reverse(create_c_test_data(grid, 4)[east_indices...], dims=2)'
                    @test get_halo_data(getregion(c, 6), North()) ==         create_c_test_data(grid, 1)[south_indices...]
                end # CUDA.@allowscalar
            end
        end
    end
end

@testset "Testing conformal cubed sphere fill halos for horizontal velocities" begin
    for FT in float_types
        for arch in archs
            @info "  Testing fill halos for horizontal velocities [$FT, $(typeof(arch))]..."

            Nx, Ny, Nz = 9, 9, 1

            underlying_grid = ConformalCubedSphereGrid(arch, FT; panel_size = (Nx, Ny, Nz), z = (0, 1), radius = 1,
                                                       horizontal_direction_halo = 3)
            @inline bottom(x, y) = ifelse(abs(y) < 30, - 2, 0)
            immersed_grid = ImmersedBoundaryGrid(underlying_grid, GridFittedBottom(bottom); active_cells_map = true)

            grids = (underlying_grid, immersed_grid)

            for grid in grids
                u = XFaceField(grid)
                v = YFaceField(grid)

                region = Iterate(1:6)
                @apply_regionally u_data = create_u_test_data(grid, region)
                @apply_regionally v_data = create_v_test_data(grid, region)
                set!(u, u_data)
                set!(v, v_data)

                fill_halo_regions!((u, v); signed = true)

                Hx, Hy, Hz = halo_size(u.grid)

                south_indices = get_boundary_indices(Nx, Ny, Hx, Hy, South(); operation=nothing, index=:all)
                east_indices  = get_boundary_indices(Nx, Ny, Hx, Hy, East();  operation=nothing, index=:all)
                north_indices = get_boundary_indices(Nx, Ny, Hx, Hy, North(); operation=nothing, index=:all)
                west_indices  = get_boundary_indices(Nx, Ny, Hx, Hy, West();  operation=nothing, index=:all)

                south_indices_first = get_boundary_indices(Nx, Ny, Hx, Hy, South(); operation=:endpoint, index=:first)
                south_indices_last  = get_boundary_indices(Nx, Ny, Hx, Hy, South(); operation=:endpoint, index=:last)
                east_indices_first  = get_boundary_indices(Nx, Ny, Hx, Hy, East();  operation=:endpoint, index=:first)
                east_indices_last   = get_boundary_indices(Nx, Ny, Hx, Hy, East();  operation=:endpoint, index=:last)
                north_indices_first = get_boundary_indices(Nx, Ny, Hx, Hy, North(); operation=:endpoint, index=:first)
                north_indices_last  = get_boundary_indices(Nx, Ny, Hx, Hy, North(); operation=:endpoint, index=:last)
                west_indices_first  = get_boundary_indices(Nx, Ny, Hx, Hy, West();  operation=:endpoint, index=:first)
                west_indices_last   = get_boundary_indices(Nx, Ny, Hx, Hy, West();  operation=:endpoint, index=:last)

                south_indices_subset_skip_first_index = get_boundary_indices(Nx, Ny, Hx, Hy, South(); operation=:subset, index=:first)
                south_indices_subset_skip_last_index  = get_boundary_indices(Nx, Ny, Hx, Hy, South(); operation=:subset, index=:last)
                east_indices_subset_skip_first_index  = get_boundary_indices(Nx, Ny, Hx, Hy, East();  operation=:subset, index=:first)
                east_indices_subset_skip_last_index   = get_boundary_indices(Nx, Ny, Hx, Hy, East();  operation=:subset, index=:last)
                north_indices_subset_skip_first_index = get_boundary_indices(Nx, Ny, Hx, Hy, North(); operation=:subset, index=:first)
                north_indices_subset_skip_last_index  = get_boundary_indices(Nx, Ny, Hx, Hy, North(); operation=:subset, index=:last)
                west_indices_subset_skip_first_index  = get_boundary_indices(Nx, Ny, Hx, Hy, West();  operation=:subset, index=:first)
                west_indices_subset_skip_last_index   = get_boundary_indices(Nx, Ny, Hx, Hy, West();  operation=:subset, index=:last)

                # Confirm that the zonal velocity halos were filled according to connectivity described at ConformalCubedSphereGrid docstring.
                @allowscalar begin
                    switch_device!(grid, 1)

                    # Trivial halo checks with no off-set in index
                    @test get_halo_data(getregion(u, 1), West())  == reverse(create_v_test_data(grid, 5)[north_indices...], dims=1)'
                    @test get_halo_data(getregion(u, 1), East())  ==         create_u_test_data(grid, 2)[west_indices...]
                    @test get_halo_data(getregion(u, 1), South()) ==         create_u_test_data(grid, 6)[north_indices...]

                    # Non-trivial halo checks with off-set in index
                    @test get_halo_data(getregion(u, 1), North();
                                        operation=:subset,
                                        index=:first) == - reverse(create_v_test_data(grid, 3)[west_indices_subset_skip_first_index...], dims=2)'
                    # The index appearing on the LHS above is the index to be skipped.
                    @test get_halo_data(getregion(u, 1), North();
                                        operation=:endpoint,
                                        index=:first) == - reverse(create_u_test_data(grid, 5)[north_indices_first...])

                    switch_device!(grid, 2)

                    # Trivial halo checks with no off-set in index
                    @test get_halo_data(getregion(u, 2), West())  ==         create_u_test_data(grid, 1)[east_indices...]
                    @test get_halo_data(getregion(u, 2), East())  == reverse(create_v_test_data(grid, 4)[south_indices...], dims=1)'
                    @test get_halo_data(getregion(u, 2), North()) ==         create_u_test_data(grid, 3)[south_indices...]

                    # Non-trivial halo checks with off-set in index
                    @test get_halo_data(getregion(u, 2), South();
                                        operation=:subset,
                                        index=:first) == - reverse(create_v_test_data(grid, 6)[east_indices_subset_skip_first_index...], dims=2)'
                    # The index appearing on the LHS above is the index to be skipped.
                    @test get_halo_data(getregion(u, 2), South();
                                        operation=:endpoint,
                                        index=:first) == - create_v_test_data(grid, 1)[east_indices_first...]

                    switch_device!(grid, 3)

                    # Trivial halo checks with no off-set in index
                    @test get_halo_data(getregion(u, 3), West())  == reverse(create_v_test_data(grid, 1)[north_indices...], dims=1)'
                    @test get_halo_data(getregion(u, 3), East())  ==         create_u_test_data(grid, 4)[west_indices...]
                    @test get_halo_data(getregion(u, 3), South()) ==         create_u_test_data(grid, 2)[north_indices...]

                    # Non-trivial halo checks with off-set in index
                    @test get_halo_data(getregion(u, 3), North();
                                        operation=:subset,
                                        index=:first) == - reverse(create_v_test_data(grid, 5)[west_indices_subset_skip_first_index...], dims=2)'
                    # The index appearing on the LHS above is the index to be skipped.
                    @test get_halo_data(getregion(u, 3), North();
                                        operation=:endpoint,
                                        index=:first) == - reverse(create_u_test_data(grid, 1)[north_indices_first...])

                    switch_device!(grid, 4)

                    # Trivial halo checks with no off-set in index
                    @test get_halo_data(getregion(u, 4), West())  ==         create_u_test_data(grid, 3)[east_indices...]
                    @test get_halo_data(getregion(u, 4), East())  == reverse(create_v_test_data(grid, 6)[south_indices...], dims=1)'
                    @test get_halo_data(getregion(u, 4), North()) ==         create_u_test_data(grid, 5)[south_indices...]

                    # Non-trivial halo checks with off-set in index
                    @test get_halo_data(getregion(u, 4), South();
                                        operation=:subset,
                                        index=:first) == - reverse(create_v_test_data(grid, 2)[east_indices_subset_skip_first_index...], dims=2)'
                    # The index appearing on the LHS above is the index to be skipped.
                    @test get_halo_data(getregion(u, 4), South();
                                        operation=:endpoint,
                                        index=:first) == - create_v_test_data(grid, 3)[east_indices_first...]

                    switch_device!(grid, 5)

                    # Trivial halo checks with no off-set in index
                    @test get_halo_data(getregion(u, 5), West())  == reverse(create_v_test_data(grid, 3)[north_indices...], dims=1)'
                    @test get_halo_data(getregion(u, 5), East())  ==         create_u_test_data(grid, 6)[west_indices...]
                    @test get_halo_data(getregion(u, 5), South()) ==         create_u_test_data(grid, 4)[north_indices...]

                    # Non-trivial halo checks with off-set in index
                    @test get_halo_data(getregion(u, 5), North();
                                        operation=:subset,
                                        index=:first) == - reverse(create_v_test_data(grid, 1)[west_indices_subset_skip_first_index...], dims=2)'
                    # The index appearing on the LHS above is the index to be skipped.
                    @test get_halo_data(getregion(u, 5), North();
                                        operation=:endpoint,
                                        index=:first) == - reverse(create_u_test_data(grid, 3)[north_indices_first...])

                    switch_device!(grid, 6)

                    # Trivial halo checks with no off-set in index
                    @test get_halo_data(getregion(u, 6), West())  ==         create_u_test_data(grid, 5)[east_indices...]
                    @test get_halo_data(getregion(u, 6), East())  == reverse(create_v_test_data(grid, 2)[south_indices...], dims=1)'
                    @test get_halo_data(getregion(u, 6), North()) ==         create_u_test_data(grid, 1)[south_indices...]

                    # Non-trivial halo checks with off-set in index
                    @test get_halo_data(getregion(u, 6), South();
                                        operation=:subset,
                                        index=:first) == - reverse(create_v_test_data(grid, 4)[east_indices_subset_skip_first_index...], dims=2)'
                    # The index appearing on the LHS above is the index to be skipped.
                    @test get_halo_data(getregion(u, 6), South();
                                        operation=:endpoint,
                                        index=:first) == - create_v_test_data(grid, 5)[east_indices_first...]
                end # CUDA.@allowscalar

                # Confirm that the meridional velocity halos were filled according to connectivity described at
                # ConformalCubedSphereGrid docstring.
                @allowscalar begin
                    switch_device!(grid, 1)

                    # Trivial halo checks with no off-set in index
                    @test get_halo_data(getregion(v, 1), East())  ==         create_v_test_data(grid, 2)[west_indices...]
                    @test get_halo_data(getregion(v, 1), South()) ==         create_v_test_data(grid, 6)[north_indices...]
                    @test get_halo_data(getregion(v, 1), North()) == reverse(create_u_test_data(grid, 3)[west_indices...], dims=2)'

                    # Non-trivial halo checks with off-set in index
                    @test get_halo_data(getregion(v, 1), West();
                                        operation=:subset,
                                        index=:first) == - reverse(create_u_test_data(grid, 5)[north_indices_subset_skip_first_index...], dims=1)'
                    # The index appearing on the LHS above is the index to be skipped.
                    @test get_halo_data(getregion(v, 1), West();
                                        operation=:endpoint,
                                        index=:first) == - create_u_test_data(grid, 6)[north_indices_first...]

                    switch_device!(grid, 2)

                    # Trivial halo checks with no off-set in index
                    @test get_halo_data(getregion(v, 2), West())  ==         create_v_test_data(grid, 1)[east_indices...]
                    @test get_halo_data(getregion(v, 2), South()) == reverse(create_u_test_data(grid, 6)[east_indices...], dims=2)'
                    @test get_halo_data(getregion(v, 2), North()) ==         create_v_test_data(grid, 3)[south_indices...]

                    # Non-trivial halo checks with off-set in index
                    @test get_halo_data(getregion(v, 2), East();
                                        operation=:subset,
                                        index=:first) == - reverse(create_u_test_data(grid, 4)[south_indices_subset_skip_first_index...], dims=1)'
                    # The index appearing on the LHS above is the index to be skipped.
                    @test get_halo_data(getregion(v, 2), East();
                                        operation=:endpoint,
                                        index=:first) == - reverse(create_v_test_data(grid, 6)[east_indices_first...])

                    switch_device!(grid, 3)

                    # Trivial halo checks with no off-set in index
                    @test get_halo_data(getregion(v, 3), East())  ==         create_v_test_data(grid, 4)[west_indices...]
                    @test get_halo_data(getregion(v, 3), South()) ==         create_v_test_data(grid, 2)[north_indices...]
                    @test get_halo_data(getregion(v, 3), North()) == reverse(create_u_test_data(grid, 5)[west_indices...], dims=2)'

                    # Non-trivial halo checks with off-set in index
                    @test get_halo_data(getregion(v, 3), West();
                                        operation=:subset,
                                        index=:first) == - reverse(create_u_test_data(grid, 1)[north_indices_subset_skip_first_index...], dims=1)'
                    # The index appearing on the LHS above is the index to be skipped.
                    @test get_halo_data(getregion(v, 3), West();
                                        operation=:endpoint,
                                        index=:first) == - create_u_test_data(grid, 2)[north_indices_first...]

                    switch_device!(grid, 4)

                    # Trivial halo checks with no off-set in index
                    @test get_halo_data(getregion(v, 4), West())  ==         create_v_test_data(grid, 3)[east_indices...]
                    @test get_halo_data(getregion(v, 4), South()) == reverse(create_u_test_data(grid, 2)[east_indices...], dims=2)'
                    @test get_halo_data(getregion(v, 4), North()) ==         create_v_test_data(grid, 5)[south_indices...]

                    # Non-trivial halo checks with off-set in index
                    @test get_halo_data(getregion(v, 4), East();
                                        operation=:subset,
                                        index=:first) == - reverse(create_u_test_data(grid, 6)[south_indices_subset_skip_first_index...], dims=1)'
                    # The index appearing on the LHS above is the index to be skipped.
                    @test get_halo_data(getregion(v, 4), East();
                                        operation=:endpoint,
                                        index=:first) == - reverse(create_v_test_data(grid, 2)[east_indices_first...])

                    switch_device!(grid, 5)

                    # Trivial halo checks with no off-set in index
                    @test get_halo_data(getregion(v, 5), East())  ==         create_v_test_data(grid, 6)[west_indices...]
                    @test get_halo_data(getregion(v, 5), South()) ==         create_v_test_data(grid, 4)[north_indices...]
                    @test get_halo_data(getregion(v, 5), North()) == reverse(create_u_test_data(grid, 1)[west_indices...], dims=2)'

                    # Non-trivial halo checks with off-set in index
                    @test get_halo_data(getregion(v, 5), West();
                                        operation=:subset,
                                        index=:first) == - reverse(create_u_test_data(grid, 3)[north_indices_subset_skip_first_index...], dims=1)'
                    # The index appearing on the LHS above is the index to be skipped.
                    @test get_halo_data(getregion(v, 5), West();
                                        operation=:endpoint,
                                        index=:first) == - create_u_test_data(grid, 4)[north_indices_first...]

                    switch_device!(grid, 6)

                    # Trivial halo checks with no off-set in index
                    @test get_halo_data(getregion(v, 6), West())  ==         create_v_test_data(grid, 5)[east_indices...]
                    @test get_halo_data(getregion(v, 6), South()) == reverse(create_u_test_data(grid, 4)[east_indices...], dims=2)'
                    @test get_halo_data(getregion(v, 6), North()) ==         create_v_test_data(grid, 1)[south_indices...]

                    # Non-trivial halo checks with off-set in index
                    @test get_halo_data(getregion(v, 6), East();
                                        operation=:subset,
                                        index=:first) == - reverse(create_u_test_data(grid, 2)[south_indices_subset_skip_first_index...], dims=1)'
                    # The index appearing on the LHS above is the index to be skipped.
                    @test get_halo_data(getregion(v, 6), East();
                                        operation=:endpoint,
                                        index=:first) == - reverse(create_v_test_data(grid, 4)[east_indices_first...])
                end # CUDA.@allowscalar
            end
        end
    end
end

@testset "Testing conformal cubed sphere fill halos for Face-Face-Any field" begin
    for FT in float_types
        for arch in archs
            @info "  Testing fill halos for streamfunction [$FT, $(typeof(arch))]..."

            Nx, Ny, Nz = 9, 9, 1

            grid = ConformalCubedSphereGrid(arch, FT; panel_size = (Nx, Ny, Nz), z = (0, 1), radius = 1, horizontal_direction_halo = 3)

            underlying_grid = ConformalCubedSphereGrid(arch, FT; panel_size = (Nx, Ny, Nz), z = (0, 1), radius = 1, horizontal_direction_halo = 3)
            @inline bottom(x, y) = ifelse(abs(y) < 30, - 2, 0)
            immersed_grid = ImmersedBoundaryGrid(underlying_grid, GridFittedBottom(bottom); active_cells_map = true)

            grids = (underlying_grid, immersed_grid)

            for grid in grids
                ψ = Field{Face, Face, Center}(grid)

                region = Iterate(1:6)
                @apply_regionally data = create_ψ_test_data(grid, region)
                set!(ψ, data)

                fill_halo_regions!(ψ)

                Hx, Hy, Hz = halo_size(ψ.grid)

                south_indices = get_boundary_indices(Nx, Ny, Hx, Hy, South(); operation=nothing, index=:all)
                east_indices  = get_boundary_indices(Nx, Ny, Hx, Hy, East();  operation=nothing, index=:all)
                north_indices = get_boundary_indices(Nx, Ny, Hx, Hy, North(); operation=nothing, index=:all)
                west_indices  = get_boundary_indices(Nx, Ny, Hx, Hy, West();  operation=nothing, index=:all)

                south_indices_first = get_boundary_indices(Nx, Ny, Hx, Hy, South(); operation=:endpoint, index=:first)
                south_indices_last  = get_boundary_indices(Nx, Ny, Hx, Hy, South(); operation=:endpoint, index=:last)
                east_indices_first  = get_boundary_indices(Nx, Ny, Hx, Hy, East();  operation=:endpoint, index=:first)
                east_indices_last   = get_boundary_indices(Nx, Ny, Hx, Hy, East();  operation=:endpoint, index=:last)
                north_indices_first = get_boundary_indices(Nx, Ny, Hx, Hy, North(); operation=:endpoint, index=:first)
                north_indices_last  = get_boundary_indices(Nx, Ny, Hx, Hy, North(); operation=:endpoint, index=:last)
                west_indices_first  = get_boundary_indices(Nx, Ny, Hx, Hy, West();  operation=:endpoint, index=:first)
                west_indices_last   = get_boundary_indices(Nx, Ny, Hx, Hy, West();  operation=:endpoint, index=:last)

                south_indices_subset_skip_first_index = get_boundary_indices(Nx, Ny, Hx, Hy, South(); operation=:subset, index=:first)
                south_indices_subset_skip_last_index  = get_boundary_indices(Nx, Ny, Hx, Hy, South(); operation=:subset, index=:last)
                east_indices_subset_skip_first_index  = get_boundary_indices(Nx, Ny, Hx, Hy, East();  operation=:subset, index=:first)
                east_indices_subset_skip_last_index   = get_boundary_indices(Nx, Ny, Hx, Hy, East();  operation=:subset, index=:last)
                north_indices_subset_skip_first_index = get_boundary_indices(Nx, Ny, Hx, Hy, North(); operation=:subset, index=:first)
                north_indices_subset_skip_last_index  = get_boundary_indices(Nx, Ny, Hx, Hy, North(); operation=:subset, index=:last)
                west_indices_subset_skip_first_index  = get_boundary_indices(Nx, Ny, Hx, Hy, West();  operation=:subset, index=:first)
                west_indices_subset_skip_last_index   = get_boundary_indices(Nx, Ny, Hx, Hy, West();  operation=:subset, index=:last)

                # Confirm that the tracer halos were filled according to connectivity described at ConformalCubedSphereGrid docstring.
                @allowscalar begin
                    # Panel 1
                    switch_device!(grid, 1)

                    # Trivial halo checks with no off-set in index
                    @test get_halo_data(getregion(ψ, 1), East())  == create_ψ_test_data(grid, 2)[west_indices...]
                    @test get_halo_data(getregion(ψ, 1), South()) == create_ψ_test_data(grid, 6)[north_indices...]

                    # Non-trivial halo checks with off-set in index
                    @test get_halo_data(getregion(ψ, 1), North();
                                        operation=:subset,
                                        index=:first) == reverse(create_ψ_test_data(grid, 3)[west_indices_subset_skip_first_index...], dims=2)'
                    # Currently we do not have any test for the point of intersection of the northwest (halo) corners of panels 1, 3, and 5.

                    # Non-trivial halo checks with off-set in index
                    @test get_halo_data(getregion(ψ, 1), West();
                                        operation=:subset,
                                        index=:first) == reverse(create_ψ_test_data(grid, 5)[north_indices_subset_skip_first_index...], dims=1)'
                    # The index appearing on the LHS above is the index to be skipped.
                    @test get_halo_data(getregion(ψ, 1), West();
                                        operation=:endpoint,
                                        index=:first) == create_ψ_test_data(grid, 6)[north_indices_first...]

                    switch_device!(grid, 2)
                    @test get_halo_data(getregion(ψ, 2), West())  == create_ψ_test_data(grid, 1)[east_indices...]
                    @test get_halo_data(getregion(ψ, 2), North()) == create_ψ_test_data(grid, 3)[south_indices...]

                    # Non-trivial halo checks with off-set in index
                    @test get_halo_data(getregion(ψ, 2), East();
                                        operation=:subset,
                                        index=:first) == reverse(create_ψ_test_data(grid, 4)[south_indices_subset_skip_first_index...], dims=1)'
                    # Currently we do not have any test for the point of intersection of the southeast (halo) corners of panels 2, 4, and 6.

                    # Non-trivial halo checks with off-set in index
                    @test get_halo_data(getregion(ψ, 2), South();
                                        operation=:subset,
                                        index=:first) == reverse(create_ψ_test_data(grid, 6)[east_indices_subset_skip_first_index...], dims=2)'
                    # The index appearing on the LHS above is the index to be skipped.
                    @test get_halo_data(getregion(ψ, 2), South();
                                        operation=:endpoint,
                                        index=:first) == create_ψ_test_data(grid, 1)[east_indices_first...]

                    switch_device!(grid, 3)
                    @test get_halo_data(getregion(ψ, 3), East())  == create_ψ_test_data(grid, 4)[west_indices...]
                    @test get_halo_data(getregion(ψ, 3), South()) == create_ψ_test_data(grid, 2)[north_indices...]

                    # Non-trivial halo checks with off-set in index
                    @test get_halo_data(getregion(ψ, 3), West();
                                        operation=:subset,
                                        index=:first) == reverse(create_ψ_test_data(grid, 1)[north_indices_subset_skip_first_index...], dims=1)'
                    # The index appearing on the LHS above is the index to be skipped.
                    @test get_halo_data(getregion(ψ, 3), West();
                                        operation=:endpoint,
                                        index=:first) == create_ψ_test_data(grid, 2)[north_indices_first...]

                    # Non-trivial halo checks with off-set in index
                    @test get_halo_data(getregion(ψ, 3), North();
                                        operation=:subset,
                                        index=:first) == reverse(create_ψ_test_data(grid, 5)[west_indices_subset_skip_first_index...], dims=2)'
                    # Currently we do not have any test for the point of intersection of the northwest (halo) corners of panels 1, 3, and 5.

                    switch_device!(grid, 4)
                    @test get_halo_data(getregion(ψ, 4), West())  == create_ψ_test_data(grid, 3)[east_indices...]
                    @test get_halo_data(getregion(ψ, 4), North()) == create_ψ_test_data(grid, 5)[south_indices...]

                    # Non-trivial halo checks with off-set in index
                    @test get_halo_data(getregion(ψ, 4), East();
                                        operation=:subset,
                                        index=:first) == reverse(create_ψ_test_data(grid, 6)[south_indices_subset_skip_first_index...], dims=1)'
                    # Currently we do not have any test for the point of intersection of the southeast (halo) corners of panels 2, 4, and 6.

                    # Non-trivial halo checks with off-set in index
                    @test get_halo_data(getregion(ψ, 4), South();
                                        operation=:subset,
                                        index=:first) == reverse(create_ψ_test_data(grid, 2)[east_indices_subset_skip_first_index...], dims=2)'
                    # The index appearing on the LHS above is the index to be skipped.
                    @test get_halo_data(getregion(ψ, 4), South();
                                        operation=:endpoint,
                                        index=:first) == create_ψ_test_data(grid, 3)[east_indices_first...]

                    switch_device!(grid, 5)
                    @test get_halo_data(getregion(ψ, 5), East())  == create_ψ_test_data(grid, 6)[west_indices...]
                    @test get_halo_data(getregion(ψ, 5), South()) == create_ψ_test_data(grid, 4)[north_indices...]

                    # Non-trivial halo checks with off-set in index
                    @test get_halo_data(getregion(ψ, 5), West();
                                        operation=:subset,
                                        index=:first) == reverse(create_ψ_test_data(grid, 3)[north_indices_subset_skip_first_index...], dims=1)'
                    # The index appearing on the LHS above is the index to be skipped.
                    @test get_halo_data(getregion(ψ, 5), West();
                                        operation=:endpoint,
                                        index=:first) == create_ψ_test_data(grid, 4)[north_indices_first...]

                    # Non-trivial halo checks with off-set in index
                    @test get_halo_data(getregion(ψ, 5), North();
                                        operation=:subset,
                                        index=:first) == reverse(create_ψ_test_data(grid, 1)[west_indices_subset_skip_first_index...], dims=2)'
                    # Currently we do not have any test for the point of intersection of the northwest (halo) corners of panels 1, 3, and 5.

                    switch_device!(grid, 6)
                    @test get_halo_data(getregion(ψ, 6), West())  == create_ψ_test_data(grid, 5)[east_indices...]
                    @test get_halo_data(getregion(ψ, 6), North()) == create_ψ_test_data(grid, 1)[south_indices...]

                    # Non-trivial halo checks with off-set in index
                    @test get_halo_data(getregion(ψ, 6), East();
                                        operation=:subset,
                                        index=:first) == reverse(create_ψ_test_data(grid, 2)[south_indices_subset_skip_first_index...], dims=1)'
                    # Currently we do not have any test for the point of intersection of the southeast (halo) corners of panels 2, 4, and 6.

                    # Non-trivial halo checks with off-set in index
                    @test get_halo_data(getregion(ψ, 6), South();
                                        operation=:subset,
                                        index=:first) == reverse(create_ψ_test_data(grid, 4)[east_indices_subset_skip_first_index...], dims=2)'

                    # The index appearing on the LHS above is the index to be skipped.
                    @test get_halo_data(getregion(ψ, 6), South();
                                        operation=:endpoint,
                                        index=:first) == create_ψ_test_data(grid, 5)[east_indices_first...]
                end # CUDA.@allowscalar
            end
        end
    end
end

@testset "Testing simulation on conformal and immersed conformal cubed sphere grids" begin
    for f in readdir(".")
        if occursin(r"^cubed_sphere_(output|checkpointer)_.*\.jld2$", f)
            rm(f; force=true)
        end
    end
    for FT in float_types
        for arch in archs
            Nx, Ny, Nz = 18, 18, 9

            underlying_grid = ConformalCubedSphereGrid(arch, FT; panel_size = (Nx, Ny, Nz), z = (0, 1), radius = 1,
                                                       horizontal_direction_halo = 6)
            @inline bottom(x, y) = ifelse(abs(y) < 30, - 2, 0)
            immersed_grid = ImmersedBoundaryGrid(underlying_grid, GridFittedBottom(bottom); active_cells_map = true)

            grids = (underlying_grid, immersed_grid)

            for grid in grids
                if grid == underlying_grid
                    @info "  Testing simulation on conformal cubed sphere grid [$FT, $(typeof(arch))]..."
                    suffix = "UG"
                else
                    @info "  Testing simulation on immersed boundary conformal cubed sphere grid [$FT, $(typeof(arch))]..."
                    suffix = "IG"
                end

                model = HydrostaticFreeSurfaceModel(; grid,
                                                    momentum_advection = WENOVectorInvariant(FT; order=5),
                                                    tracer_advection = WENO(FT; order=5),
                                                    free_surface = SplitExplicitFreeSurface(grid; substeps=12),
                                                    coriolis = HydrostaticSphericalCoriolis(FT),
                                                    tracers = :b,
                                                    buoyancy = BuoyancyTracer())

                simulation = Simulation(model, Δt=1minute, stop_time=10minutes)

                save_fields_interval = 2minute
                checkpointer_interval = 4minutes

                filename_checkpointer = "cubed_sphere_checkpointer_$(FT)_$(typeof(arch))_" * suffix
                simulation.output_writers[:checkpointer] = Checkpointer(model,
                                                                        schedule = TimeInterval(checkpointer_interval),
                                                                        prefix = filename_checkpointer,
                                                                        overwrite_existing = true)

                outputs = fields(model)
                filename_output_writer = "cubed_sphere_output_$(FT)_$(typeof(arch))_" * suffix
                simulation.output_writers[:fields] = JLD2Writer(model, outputs;
                                                                schedule = TimeInterval(save_fields_interval),
                                                                filename = filename_output_writer,
                                                                verbose = false,
                                                                overwrite_existing = true)

                run!(simulation)

                @test iteration(simulation) == 10
                @test time(simulation) == 10minutes

                u_timeseries = FieldTimeSeries(filename_output_writer * ".jld2", "u"; architecture = CPU())

                if grid == underlying_grid
                    @info "  Restarting simulation from pickup file on conformal cubed sphere grid [$FT, $(typeof(arch))]..."
                else
                    @info "  Restarting simulation from pickup file on immersed boundary conformal cubed sphere grid [$FT, $(typeof(arch))]..."
                end

                simulation = Simulation(model, Δt=1minute, stop_time=20minutes)

                simulation.output_writers[:checkpointer] = Checkpointer(model,
                                                                        schedule = TimeInterval(checkpointer_interval),
                                                                        prefix = filename_checkpointer,
                                                                        overwrite_existing = true)

                simulation.output_writers[:fields] = JLD2Writer(model, outputs;
                                                                schedule = TimeInterval(save_fields_interval),
                                                                filename = filename_output_writer,
                                                                verbose = false,
                                                                overwrite_existing = true)

                run!(simulation, pickup = true)

                @test iteration(simulation) == 20
                @test time(simulation) == 20minutes

                u_timeseries = FieldTimeSeries(filename_output_writer * ".jld2", "u"; architecture = CPU())
            end
        end
    end
end
