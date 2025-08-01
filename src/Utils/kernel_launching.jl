#####
##### Utilities for launching kernels
#####

using Oceananigans: location
using Oceananigans.Architectures
using Oceananigans.Grids
using Oceananigans.Grids: AbstractGrid
using Adapt
using Base: @pure
using KernelAbstractions: Kernel

import Oceananigans
import KernelAbstractions: get, expand
import Base

struct KernelParameters{S, O} end

"""
    KernelParameters(size, offsets)

Return parameters for kernel launching and execution that define (i) a tuple that
defines the `size` of the kernel being launched and (ii) a tuple of `offsets` that
offset loop indices. For example, `offsets = (0, 0, 0)` with `size = (N, N, N)` means
all indices loop from `1:N`. If `offsets = (1, 1, 1)`, then all indices loop from
`2:N+1`. And so on.

Example
=======

```julia
size = (8, 6, 4)
offsets = (0, 1, 2)
kp = KernelParameters(size, offsets)

# Launch a kernel with indices that range from i=1:8, j=2:7, k=3:6,
# where i, j, k are the first, second, and third index, respectively:

launch!(arch, grid, kp, kernel!, kernel_args...)
```

See [`launch!`](@ref).
"""
KernelParameters(size, offsets) = KernelParameters{size, offsets}()

# If `size` and `offsets` are numbers, we convert them to tuples
KernelParameters(s::Number, o::Number) = KernelParameters(tuple(s), tuple(o))

"""
    KernelParameters(range1, [range2, range3])

Return parameters for launching a kernel of up to three dimensions, where the
indices spanned by the kernel in each dimension are given by (range1, range2, range3).

Example
=======

```julia
kp = KernelParameters(1:4, 0:10)

# Launch a kernel with indices that range from i=1:4, j=0:10,
# where i, j are the first and second index, respectively.
launch!(arch, grid, kp, kernel!, kernel_args...)
```

See the documentation for [`launch!`](@ref).
"""
function KernelParameters(r::AbstractUnitRange)
    size = length(r)
    offset = first(r) - 1
    return KernelParameters(tuple(size), tuple(offset))
end

function KernelParameters(r1::AbstractUnitRange, r2::AbstractUnitRange)
    size = (length(r1), length(r2))
    offsets = (first(r1) - 1, first(r2) - 1)
    return KernelParameters(size, offsets)
end

function KernelParameters(r1::AbstractUnitRange, r2::AbstractUnitRange, r3::AbstractUnitRange)
    size = (length(r1), length(r2), length(r3))
    offsets = (first(r1) - 1, first(r2) - 1, first(r3) - 1)
    return KernelParameters(size, offsets)
end

# Convenience `Tuple`d constructor
KernelParameters(args::Tuple) = KernelParameters(args...)

contiguousrange(range::NTuple{N, Int}, offset::NTuple{N, Int}) where N = Tuple(1+o:r+o for (r, o) in zip(range, offset))
flatten_reduced_dimensions(worksize, dims) = Tuple(d ∈ dims ? 1 : worksize[d] for d = 1:3)

"""
    MappedFunction(func, index_map)

A `MappedFunction` is a wrapper around a function `func` of a kernel that is mapped over an `index_map`.
The `index_map` is a one-dimensional `AbstractArray` where the elements are tuple of indices `(i, j, k, ....)`.

A kernel launched over a `MappedFunction` **needs** to be launched with a one-dimensional **static** workgroup and worksize.
If using `launch!` with a non-nothing `active_cells_map` keyword argument, the kernel function will be automatically wrapped
in a `MappedFunction` with `index_map = active_cells_map` and the resulting kernel will be launched with a
one-dimensional workgroup and worksize equal  to the length of the `active_cells_map`.
"""
struct MappedFunction{F, M} <: Function
    func :: F
    index_map :: M
end

# Support for 1D
heuristic_workgroup(Wx) = min(Wx, 256)

# This supports 2D, 3D and 4D work sizes (but the 3rd and 4th dimension are discarded)
function heuristic_workgroup(Wx, Wy, Wz = nothing, Wt = nothing)
    if Wx == 1 && Wy == 1            # One-dimensional column models
        return (1, 1) 
    elseif Wx == 1                   # Two-dimensional y-z slice models
        return (1, min(256, Wy))
    elseif Wy == 1                   # Two-dimensional x-z slice models
        return (min(256, Wx), 1)
    else                             # Three-dimensional models
        return (16, 16)
    end
end


