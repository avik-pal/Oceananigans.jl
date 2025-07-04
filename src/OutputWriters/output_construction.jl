using Oceananigans.Fields: validate_indices, Reduction
using Oceananigans.AbstractOperations: AbstractOperation, ComputedField
using Oceananigans.Grids: default_indices
using Oceananigans.Utils: getregion, @apply_regionally

restrict_to_interior(::Colon, loc, topo, N) = interior_indices(loc, topo, N)
restrict_to_interior(::Colon, ::Nothing, topo, N) = UnitRange(1, 1)
restrict_to_interior(index::Base.OneTo, loc, topo, N) = restrict_to_interior(UnitRange(index), loc, topo, N)
restrict_to_interior(index::AbstractUnitRange, ::Nothing, topo, N) = UnitRange(1, 1)

function restrict_to_interior(index::AbstractUnitRange, loc, topo, N)
    from = max(first(index), 1)
    to = min(last(index), last(interior_indices(loc, topo, N)))
    return UnitRange(from, to)
end

#####
##### Function output fallback
#####

function construct_output(output, grid, indices, with_halos)
    if !(indices isa typeof(default_indices(3)))
        output_type = output isa Function ? "Function" : ""
        @warn "Cannot slice $output_type $output with $indices: output will be unsliced."
    end

    return output
end

#####
##### Support for Field, Reduction, and AbstractOperation outputs
#####

intersect_indices(output, indices) = indices
intersect_indices(output::Field, indices) = map(intersect_index_range, indices, output.indices)

intersect_index_range(::Colon, ::Colon) = Colon()
intersect_index_range(range::UnitRange, ::Colon) = range
intersect_index_range(::Colon, range::UnitRange) = range
intersect_index_range(range1::UnitRange, range2::UnitRange) = intersect(range1, range2)

function output_indices(output::Union{AbstractField, Reduction}, grid, indices, with_halos)
    indices = validate_indices(indices, location(output), grid)

    if !with_halos # Maybe chop those indices
        loc = map(instantiate, location(output))
        topo = map(instantiate, topology(grid))
        @apply_regionally indices = map(restrict_to_interior, indices, loc, topo, size(grid))
    end

    @apply_regionally intersected = intersect_indices(output, indices)

    return intersected
end

function construct_output(user_output::Union{AbstractField, Reduction}, grid, user_indices, with_halos)
    indices = output_indices(user_output, grid, user_indices, with_halos)

    # Don't compute AbstractOperations or Reductions
    additional_kw = user_output isa Field ? NamedTuple() : (; compute=false)

    return Field(user_output; indices, additional_kw...)
end

#####
##### Time-averaging
#####

function construct_output(averaged_output::WindowedTimeAverage{<:Field}, grid, indices, with_halos)
    output = construct_output(averaged_output.operand, grid, indices, with_halos)
    return WindowedTimeAverage(output; schedule=averaged_output.schedule)
end
