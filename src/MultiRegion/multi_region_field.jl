using Oceananigans.BoundaryConditions: default_auxiliary_bc
using Oceananigans.Fields: FunctionField, data_summary, AbstractField, instantiated_location
using Oceananigans.AbstractOperations: AbstractOperation, compute_computed_field!
using Oceananigans.Operators: assumed_field_location
using Oceananigans.OutputWriters: output_indices

using Base: @propagate_inbounds

import Oceananigans.DistributedComputations: reconstruct_global_field, CommunicationBuffers
import Oceananigans.BoundaryConditions: regularize_field_boundary_conditions
import Oceananigans.Grids: xnodes, ynodes
import Oceananigans.Fields: set!, compute!, compute_at!, validate_field_data, validate_boundary_conditions
import Oceananigans.Fields: validate_indices, communication_buffers
import Oceananigans.Diagnostics: hasnan

import Base: fill!, axes

# Field and FunctionField (both fields with "grids attached")
const MultiRegionField{LX, LY, LZ, O} = Field{LX, LY, LZ, O, <:MultiRegionGrids} where {LX, LY, LZ, O}
const MultiRegionComputedField{LX, LY, LZ, O} = Field{LX, LY, LZ, <:AbstractOperation, <:MultiRegionGrids} where {LX, LY, LZ}
const MultiRegionFunctionField{LX, LY, LZ, C, P, F} = FunctionField{LX, LY, LZ, C, P, F, <:MultiRegionGrids} where {LX, LY, LZ, C, P, F}

const GriddedMultiRegionField = Union{MultiRegionField, MultiRegionFunctionField}
const GriddedMultiRegionFieldTuple{N, T} = NTuple{N, T} where {N, T<:GriddedMultiRegionField}
const GriddedMultiRegionFieldNamedTuple{S, N} = NamedTuple{S, N} where {S, N<:GriddedMultiRegionFieldTuple}

# Utils
Base.size(f::GriddedMultiRegionField) = size(getregion(f, 1))

@inline isregional(f::GriddedMultiRegionField) = true
@inline devices(f::GriddedMultiRegionField) = devices(f.grid)
@inline sync_all_devices!(f::GriddedMultiRegionField) = sync_all_devices!(devices(f.grid))

@inline switch_device!(f::GriddedMultiRegionField, d) = switch_device!(f.grid, d)
@inline getdevice(f::GriddedMultiRegionField, d) = getdevice(f.grid, d)

@inline getregion(f::MultiRegionFunctionField{LX, LY, LZ}, r) where {LX, LY, LZ} =
    FunctionField{LX, LY, LZ}(_getregion(f.func, r),
                              _getregion(f.grid, r),
                              clock = _getregion(f.clock, r),
                              parameters = _getregion(f.parameters, r))

@inline getregion(f::MultiRegionField{LX, LY, LZ}, r) where {LX, LY, LZ} =
    Field{LX, LY, LZ}(_getregion(f.grid, r),
                      _getregion(f.data, r),
                      _getregion(f.boundary_conditions, r),
                      _getregion(f.indices, r),
                      _getregion(f.operand, r),
                      _getregion(f.status, r),
                      _getregion(f.communication_buffers, r))

@inline _getregion(f::MultiRegionFunctionField{LX, LY, LZ}, r) where {LX, LY, LZ} =
    FunctionField{LX, LY, LZ}(getregion(f.func, r),
                              getregion(f.grid, r),
                              clock = getregion(f.clock, r),
                              parameters = getregion(f.parameters, r))

@inline _getregion(f::MultiRegionField{LX, LY, LZ}, r) where {LX, LY, LZ} =
    Field{LX, LY, LZ}(getregion(f.grid, r),
                      getregion(f.data, r),
                      getregion(f.boundary_conditions, r),
                      getregion(f.indices, r),
                      getregion(f.operand, r),
                      getregion(f.status, r),
                      getregion(f.communication_buffers, r))

"""
    reconstruct_global_field(mrf)

Reconstruct a global field from `mrf::MultiRegionField` on the `CPU`.
"""
function reconstruct_global_field(mrf::MultiRegionField)

    # TODO: Is this correct? Shall we reconstruct a global field on the architecture of the grid?
    global_grid  = on_architecture(CPU(), reconstruct_global_grid(mrf.grid))
    indices      = reconstruct_global_indices(mrf.indices, mrf.grid.partition, size(global_grid))
    global_field = Field(instantiated_location(mrf), global_grid; indices)

    data = construct_regionally(interior, mrf)
    data = construct_regionally(Array, data)
    compact_data!(global_field, global_grid, data, mrf.grid.partition)

    fill_halo_regions!(global_field)
    return global_field
end

function reconstruct_global_indices(indices, p::XPartition, N)
    idx1 = getregion(indices, 1)[1]
    idxl = getregion(indices, length(p))[1]

    if idx1 == Colon() && idxl == Colon()
        idx_x = Colon()
    else
        idx_x = UnitRange(idx1 == Colon() ? 1 : first(idx1), idxl == Colon() ? N[1] : last(idxl))
    end

    idx_y = getregion(indices, 1)[2]
    idx_z = getregion(indices, 1)[3]

    return (idx_x, idx_y, idx_z)
end