periphery_offset(loc, topo, N) = 0
periphery_offset(::Face, ::Bounded, N) = ifelse(N > 1, 1, 0)

drop_omitted_dims(::Val{:xyz}, xyz) = xyz
drop_omitted_dims(::Val{:xy}, (x, y, z)) = (x, y)
drop_omitted_dims(::Val{:xz}, (x, y, z)) = (x, z)
drop_omitted_dims(::Val{:yz}, (x, y, z)) = (y, z)
drop_omitted_dims(workdims, xyz) = throw(ArgumentError("Unsupported launch configuration: $workdims"))

"""
    interior_work_layout(grid, dims, location)

Returns the `workgroup` and `worksize` for launching a kernel over `dims`
on `grid` that excludes peripheral nodes.
The `workgroup` is a tuple specifying the threads per block in each
dimension. The `worksize` specifies the range of the loop in each dimension.

Specifying `include_right_boundaries=true` will ensure the work layout includes the
right face end points along bounded dimensions. This requires the field `location`
to be specified.

For more information, see: https://github.com/CliMA/Oceananigans.jl/pull/308
"""
@inline function interior_work_layout(grid, workdims::Symbol, location)
    valdims = Val(workdims)
    Nx, Ny, Nz = size(grid)

    # just an example for :xyz
    ℓx, ℓy, ℓz = map(instantiate, location)
    tx, ty, tz = map(instantiate, topology(grid))

    # Offsets
    ox = periphery_offset(ℓx, tx, Nx)
    oy = periphery_offset(ℓy, ty, Ny)
    oz = periphery_offset(ℓz, tz, Nz)

    # Worksize
    Wx, Wy, Wz = (Nx-ox, Ny-oy, Nz-oz)
    workgroup = heuristic_workgroup(Wx, Wy, Wz)
    workgroup = StaticSize(workgroup)

    # Adapt to workdims
    worksize = drop_omitted_dims(valdims, (Wx, Wy, Wz))
    offsets = drop_omitted_dims(valdims, (ox, oy, oz))
    range = contiguousrange(worksize, offsets)
    worksize = OffsetStaticSize(range)

    return workgroup, worksize
end

"""
    work_layout(grid, dims, location)

Returns the `workgroup` and `worksize` for launching a kernel over `dims`
on `grid`. The `workgroup` is a tuple specifying the threads per block in each
dimension. The `worksize` specifies the range of the loop in each dimension.

Specifying `include_right_boundaries=true` will ensure the work layout includes the
right face end points along bounded dimensions. This requires the field `location`
to be specified.

For more information, see: https://github.com/CliMA/Oceananigans.jl/pull/308
"""
@inline function work_layout(grid, workdims::Symbol, reduced_dimensions)
    valdims = Val(workdims)
    Nx, Ny, Nz = size(grid)
    Wx, Wy, Wz = flatten_reduced_dimensions((Nx, Ny, Nz), reduced_dimensions) # this seems to be for halo filling
    workgroup = heuristic_workgroup(Wx, Wy, Wz)
    worksize = drop_omitted_dims(valdims, (Wx, Wy, Wz))
    return workgroup, worksize
end

function work_layout(grid, worksize::NTuple{N, Int}, reduced_dimensions) where N
    workgroup = heuristic_workgroup(worksize...)
    return workgroup, worksize
end

function work_layout(grid, ::KernelParameters{spec, offsets}, reduced_dimensions) where {spec, offsets}
    workgroup, worksize = work_layout(grid, spec, reduced_dimensions)
    static_workgroup = StaticSize(workgroup)
    range = contiguousrange(worksize, offsets)
    offset_worksize = OffsetStaticSize(range)
    return static_workgroup, offset_worksize
end

