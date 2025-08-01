using Oceananigans.Grids: metrics_precomputed, on_architecture, pop_flat_elements, grid_name
using Oceananigans.ImmersedBoundaries: GridFittedBottom, PartialCellBottom, GridFittedBoundary

import Oceananigans.Grids: architecture, size, new_data, halo_size
import Oceananigans.Grids: with_halo, on_architecture
import Oceananigans.Grids: destantiate
import Oceananigans.Grids: minimum_xspacing, minimum_yspacing, minimum_zspacing
import Oceananigans.Models.HydrostaticFreeSurfaceModels: default_free_surface
import Oceananigans.DistributedComputations: reconstruct_global_grid

struct MultiRegionGrid{FT, TX, TY, TZ, CZ, P, C, G, D, Arch} <: AbstractUnderlyingGrid{FT, TX, TY, TZ, CZ, Arch}
    architecture :: Arch
    partition :: P
    connectivity :: C
    region_grids :: G
    devices :: D

    MultiRegionGrid{FT, TX, TY, TZ, CZ}(arch::A, partition::P, connectivity::C,
                                        region_grids::G, devices::D) where {FT, TX, TY, TZ, CZ, P, C, G, D, A} =
        new{FT, TX, TY, TZ, CZ, P, C, G, D, A}(arch, partition, connectivity, region_grids, devices)
end

const ImmersedMultiRegionGrid{FT, TX, TY, TZ} = ImmersedBoundaryGrid{FT, TX, TY, TZ, <:MultiRegionGrid}

const MultiRegionGrids{FT, TX, TY, TZ} = Union{MultiRegionGrid{FT, TX, TY, TZ}, ImmersedMultiRegionGrid{FT, TX, TY, TZ}}

@inline isregional(mrg::MultiRegionGrids)       = true
@inline getdevice(mrg::MultiRegionGrid, i)      = getdevice(mrg.region_grids, i)
@inline switch_device!(mrg::MultiRegionGrid, i) = switch_device!(getdevice(mrg, i))
@inline devices(mrg::MultiRegionGrid)           = devices(mrg.region_grids)
@inline sync_all_devices!(mrg::MultiRegionGrid) = sync_all_devices!(devices(mrg))

@inline  getregion(mrg::MultiRegionGrid, r) = _getregion(mrg.region_grids, r)
@inline _getregion(mrg::MultiRegionGrid, r) =  getregion(mrg.region_grids, r)

# Convenience
@inline Base.getindex(mrg::MultiRegionGrids, r::Int) = getregion(mrg, r)
@inline Base.first(mrg::MultiRegionGrids) = mrg[1]
@inline Base.lastindex(mrg::MultiRegionGrids) = length(mrg)
number_of_regions(mrg::MultiRegionGrids) = lastindex(mrg)

minimum_xspacing(grid::MultiRegionGrid, ℓx, ℓy, ℓz) =
    minimum(minimum_xspacing(grid[r], ℓx, ℓy, ℓz) for r in 1:number_of_regions(grid))

minimum_yspacing(grid::MultiRegionGrid, ℓx, ℓy, ℓz) =
    minimum(minimum_yspacing(grid[r], ℓx, ℓy, ℓz) for r in 1:number_of_regions(grid))

minimum_zspacing(grid::MultiRegionGrid, ℓx, ℓy, ℓz) =
    minimum(minimum_zspacing(grid[r], ℓx, ℓy, ℓz) for r in 1:number_of_regions(grid))

@inline getdevice(mrg::ImmersedMultiRegionGrid, i)      = getdevice(mrg.underlying_grid.region_grids, i)
@inline switch_device!(mrg::ImmersedMultiRegionGrid, i) = switch_device!(getdevice(mrg.underlying_grid, i))
@inline devices(mrg::ImmersedMultiRegionGrid)           = devices(mrg.underlying_grid.region_grids)
@inline sync_all_devices!(mrg::ImmersedMultiRegionGrid) = sync_all_devices!(devices(mrg.underlying_grid))

@inline Base.length(mrg::MultiRegionGrid)         = Base.length(mrg.region_grids)
@inline Base.length(mrg::ImmersedMultiRegionGrid) = Base.length(mrg.underlying_grid.region_grids)

# the default free surface solver; see Models.HydrostaticFreeSurfaceModels
default_free_surface(grid::MultiRegionGrid; gravitational_acceleration=g_Earth) =
    SplitExplicitFreeSurface(; substeps=50, gravitational_acceleration)