function reconstruct_global_indices(indices, p::YPartition, N)
    idx1 = getregion(indices, 1)[2]
    idxl = getregion(indices, length(p))[2]

    if idx1 == Colon() && idxl == Colon()
        idx_y = Colon()
    else
        idx_y = UnitRange(ix1 == Colon() ? 1 : first(idx1), idxl == Colon() ? N[2] : last(idxl))
    end

    idx_x = getregion(indices, 1)[1]
    idx_z = getregion(indices, 1)[3]

    return (idx_x, idx_y, idx_z)
end

## Functions applied regionally
set!(mrf::MultiRegionField, v)  = apply_regionally!(set!,  mrf, v)
fill!(mrf::MultiRegionField, v) = apply_regionally!(fill!, mrf, v)

set!(mrf::MultiRegionField, a::Number)  = apply_regionally!(set!,  mrf, a)
fill!(mrf::MultiRegionField, a::Number) = apply_regionally!(fill!, mrf, a)

set!(mrf::MultiRegionField, f::Function) = apply_regionally!(set!, mrf, f)
set!(u::MultiRegionField, v::MultiRegionField) = apply_regionally!(set!, u, v)
compute!(mrf::GriddedMultiRegionField, time=nothing) = apply_regionally!(compute!, mrf, time)

# Disambiguation (same as computed_field.jl:64)
function compute!(comp::MultiRegionComputedField, time=nothing)
    # First compute `dependencies`:
    compute_at!(comp.operand, time)

    # Now perform the primary computation
    @apply_regionally compute_computed_field!(comp)

    fill_halo_regions!(comp)

    return comp
end

@inline hasnan(field::MultiRegionField) = (&)(construct_regionally(hasnan, field).regional_objects...)

validate_indices(indices, loc, mrg::MultiRegionGrids) =
    construct_regionally(validate_indices, indices, loc, mrg.region_grids)

communication_buffers(grid::MultiRegionGrid, data, bcs) =
    construct_regionally(CommunicationBuffers, grid, data, bcs)

communication_buffers(grid::MultiRegionGrid, data, ::Nothing) = nothing
communication_buffers(grid::MultiRegionGrid, data, ::Missing) = nothing

CommunicationBuffers(grid::MultiRegionGrids, args...; kwargs...) =
    construct_regionally(CommunicationBuffers, grid, args...; kwargs...)

function regularize_field_boundary_conditions(bcs::FieldBoundaryConditions,
                                              mrg::MultiRegionGrids,
                                              field_name::Symbol,
                                              prognostic_field_name=nothing)

  reg_bcs = regularize_field_boundary_conditions(bcs, mrg.region_grids[1], field_name, prognostic_field_name)
  loc = assumed_field_location(field_name)

  return FieldBoundaryConditions(mrg, loc; west = reg_bcs.west,
                                           east = reg_bcs.east,
                                           south = reg_bcs.south,
                                           north = reg_bcs.north,
                                           bottom = reg_bcs.bottom,
                                           top = reg_bcs.top,
                                           immersed = reg_bcs.immersed)
end

function inject_regional_bcs(grid, connectivity, loc, indices;   
                             west = default_auxiliary_bc(grid, Val(:west), loc),
                             east = default_auxiliary_bc(grid, Val(:east), loc),
                             south = default_auxiliary_bc(grid, Val(:south), loc),
                             north = default_auxiliary_bc(grid, Val(:north), loc),
                             bottom = default_auxiliary_bc(grid, Val(:bottom),loc),
                             top = default_auxiliary_bc(grid, Val(:top), loc),
                             immersed = NoFluxBoundaryCondition())

    west  = inject_west_boundary(connectivity, west)
    east  = inject_east_boundary(connectivity, east)
    south = inject_south_boundary(connectivity, south)
    north = inject_north_boundary(connectivity, north)

    return FieldBoundaryConditions(indices, west, east, south, north, bottom, top, immersed)
end

FieldBoundaryConditions(mrg::MultiRegionGrids, loc, indices; kwargs...) =
    construct_regionally(inject_regional_bcs, mrg, mrg.connectivity, Reference(loc), indices; kwargs...)

function Base.show(io::IO, field::MultiRegionField)
    bcs = getregion(field, 1).boundary_conditions

    prefix =
        string("$(summary(field))\n",
                "├── grid: ", summary(field.grid), "\n",
                "├── boundary conditions: ", summary(bcs), "\n")
    middle = isnothing(field.operand) ? "" :
        string("├── operand: ", summary(field.operand), "\n",
                "├── status: ", summary(field.status), "\n")

    suffix = string("└── data: ", summary(field.data), "\n",
                    "    └── ", data_summary(field))

    print(io, prefix, middle, suffix)
end

xnodes(ψ::AbstractField{<:Any, <:Any, <:Any, <:OrthogonalSphericalShellGrid}) = xnodes((location(ψ, 1), location(ψ, 2)), ψ.grid)
ynodes(ψ::AbstractField{<:Any, <:Any, <:Any, <:OrthogonalSphericalShellGrid}) = ynodes((location(ψ, 1), location(ψ, 2)), ψ.grid)

# Convenience
@propagate_inbounds Base.getindex(mrf::MultiRegionField, r::Int) = getregion(mrf, r)
@propagate_inbounds Base.lastindex(mrf::MultiRegionField) = lastindex(mrf.grid)