"""
    configure_kernel(arch, grid, workspec, kernel!;
                     exclude_periphery = false,
                     reduced_dimensions = (),
                     location = nothing,
                     active_cells_map = nothing)

Configure `kernel!` to launch over the `dims` of `grid` on
the architecture `arch`.

Arguments
=========

- `arch`: The architecture on which the kernel will be launched.
- `grid`: The grid on which the kernel will be executed.
- `workspec`: The workspec that defines the work distribution.
- `kernel!`: The kernel function to be executed.

Keyword Arguments
=================

- `exclude_periphery`: A boolean indicating whether to exclude the periphery. Default is `false`.
- `reduced_dimensions`: A tuple specifying the dimensions to be reduced in the work distribution. Default is an empty tuple.
- `location`: The location of the kernel execution, needed for `include_right_boundaries`. Default is `nothing`.
- `active_cells_map`: A map indicating the active cells in the grid. If the map is not a nothing, the workspec will be disregarded and
                      the kernel is configured as a linear kernel with a worksize equal to the length of the active cell map. Default is `nothing`.
"""
@inline function configure_kernel(arch, grid, workspec, kernel!;
                                  exclude_periphery = false,
                                  reduced_dimensions = (),
                                  location = nothing,
                                  active_cells_map = nothing)


    if !isnothing(active_cells_map) # everything else is irrelevant
        workgroup = min(length(active_cells_map), 256)
        worksize = length(active_cells_map)
    elseif exclude_periphery && !(workspec isa KernelParameters) # TODO: support KernelParameters
        workgroup, worksize = interior_work_layout(grid, workspec, location)
    else
        workgroup, worksize = work_layout(grid, workspec, reduced_dimensions)
    end

    dev  = Architectures.device(arch)
    loop = kernel!(dev, workgroup, worksize)

    # Map out the function to use active_cells_map as an index map
    if !isnothing(active_cells_map)
        loop = mapped_kernel(loop, dev, active_cells_map)
    end

    return loop, worksize
end

@inline function mapped_kernel(kernel::Kernel{Dev, B, W}, dev, map) where {Dev, B, W}
    f  = kernel.f
    mf = MappedFunction(f, map)
    return Kernel{Dev, B, W, typeof(mf)}(dev, mf)
end

"""
    launch!(arch, grid, workspec, kernel!, kernel_args...; kw...)

Launches `kernel!` with arguments `kernel_args`
over the `dims` of `grid` on the architecture `arch`.
Kernels run on the default stream.

See [configure_kernel](@ref) for more information and also a list of the
keyword arguments `kw`.
"""
@inline launch!(args...; kwargs...) = _launch!(args...; kwargs...)

@inline launch!(arch, grid, workspec::NTuple{N, Int}, args...; kwargs...) where N =
    _launch!(arch, grid, workspec, args...; kwargs...)

@inline function launch!(arch, grid, workspec_tuple::Tuple, args...; kwargs...)
    for workspec in workspec_tuple
        _launch!(arch, grid, workspec, args...; kwargs...)
    end
    return nothing
end

# launching with an empty tuple has no effect
@inline function launch!(arch, grid, workspec_tuple::Tuple{}, kernel, args...; kwargs...)
    @warn "trying to launch kernel $kernel! with workspec == (). The kernel will not be launched."
    return nothing
end

# When dims::Val
@inline launch!(arch, grid, ::Val{workspec}, args...; kw...) where workspec =
    _launch!(arch, grid, workspec, args...; kw...)

# Inner interface
@inline function _launch!(arch, grid, workspec, kernel!, first_kernel_arg, other_kernel_args...;
                          exclude_periphery = false,
                          reduced_dimensions = (),
                          active_cells_map = nothing)

    location = Oceananigans.location(first_kernel_arg)

    loop!, worksize = configure_kernel(arch, grid, workspec, kernel!;
                                       location,
                                       exclude_periphery,
                                       reduced_dimensions,
                                       active_cells_map)

    # Don't launch kernels with no size
    haswork = if worksize isa OffsetStaticSize
        length(worksize) > 0
    elseif worksize isa Number
        worksize > 0
    else
        true
    end

    if haswork
        loop!(first_kernel_arg, other_kernel_args...)
    end

    return nothing
end

#####
##### Extension to KA for offset indices: to remove when implemented in KA
##### Allows to use `launch!` with offsets, e.g.:
##### `launch!(arch, grid, KernelParameters(size, offsets), kernel!; kernel_args...)`
##### where offsets is a tuple containing the offset to pass to @index
##### Note that this syntax is only usable in conjunction with the `launch!` function and
##### will have no effect if the kernel is launched with `kernel!` directly.
##### To achieve the same result with kernel launching, the correct syntax is:
##### `kernel!(arch, StaticSize(size), OffsetStaticSize(contiguousrange(size, offset)))`
##### Using offsets is (at the moment) incompatible with dynamic workgroup sizes: in case of offset dynamic kernels
##### offsets will have to be passed manually.
#####

# TODO: when offsets are implemented in KA so that we can call `kernel(dev, group, size, offsets)`, remove all of this
using KernelAbstractions.NDIteration: _Size, StaticSize
using KernelAbstractions.NDIteration: NDRange

using KernelAbstractions.NDIteration
using KernelAbstractions: ndrange, workgroupsize