"""
    MultiRegionGrid(global_grid; partition = XPartition(2),
                                 devices = nothing,
                                 validate = true)

Split a `global_grid` into different regions handled by `devices`.

Positional Arguments
====================

- `global_grid`: the grid to be divided into regions.

Keyword Arguments
=================

- `partition`: the partitioning required. The implemented partitioning are `XPartition`
               (division along the ``x`` direction) and `YPartition` (division along
               the ``y`` direction).

- `devices`: the devices to allocate memory on. If `nothing` is provided (default) then memorey is
             allocated on the the `CPU`. For `GPU` computation it is possible to specify the total
             number of GPUs or the specific GPUs to allocate memory on. The number of devices does
             not need to match the number of regions.

- `validate :: Boolean`: Whether to validate `devices`; defautl: `true`.

Example
=======

```@example multiregion
julia> using Oceananigans

julia> using Oceananigans.MultiRegion: MultiRegionGrid, XPartition

julia> grid = RectilinearGrid(size=(12, 12), extent=(1, 1), topology=(Bounded, Bounded, Flat));

julia> multi_region_grid = MultiRegionGrid(grid, partition = XPartition(4))
```
"""
function MultiRegionGrid(global_grid; partition = XPartition(2),
                                      devices = nothing,
                                      validate = true)

    @warn "MultiRegion functionalities are experimental: help the development by reporting bugs or non-implemented features!"

    if length(partition) == 1
        return global_grid
    end

    arch = architecture(global_grid)

    if validate
        devices = validate_devices(partition, arch, devices)
        devices = assign_devices(arch, partition, devices)
    end

    connectivity = Connectivity(devices, partition, global_grid)

    global_grid  = on_architecture(CPU(), global_grid)
    local_size   = MultiRegionObject(arch, partition_size(partition, global_grid), devices)
    local_extent = MultiRegionObject(arch, partition_extent(partition, global_grid), devices)
    local_topo   = MultiRegionObject(arch, partition_topology(partition, global_grid), devices)

    global_topo  = topology(global_grid)

    FT = eltype(global_grid)

    args = (Reference(global_grid),
            Reference(arch),
            local_topo,
            local_size,
            local_extent,
            Reference(partition),
            Iterate(1:length(partition)))

    region_grids = construct_regionally(construct_grid, args...)

    # Propagate the vertical coordinate type in the `MultiRegionGrid`
    CZ = typeof(global_grid.z)

    ## If we are on GPUs we want to enable peer access, which we do by just copying fake arrays between all devices
    maybe_enable_peer_access!(arch, devices)

    return MultiRegionGrid{FT, global_topo[1], global_topo[2], global_topo[3], CZ}(arch, partition, connectivity, region_grids, devices)
end

function construct_grid(grid::RectilinearGrid, child_arch, topo, size, extent, args...)
    halo = halo_size(grid)
    size = pop_flat_elements(size, topo)
    halo = pop_flat_elements(halo, topo)
    FT   = eltype(grid)

    return RectilinearGrid(child_arch, FT; size = size, halo = halo, topology = topo, extent...)
end

function construct_grid(grid::LatitudeLongitudeGrid, child_arch, topo, size, extent, args...)
    halo = halo_size(grid)
    FT   = eltype(grid)
    lon, lat, z = extent
    return LatitudeLongitudeGrid(child_arch, FT;
                                 size = size, halo = halo, radius = grid.radius,
                                 latitude = lat, longitude = lon, z = z, topology = topo,
                                 precompute_metrics = metrics_precomputed(grid))
end

"""
    reconstruct_global_grid(mrg::MultiRegionGrid)

Reconstruct the `mrg` global grid associated with the `MultiRegionGrid` on `architecture(mrg)`.
"""
function reconstruct_global_grid(mrg::MultiRegionGrid)
    size   = reconstruct_size(mrg, mrg.partition)
    extent = reconstruct_extent(mrg, mrg.partition)
    topo   = topology(mrg)
    switch_device!(mrg.devices[1])
    return construct_grid(mrg.region_grids[1], architecture(mrg), topo, size, extent)
end

#####
##### `ImmersedMultiRegionGrid` functionalities
#####

function reconstruct_global_grid(mrg::ImmersedMultiRegionGrid)
    global_grid     = reconstruct_global_grid(mrg.underlying_grid)
    global_immersed_boundary = reconstruct_global_immersed_boundary(mrg.immersed_boundary)
    global_immersed_boundary = on_architecture(architecture(mrg), global_immersed_boundary)

    return ImmersedBoundaryGrid(global_grid, global_immersed_boundary)
end

reconstruct_global_immersed_boundary(g::GridFittedBottom{<:Field})   =   GridFittedBottom(reconstruct_global_field(g.bottom_height), g.immersed_condition)
reconstruct_global_immersed_boundary(g::PartialCellBottom{<:Field})  =  PartialCellBottom(reconstruct_global_field(g.bottom_height), g.minimum_fractional_cell_height)
reconstruct_global_immersed_boundary(g::GridFittedBoundary{<:Field}) = GridFittedBoundary(reconstruct_global_field(g.mask))

@inline  getregion(mrg::ImmersedMultiRegionGrid{FT, TX, TY, TZ}, r) where {FT, TX, TY, TZ} = ImmersedBoundaryGrid{TX, TY, TZ}(_getregion(mrg.underlying_grid, r),
                                                                                                                              _getregion(mrg.immersed_boundary, r),
                                                                                                                              _getregion(mrg.interior_active_cells, r),
                                                                                                                              _getregion(mrg.active_z_columns, r))

