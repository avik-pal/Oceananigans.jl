using Oceananigans.Utils: work_layout
using Oceananigans.Architectures: device
using Oceananigans.TimeSteppers: cache_tracer_tendency!

using KernelAbstractions.Extras.LoopInfo: @unroll

import Oceananigans.TimeSteppers: _cache_field_tendencies!

""" Store source terms for `uh`, `vh`, and `h`. """
@kernel function _cache_solution_tendencies!(G⁻, grid, G⁰)
    i, j, k = @index(Global, NTuple)
    @unroll for t in 1:3
        @inbounds G⁻[t][i, j, k] = G⁰[t][i, j, k]
    end
end

""" Store previous source terms before updating them. """
function cache_previous_tendencies!(model::ShallowWaterModel)
    workgroup, worksize = work_layout(model.grid, :xyz)

    cache_solution_tendencies_kernel! = _cache_solution_tendencies!(device(model.architecture), workgroup, worksize)
    cache_tracer_tendency_kernel! = _cache_field_tendencies!(device(model.architecture), workgroup, worksize)

    cache_solution_tendencies_kernel!(model.timestepper.G⁻,
                                      model.grid,
                                      model.timestepper.Gⁿ)

    # Tracer fields
    for i in 4:length(model.timestepper.G⁻)
        @inbounds Gc⁻ = model.timestepper.G⁻[i]
        @inbounds Gc⁰ = model.timestepper.Gⁿ[i]
        cache_tracer_tendency_kernel!(Gc⁻, model.grid, Gc⁰)
    end

    return nothing
end