using KernelAbstractions: __iterspace, __groupindex, __dynamic_checkbounds
using KernelAbstractions: CompilerMetadata

import KernelAbstractions: partition
import KernelAbstractions: __ndrange, __groupsize
import KernelAbstractions: __validindex

struct OffsetStaticSize{S} <: _Size
    function OffsetStaticSize{S}() where S
        new{S::Tuple{Vararg}}()
    end
end

@pure OffsetStaticSize(s::Tuple{Vararg{Int}}) = OffsetStaticSize{s}()
@pure OffsetStaticSize(s::Int...) = OffsetStaticSize{s}()
@pure OffsetStaticSize(s::Type{<:Tuple}) = OffsetStaticSize{tuple(s.parameters...)}()
@pure OffsetStaticSize(s::Tuple{Vararg{UnitRange{Int}}}) = OffsetStaticSize{s}()

# Some @pure convenience functions for `OffsetStaticSize` (following `StaticSize` in KA)
@pure get(::Type{OffsetStaticSize{S}}) where {S} = S
@pure get(::OffsetStaticSize{S}) where {S} = S
@pure Base.getindex(::OffsetStaticSize{S}, i::Int) where {S} = i <= length(S) ? S[i] : 1
@pure Base.ndims(::OffsetStaticSize{S}) where {S}  = length(S)
@pure Base.length(::OffsetStaticSize{S}) where {S} = prod(map(worksize, S))

@inline getrange(::OffsetStaticSize{S}) where {S} = worksize(S), offsets(S)
@inline getrange(::Type{OffsetStaticSize{S}}) where {S} = worksize(S), offsets(S)

@inline offsets(ranges::NTuple{N, UnitRange}) where N = Tuple(r.start - 1 for r in ranges)::NTuple{N}

@inline worksize(t::Tuple) = map(worksize, t)
@inline worksize(sz::Int) = sz
@inline worksize(r::AbstractUnitRange) = length(r)

const OffsetNDRange{N, S} = NDRange{N, <:StaticSize, <:StaticSize, <:Any, <:OffsetStaticSize{S}} where {N, S}

# NDRange has been modified to have offsets in place of workitems: Remember, dynamic offset kernels are not possible with this extension!!
# TODO: maybe don't do this
@inline function expand(ndrange::OffsetNDRange{N, S}, groupidx::CartesianIndex{N}, idx::CartesianIndex{N}) where {N, S}
    nI = ntuple(Val(N)) do I
        Base.@_inline_meta
        offsets = workitems(ndrange)
        stride = size(offsets, I)
        gidx = groupidx.I[I]
        (gidx - 1) * stride + idx.I[I] + S[I]
    end
    return CartesianIndex(nI)
end

@inline __ndrange(::CompilerMetadata{NDRange}) where {NDRange<:OffsetStaticSize}  = CartesianIndices(get(NDRange))
@inline __groupsize(cm::CompilerMetadata{NDRange}) where {NDRange<:OffsetStaticSize} = size(__ndrange(cm))

# Kernel{<:Any, <:StaticSize, <:StaticSize} and Kernel{<:Any, <:StaticSize, <:OffsetStaticSize} are the only kernels used by Oceananigans
const OffsetKernel = Kernel{<:Any, <:StaticSize, <:OffsetStaticSize}

# Extending the partition function to include offsets in NDRange: note that in this case the
# offsets take the place of the DynamicWorkitems which we assume is not needed in static kernels
function partition(kernel::OffsetKernel, inrange, ingroupsize)
    static_ndrange = ndrange(kernel)
    static_workgroupsize = workgroupsize(kernel)

    if inrange !== nothing && inrange != get(static_ndrange)
        error("Static NDRange ($static_ndrange) and launch NDRange ($inrange) differ")
    end

    range, offsets = getrange(static_ndrange)

    if static_workgroupsize <: StaticSize
        if ingroupsize !== nothing && ingroupsize != get(static_workgroupsize)
            error("Static WorkgroupSize ($static_workgroupsize) and launch WorkgroupSize $(ingroupsize) differ")
        end
        groupsize = get(static_workgroupsize)
    end

    @assert groupsize !== nothing
    @assert range !== nothing
    blocks, groupsize, dynamic = NDIteration.partition(range, groupsize)

    static_blocks = StaticSize{blocks}
    static_workgroupsize = StaticSize{groupsize} # we might have padded workgroupsize

    iterspace = NDRange{length(range), static_blocks, static_workgroupsize}(blocks, OffsetStaticSize(offsets))

    return iterspace, dynamic
