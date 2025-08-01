using MPI
using OffsetArrays
using Oceananigans.Utils: getnamewrapper
using Oceananigans.Grids: AbstractGrid, topology, size, halo_size, architecture, pop_flat_elements
using Oceananigans.Grids: validate_rectilinear_grid_args, validate_lat_lon_grid_args, validate_size
using Oceananigans.Grids: generate_coordinate, with_precomputed_metrics
using Oceananigans.Grids: cpu_face_constructor_x, cpu_face_constructor_y, cpu_face_constructor_z
using Oceananigans.Grids: R_Earth, metrics_precomputed

using Oceananigans.Fields

import Oceananigans.Grids: RectilinearGrid, LatitudeLongitudeGrid, with_halo

const DistributedGrid{FT, TX, TY, TZ} = Union{
    AbstractGrid{FT, TX, TY, TZ, <:Distributed{<:CPU}},
    AbstractGrid{FT, TX, TY, TZ, <:Distributed{<:GPU}},
}

const DistributedRectilinearGrid{FT, TX, TY, TZ, CZ, FX, FY, VX, VY} =
    RectilinearGrid{FT, TX, TY, TZ, CZ, FX, FY, VX, VY, <:Distributed}

const DistributedLatitudeLongitudeGrid{FT, TX, TY, TZ, Z,
                                       DXF, DXC, XF, XC,
                                       DYF, DYC, YF, YC,
                                       DXCC, DXFC, DXCF,
                                       DXFF, DYFC, DYCF} =
    LatitudeLongitudeGrid{FT, TX, TY, TZ, Z,
                          DXF, DXC, XF, XC,
                          DYF, DYC, YF, YC,
                          DXCC, DXFC, DXCF,
                          DXFF, DYFC, DYCF,
                          <:Distributed} where {FT, TX, TY, TZ, Z,
                                                DXF, DXC, XF, XC,
                                                DYF, DYC, YF, YC,
                                                DXCC, DXFC, DXCF,
                                                DXFF, DYFC, DYCF}

# Local size from global size and architecture
local_size(arch::Distributed, global_sz) = (local_size(global_sz[1], arch.partition.x, arch.local_index[1]),
                                            local_size(global_sz[2], arch.partition.y, arch.local_index[2]),
                                            local_size(global_sz[3], arch.partition.z, arch.local_index[3]))

# Individual, per-direction local size
function local_size(N, R, local_index)
    N𝓁  = local_sizes(N, R) # tuple of local sizes per rank
    Nℊ = sum(N𝓁) # global size (should be equal to `N` if `N` is divisible by `R`)
    if local_index == ranks(R) # If R does not divide `N`, we add the remainder to the last rank
        return N𝓁[local_index] + N - Nℊ
    else
        return N𝓁[local_index]
    end
end

# Differentiate between equal and unequal partitioning
@inline local_sizes(N, R::Nothing)    = N
@inline local_sizes(N, R::Int)        = Tuple(N ÷ R for i in 1:R)
@inline local_sizes(N, R::Fractional) = Tuple(ceil(Int, N * r) for r in R.sizes)
@inline function local_sizes(N, R::Sizes)
    if N != sum(R.sizes)
        @warn "The Sizes specified in the architecture $(R.sizes) is inconsistent
               with the grid size: (N = $N != sum(Sizes) = $(sum(R.sizes))).
               Using $(R.sizes)..."
    end
    return R.sizes
end

# Global size from local size
global_size(arch, local_size) = map(sum, concatenate_local_sizes(local_size, arch))