@inline _getregion(mrg::ImmersedMultiRegionGrid{FT, TX, TY, TZ}, r) where {FT, TX, TY, TZ} = ImmersedBoundaryGrid{TX, TY, TZ}(getregion(mrg.underlying_grid, r),
                                                                                                                              getregion(mrg.immersed_boundary, r),
                                                                                                                              getregion(mrg.interior_active_cells, r),
                                                                                                                              getregion(mrg.active_z_columns, r))

"""
    multi_region_object_from_array(a::AbstractArray, mrg::MultiRegionGrid)

Adapt an array `a` to be compatible with a `MultiRegionGrid`.
"""
function multi_region_object_from_array(a::AbstractArray, mrg::MultiRegionGrid)
    local_size = construct_regionally(size, mrg)
    arch = architecture(mrg)
    a  = on_architecture(CPU(), a)
    ma = construct_regionally(partition, a, mrg.partition, local_size, Iterate(1:length(mrg)), arch)
    return ma
end

# Fallback!
multi_region_object_from_array(a::AbstractArray, grid) = on_architecture(architecture(grid), a)

####
#### Utilities for MultiRegionGrid
####

new_data(FT::DataType, mrg::MultiRegionGrids, args...) = construct_regionally(new_data, FT, mrg, args...)

# This is kind of annoying but it is necessary to have compatible MultiRegion and Distributed
function with_halo(new_halo, mrg::MultiRegionGrid)
    devices   = mrg.devices
    partition = mrg.partition
    cpu_mrg   = on_architecture(CPU(), mrg)

    global_grid = reconstruct_global_grid(cpu_mrg)
    new_global  = with_halo(new_halo, global_grid)
    new_global  = on_architecture(architecture(mrg), new_global)

    return MultiRegionGrid(new_global; partition, devices, validate = false)
end

function on_architecture(::CPU, mrg::MultiRegionGrid{FT, TX, TY, TZ, CZ}) where {FT, TX, TY, TZ, CZ}
    new_grids = on_architecture(CPU(), mrg.region_grids)
    devices   = Tuple(CPU() for i in 1:length(mrg))
    return MultiRegionGrid{FT, TX, TY, TZ, CZ}(CPU(), mrg.partition, mrg.connectivity, new_grids, devices)
end

Base.summary(mrg::MultiRegionGrids{FT, TX, TY, TZ}) where {FT, TX, TY, TZ} =
    "MultiRegionGrid{$FT, $TX, $TY, $TZ} with $(summary(mrg.partition)) on $(string(typeof(mrg.region_grids[1]).name.wrapper))"

Base.show(io::IO, mrg::MultiRegionGrids{FT, TX, TY, TZ}) where {FT, TX, TY, TZ} =
    print(io, "$(grid_name(mrg)){$FT, $TX, $TY, $TZ} partitioned on $(architecture(mrg)): \n",
              "├── grids: $(summary(mrg.region_grids[1])) \n",
              "├── partitioning: $(summary(mrg.partition)) \n",
              "├── connectivity: $(summary(mrg.connectivity)) \n",
              "└── devices: $(devices(mrg))")

function Base.:(==)(mrg₁::MultiRegionGrids, mrg₂::MultiRegionGrids)
    #check if grids are of the same type
    vals = construct_regionally(Base.:(==), mrg₁, mrg₂)
    return all(vals.regional_objects)
end

####
#### This works only for homogenous partitioning
####

size(mrg::MultiRegionGrids) = size(getregion(mrg, 1))
halo_size(mrg::MultiRegionGrids) = halo_size(getregion(mrg, 1))

####
#### Get property for `MultiRegionGrid` (gets the properties of region 1)
#### In general getproperty should never be used as a MultiRegionGrid
#### Should be used only in combination with an @apply_regionally
####

grids(mrg::MultiRegionGrid) = mrg.region_grids

getmultiproperty(mrg::MultiRegionGrid, x::Symbol) = construct_regionally(Base.getproperty, grids(mrg), x)

const MRG = MultiRegionGrid

@inline Base.getproperty(mrg::MRG, property::Symbol)                 = get_multi_property(mrg, Val(property))
@inline get_multi_property(mrg::MRG, ::Val{property}) where property = getproperty(getindex(getfield(mrg, :region_grids), 1), property)
@inline get_multi_property(mrg::MRG, ::Val{:architecture})           = getfield(mrg, :architecture)
@inline get_multi_property(mrg::MRG, ::Val{:partition})              = getfield(mrg, :partition)
@inline get_multi_property(mrg::MRG, ::Val{:connectivity})           = getfield(mrg, :connectivity)
@inline get_multi_property(mrg::MRG, ::Val{:region_grids})           = getfield(mrg, :region_grids)
@inline get_multi_property(mrg::MRG, ::Val{:devices})                = getfield(mrg, :devices)