end

#####
##### Utilities for Mapped kernels
#####

struct IndexMap end

const MappedNDRange{N, B, W} = NDRange{N, B, W, <:IndexMap, <:AbstractArray} where {N, B<:StaticSize, W<:StaticSize}

# TODO: maybe don't do this
# NDRange has been modified to include an index_map in place of workitems.
# Remember, dynamic kernels are not possible in combination with this extension!!
# Also, mapped kernels work only with a 1D kernel and a 1D map, it is not possible to launch a ND kernel.
@inline function expand(ndrange::MappedNDRange, groupidx::CartesianIndex{N}, idx::CartesianIndex{N}) where N
    nI = ntuple(Val(N)) do I
        Base.@_inline_meta
        offsets = workitems(ndrange)
        stride = size(offsets, I)
        gidx = groupidx.I[I]
        ndrange.workitems[(gidx - 1) * stride + idx.I[I]]
    end
    return CartesianIndex(nI...)
end

const MappedKernel{D} = Kernel{D, <:Any, <:Any, <:MappedFunction} where D

# Override the getproperty to make sure we launch the correct function in the kernel
@inline Base.getproperty(k::MappedKernel, prop::Symbol) = get_mapped_kernel_property(k, Val(prop))

@inline get_mapped_kernel_property(k, ::Val{prop}) where prop = getfield(k, prop)
@inline get_mapped_kernel_property(k, ::Val{:index_map}) = getfield(getfield(k, :f), :index_map)
@inline get_mapped_kernel_property(k, ::Val{:f})         = getfield(getfield(k, :f), :func)

Adapt.adapt_structure(to, ndrange::MappedNDRange{N, B, W}) where {N, B, W} =
    NDRange{N, B, W}(Adapt.adapt(to, ndrange.blocks), Adapt.adapt(to, ndrange.workitems))

# Extending the partition function to include the index_map in NDRange: note that in this case the
# index_map takes the place of the DynamicWorkitems which we assume is not needed in static kernels
function partition(kernel::MappedKernel, inrange, ingroupsize)
    static_workgroupsize = workgroupsize(kernel)

    # Calculate the static NDRange and WorkgroupSize
    index_map = kernel.index_map
    range = length(index_map)
    groupsize = get(static_workgroupsize)

    blocks, groupsize, dynamic = NDIteration.partition(range, groupsize)

    static_blocks = StaticSize{blocks}
    static_workgroupsize = StaticSize{groupsize} # we might have padded workgroupsize

    iterspace = NDRange{length(range), static_blocks, static_workgroupsize}(IndexMap(), index_map)

    return iterspace, dynamic
end

#####
##### Extend the valid index function to check whether the index is valid in the index map
#####

const MappedCompilerMetadata{N, C} = CompilerMetadata{N, C, <:Any, <:Any, <:MappedNDRange} where {N<:StaticSize, C}

Adapt.adapt_structure(to, cm::MappedCompilerMetadata{N, C}) where {N, C} =
    CompilerMetadata{N, C}(Adapt.adapt(to, cm.groupindex),
                           Adapt.adapt(to, cm.ndrange),
                           Adapt.adapt(to, cm.iterspace))

@inline __linear_ndrange(ctx::MappedCompilerMetadata) = length(__iterspace(ctx).workitems)

# Mapped kernels are always 1D
Base.@propagate_inbounds function linear_expand(ndrange::MappedNDRange, gidx::Integer, idx::Integer)
    offsets = workitems(ndrange)
    stride = size(offsets, 1)
    return (gidx - 1) * stride + idx
end

# Mapped kernels are always 1D
Base.@propagate_inbounds function linear_expand(ndrange::MappedNDRange, groupidx::CartesianIndex{1}, idx::CartesianIndex{1})
    offsets = workitems(ndrange)
    stride = size(offsets, 1)
    gidx = groupidx.I[1]
    return (gidx - 1) * stride + idx.I[1]
end

# To check whether the index is valid in the index map, we need to
# check whether the linear index is smaller than the size of the index map

# CPU version, the index is passed explicitly
@inline function __validindex(ctx::MappedCompilerMetadata, idx::CartesianIndex)
    # Turns this into a noop for code where we can turn of checkbounds of
    if __dynamic_checkbounds(ctx)
        index = @inbounds linear_expand(__iterspace(ctx), __groupindex(ctx), idx)
        return index ≤ __linear_ndrange(ctx)
    else
        return true
    end
end