"""
    RectilinearGrid(arch::Distributed, FT=Float64; kw...)

Return the rank-local portion of `RectilinearGrid` on `arch`itecture.
"""
function RectilinearGrid(arch::Distributed,
                         FT::DataType = Oceananigans.defaults.FloatType;
                         size,
                         x = nothing,
                         y = nothing,
                         z = nothing,
                         halo = nothing,
                         extent = nothing,
                         topology = (Periodic, Periodic, Bounded))

    topology, global_sz, halo, x, y, z =
        validate_rectilinear_grid_args(topology, size, halo, FT, extent, x, y, z)

    local_sz = local_size(arch, global_sz)

    nx, ny, nz = local_sz
    Hx, Hy, Hz = halo

    ri, rj, rk = arch.local_index
    Rx, Ry, Rz = arch.ranks

    TX = insert_connected_topology(topology[1], Rx, ri)
    TY = insert_connected_topology(topology[2], Ry, rj)
    TZ = insert_connected_topology(topology[3], Rz, rk)

    local_topo = (TX, TY, TZ)

    xl = Rx == 1 ? x : partition_coordinate(x, nx, arch, 1)
    yl = Ry == 1 ? y : partition_coordinate(y, ny, arch, 2)
    zl = Rz == 1 ? z : partition_coordinate(z, nz, arch, 3)

    Lx, xᶠᵃᵃ, xᶜᵃᵃ, Δxᶠᵃᵃ, Δxᶜᵃᵃ = generate_coordinate(FT, local_topo, local_sz, halo, xl, :x, 1, child_architecture(arch))
    Ly, yᵃᶠᵃ, yᵃᶜᵃ, Δyᵃᶠᵃ, Δyᵃᶜᵃ = generate_coordinate(FT, local_topo, local_sz, halo, yl, :y, 2, child_architecture(arch))
    Lz, z                        = generate_coordinate(FT, local_topo, local_sz, halo, zl, :z, 3, child_architecture(arch))

    return RectilinearGrid{TX, TY, TZ}(arch,
                                       nx, ny, nz,
                                       Hx, Hy, Hz,
                                       Lx, Ly, Lz,
                                       Δxᶠᵃᵃ, Δxᶜᵃᵃ, xᶠᵃᵃ, xᶜᵃᵃ,
                                       Δyᵃᶜᵃ, Δyᵃᶠᵃ, yᵃᶠᵃ, yᵃᶜᵃ,
                                       z)
end

"""
    LatitudeLongitudeGrid(arch::Distributed, FT=Float64; kw...)

Return the rank-local portion of `LatitudeLongitudeGrid` on `arch`itecture.
"""
function LatitudeLongitudeGrid(arch::Distributed,
                               FT::DataType = Oceananigans.defaults.FloatType;
                               precompute_metrics = true,
                               size,
                               latitude,
                               longitude,
                               z,
                               topology = nothing,
                               radius = R_Earth,
                               halo = (1, 1, 1))

    topology, global_sz, halo, latitude, longitude, z, precompute_metrics =
        validate_lat_lon_grid_args(topology, size, halo, FT, latitude, longitude, z, precompute_metrics)

    local_sz = local_size(arch, global_sz)

    nλ, nφ, nz = local_sz
    Hλ, Hφ, Hz = halo
    ri, rj, rk = arch.local_index
    Rx, Ry, Rz = arch.ranks

    TX = insert_connected_topology(topology[1], Rx, ri)
    TY = insert_connected_topology(topology[2], Ry, rj)
    TZ = insert_connected_topology(topology[3], Rz, rk)

    local_topo = (TX, TY, TZ)

    λl = Rx == 1 ? longitude : partition_coordinate(longitude, nλ, arch, 1)
    φl = Ry == 1 ? latitude  : partition_coordinate(latitude,  nφ, arch, 2)
    zl = Rz == 1 ? z         : partition_coordinate(z,         nz, arch, 3)

    # Calculate all direction (which might be stretched)
    # A direction is regular if the domain passed is a Tuple{<:Real, <:Real},
    # it is stretched if being passed is a function or vector (as for the VerticallyStretchedRectilinearGrid)
    Lλ, λᶠᵃᵃ, λᶜᵃᵃ, Δλᶠᵃᵃ, Δλᶜᵃᵃ = generate_coordinate(FT, local_topo, local_sz, halo, λl, :longitude, 1, child_architecture(arch))
    Lz, z                        = generate_coordinate(FT, local_topo, local_sz, halo, zl, :z,         3, child_architecture(arch))

    # The Latitudinal direction is _special_:
    # precompute_metrics assumes that `length(φᵃᶠᵃ) = length(φᵃᶜᵃ) + 1`, which is always the case in a
    # serial grid because `LatitudeLongitudeGrid` should be always `Bounded`, but it is not true for a
    # partitioned `DistributedGrid` with Ry > 1 (one rank will hold a `RightConnected` topology)
    # An extra point is to precompute the Y-direction metrics in case of only one halo, hence
    # we disregard the topology when constructing the metrics and add a halo point!
    # Furthermore, the `LatitudeLongitudeGrid` requires an extra halo on it's latitudinal coordinate to allow calculating
    # the z-area on halo cells. (see: Az =  R^2 * Δλ * (sin(φ[j]) - sin(φ[j-1]))
    Lφ, φᵃᶠᵃ, φᵃᶜᵃ, Δφᵃᶠᵃ, Δφᵃᶜᵃ = generate_coordinate(FT, Bounded(), nφ, Hφ + 1, φl, :latitude, child_architecture(arch))


    preliminary_grid = LatitudeLongitudeGrid{TX, TY, TZ}(arch,
                                                         nλ, nφ, nz,
                                                         Hλ, Hφ, Hz,
                                                         Lλ, Lφ, Lz,
                                                         Δλᶠᵃᵃ, Δλᶜᵃᵃ, λᶠᵃᵃ, λᶜᵃᵃ,
                                                         Δφᵃᶠᵃ, Δφᵃᶜᵃ, φᵃᶠᵃ, φᵃᶜᵃ,
                                                         z,
                                                         (nothing for i=1:10)..., convert(FT, radius))

    return !precompute_metrics ? preliminary_grid : with_precomputed_metrics(preliminary_grid)
