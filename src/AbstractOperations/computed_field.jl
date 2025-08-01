#####
##### Fields computed from abstract operations
#####

using KernelAbstractions: @kernel, @index
using Oceananigans.Grids: default_indices
using Oceananigans.Fields: FunctionField, FieldStatus, validate_indices, offset_index, instantiated_location
using Oceananigans.Utils: launch!

import Oceananigans.Fields: Field, compute!

const OperationOrFunctionField = Union{AbstractOperation, FunctionField}
const ComputedField = Field{<:Any, <:Any, <:Any, <:OperationOrFunctionField}

"""
    Field(operand::OperationOrFunctionField;
          data = nothing,
          indices = indices(operand),
          boundary_conditions = FieldBoundaryConditions(operand.grid, location(operand)),
          compute = true,
          recompute_safely = true)

Return a field `f` where `f.data` is computed from `f.operand` by calling `compute!(f)`.

Keyword arguments
=================

`data` (`AbstractArray`): An offset Array or CuArray for storing the result of a computation.
                          Must have `total_size(location(operand), grid)`.

`boundary_conditions` (`FieldBoundaryConditions`): Boundary conditions for `f`.

`recompute_safely` (`Bool`): Whether or not to _always_ "recompute" `f` if `f` is
                             nested within another computation via an `AbstractOperation` or `FunctionField`.
                             If `data` is not provided then `recompute_safely = false` and
                             recomputation is _avoided_. If `data` is provided, then
                             `recompute_safely = true` by default.

`compute`: If `true`, `compute!` the `Field` during construction, otherwise if `false`, initialize with zeros.
           Default: `true`.
"""
function Field(operand::OperationOrFunctionField;
               data = nothing,
               indices = indices(operand),
               boundary_conditions = FieldBoundaryConditions(operand.grid, instantiated_location(operand)),
               status = nothing,
               compute = true,
               recompute_safely = true)

    grid = operand.grid
    loc = instantiated_location(operand)
    indices = validate_indices(indices, loc, grid)

    @apply_regionally boundary_conditions = FieldBoundaryConditions(indices, boundary_conditions)

    if isnothing(data)
        @apply_regionally data = new_data(grid, loc, indices)
        recompute_safely = false
    end

    if isnothing(status)
        status = recompute_safely ? nothing : FieldStatus()
    end

    computed_field = Field(loc, grid, data, boundary_conditions, indices, operand, status)

    if compute
        compute!(computed_field)
    end

    return computed_field
end

"""
    compute!(comp::ComputedField, time=nothing)

Compute `comp.operand` and store the result in `comp.data`.
If `time` then computation happens if `time != field.status.time`.
"""
function compute!(comp::ComputedField, time=nothing)
    # First compute `dependencies`:
    compute_at!(comp.operand, time)

    # Now perform the primary computation
    @apply_regionally compute_computed_field!(comp)

    fill_halo_regions!(comp)

    return comp
end

function compute_computed_field!(comp)
    arch = architecture(comp)
    parameters = KernelParameters(size(comp), map(offset_index, comp.indices))
    launch!(arch, comp.grid, parameters, _compute!, comp.data, comp.operand)
    return comp
end

"""Compute an `operand` and store in `data`."""
@kernel function _compute!(data, operand)
    i, j, k = @index(Global, NTuple)
    @inbounds data[i, j, k] = operand[i, j, k]
end