end

# Fallback!
reconstruct_global_grid(grid::AbstractGrid) = grid

"""
    reconstruct_global_grid(grid::DistributedGrid)

Return the global grid on `child_architecture(grid)`
"""
function reconstruct_global_grid(grid::DistributedRectilinearGrid)

    arch = grid.architecture
    ri, rj, rk = arch.local_index

    Rx, Ry, Rz = R = arch.ranks

    nx, ny, nz = n = size(grid)
    Hx, Hy, Hz = H = halo_size(grid)
    Nx, Ny, Nz = global_size(arch, n)

    TX, TY, TZ = topology(grid)

    TX = reconstruct_global_topology(TX, Rx, ri, rj, rk, arch)
    TY = reconstruct_global_topology(TY, Ry, rj, ri, rk, arch)
    TZ = reconstruct_global_topology(TZ, Rz, rk, ri, rj, arch)

    x = cpu_face_constructor_x(grid)
    y = cpu_face_constructor_y(grid)
    z = cpu_face_constructor_z(grid)

    ## This will not work with 3D parallelizations!!
    xG = Rx == 1 ? x : assemble_coordinate(x, nx, arch, 1)
    yG = Ry == 1 ? y : assemble_coordinate(y, ny, arch, 2)
    zG = Rz == 1 ? z : assemble_coordinate(z, nz, arch, 3)

    child_arch = child_architecture(arch)

    FT = eltype(grid)

    Lx, xᶠᵃᵃ, xᶜᵃᵃ, Δxᶠᵃᵃ, Δxᶜᵃᵃ = generate_coordinate(FT, TX(), Nx, Hx, xG, :x, child_arch)
    Ly, yᵃᶠᵃ, yᵃᶜᵃ, Δyᵃᶠᵃ, Δyᵃᶜᵃ = generate_coordinate(FT, TY(), Ny, Hy, yG, :y, child_arch)
    Lz, z                        = generate_coordinate(FT, (TX, TY, TZ), (Nx, Ny, Nz), H, zG, :z, 3, child_arch)

    return RectilinearGrid{TX, TY, TZ}(child_arch,
                                       Nx, Ny, Nz,
                                       Hx, Hy, Hz,
                                       Lx, Ly, Lz,
                                       Δxᶠᵃᵃ, Δxᶜᵃᵃ, xᶠᵃᵃ, xᶜᵃᵃ,
                                       Δyᵃᶠᵃ, Δyᵃᶜᵃ, yᵃᶠᵃ, yᵃᶜᵃ,
                                       z)
end

function reconstruct_global_grid(grid::DistributedLatitudeLongitudeGrid)

    arch = grid.architecture
    ri, rj, rk = arch.local_index

    Rx, Ry, Rz = R = arch.ranks

    nλ, nφ, nz = n = size(grid)
    Hλ, Hφ, Hz = H = halo_size(grid)
    Nλ, Nφ, Nz = global_size(arch, n)

    TX, TY, TZ = topology(grid)

    TX = reconstruct_global_topology(TX, Rx, ri, rj, rk, arch)
    TY = reconstruct_global_topology(TY, Ry, rj, ri, rk, arch)
    TZ = reconstruct_global_topology(TZ, Rz, rk, ri, rj, arch)

    λ = cpu_face_constructor_x(grid)
    φ = cpu_face_constructor_y(grid)
    z = cpu_face_constructor_z(grid)

    ## This will not work with 3D parallelizations!!
    λG = Rx == 1 ? λ : assemble_coordinate(λ, nλ, arch, 1)
    φG = Ry == 1 ? φ : assemble_coordinate(φ, nφ, arch, 2)
    zG = Rz == 1 ? z : assemble_coordinate(z, nz, arch, 3)

    child_arch = child_architecture(arch)

    FT = eltype(grid)

    # Calculate all direction (which might be stretched)
    # A direction is regular if the domain passed is a Tuple{<:Real, <:Real},
    # it is stretched if being passed is a function or vector
    Lλ, λᶠᵃᵃ, λᶜᵃᵃ, Δλᶠᵃᵃ, Δλᶜᵃᵃ = generate_coordinate(FT, TX(), Nλ, Hλ, λG, :longitude, child_arch)
    Lφ, φᵃᶠᵃ, φᵃᶜᵃ, Δφᵃᶠᵃ, Δφᵃᶜᵃ = generate_coordinate(FT, TY(), Nφ, Hφ, φG, :latitude,  child_arch)
    Lz, z                        = generate_coordinate(FT, (TX, TY, TZ), (Nλ, Nφ, Nz), H, zG, :z, 3, child_arch)

    precompute_metrics = metrics_precomputed(grid)

    preliminary_grid = LatitudeLongitudeGrid{TX, TY, TZ}(child_arch,
                                                         Nλ, Nφ, Nz,
                                                         Hλ, Hφ, Hz,
                                                         Lλ, Lφ, Lz,
                                                         Δλᶠᵃᵃ, Δλᶜᵃᵃ, λᶠᵃᵃ, λᶜᵃᵃ,
                                                         Δφᵃᶠᵃ, Δφᵃᶜᵃ, φᵃᶠᵃ, φᵃᶜᵃ,
                                                         z,
                                                         (nothing for i=1:10)..., grid.radius)

    return !precompute_metrics ? preliminary_grid : with_precomputed_metrics(preliminary_grid)
end

# We _HAVE_ to dispatch individually for all grid types because
# `RectilinearGrid`, `LatitudeLongitudeGrid` and `ImmersedBoundaryGrid`
# take precedence on `DistributedGrid`
function with_halo(new_halo, grid::DistributedRectilinearGrid)
    new_grid = with_halo(new_halo, reconstruct_global_grid(grid))
    return scatter_local_grids(new_grid, architecture(grid), size(grid))
end

function with_halo(new_halo, grid::DistributedLatitudeLongitudeGrid)
    new_grid = with_halo(new_halo, reconstruct_global_grid(grid))
    return scatter_local_grids(new_grid, architecture(grid), size(grid))
end

# Extending child_architecture for grids
child_architecture(grid::AbstractGrid) = architecture(grid)
child_architecture(grid::DistributedGrid) = child_architecture(architecture(grid))

"""
    scatter_grid_properties(global_grid)

Return the individual `extent`, `topology`, `size`, and `halo` of a `global_grid`.
"""
function scatter_grid_properties(global_grid)
    # Pull out face grid constructors
    x = cpu_face_constructor_x(global_grid)
    y = cpu_face_constructor_y(global_grid)
    z = cpu_face_constructor_z(global_grid)

    topo = topology(global_grid)
    halo = pop_flat_elements(halo_size(global_grid), topo)

    return x, y, z, topo, halo
end

function scatter_local_grids(global_grid::RectilinearGrid, arch::Distributed, local_size)
    x, y, z, topo, halo = scatter_grid_properties(global_grid)
    global_sz = global_size(arch, local_size)
    return RectilinearGrid(arch, eltype(global_grid); size=global_sz, x=x, y=y, z=z, halo=halo, topology=topo)
end

function scatter_local_grids(global_grid::LatitudeLongitudeGrid, arch::Distributed, local_size)
    x, y, z, topo, halo = scatter_grid_properties(global_grid)
    global_sz = global_size(arch, local_size)
    return LatitudeLongitudeGrid(arch, eltype(global_grid); size=global_sz, longitude=x,
                                 latitude=y, z=z, halo=halo, topology=topo, radius=global_grid.radius)
end

"""
    insert_connected_topology(T, R, r)

Return the local topology associated with the global topology `T`, the amount of ranks
in `T` direction (`R`) and the local rank index `r`.
"""
insert_connected_topology(T, R, r) = T

insert_connected_topology(::Type{Bounded}, R, r) = ifelse(R == 1, Bounded,
                                                   ifelse(r == 1, RightConnected,
                                                   ifelse(r == R, LeftConnected,
                                                   FullyConnected)))

insert_connected_topology(::Type{Periodic}, R, r) = ifelse(R == 1, Periodic, FullyConnected)

"""
    reconstruct_global_topology(T, R, r, r1, r2, arch)

Reconstruct the global topology associated with the local topologies `T`, the amount of ranks
in `T` direction (`R`) and the local rank index `r`.

If all ranks have `FullyConnected` topologies, the global topology is `Periodic`;
otherwise it is `Bounded`.
"""
function reconstruct_global_topology(T, R, r, r1, r2, arch)
    if R == 1
        return T
    end

    topologies = zeros(Int, R)
    if T == FullyConnected && r1 == 1 && r2 == 1
        topologies[r] = 1
    end

    topologies = all_reduce(+, topologies, arch)

    if sum(topologies) == R
        return Periodic
    else
        return Bounded
    end
end
