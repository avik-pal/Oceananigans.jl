using Oceananigans.Grids: inactive_node, new_data

struct PolarValue{D, S}
    data :: D
    side :: S
end

Adapt.adapt_structure(to, pv::PolarValue) = PolarValue(Adapt.adapt(to, pv.data), nothing)

const PolarValueBoundaryCondition{V} = BoundaryCondition{<:Value, <:PolarValue}
const PolarOpenBoundaryCondition{V}  = BoundaryCondition{<:Open,  <:PolarValue}

function PolarValueBoundaryCondition(grid, side, LZ)
    FT   = eltype(grid)
    loc  = (Nothing, Nothing, LZ)
    data = new_data(FT, grid, loc)
    return ValueBoundaryCondition(PolarValue(data, side))
end

function PolarOpenBoundaryCondition(grid, side, LZ)
    FT   = eltype(grid)
    loc  = (Nothing, Nothing, LZ)
    data = new_data(FT, grid, loc)
    return OpenBoundaryCondition(PolarValue(data, side))
end

const PolarBoundaryCondition = Union{PolarValueBoundaryCondition, PolarOpenBoundaryCondition}

maybe_polar_boundary_condition(grid, side, ::Nothing, ℓz::LZ) where LZ = nothing
maybe_polar_boundary_condition(grid, side, ::Center,  ℓz::LZ) where LZ = PolarValueBoundaryCondition(grid, side, LZ)
maybe_polar_boundary_condition(grid, side, ::Face,    ℓz::LZ) where LZ = PolarOpenBoundaryCondition(grid, side, LZ)

# Just a column
@inline getbc(pv::PolarValue, i, k, args...) = @inbounds pv.data[1, 1, k]

@kernel function _average_pole_value!(data, c, j, grid, loc)
    i′, j′, k = @index(Global, NTuple)
    c̄ = zero(grid)
    n = 0
    @inbounds for i in 1:grid.Nx
        inactive = inactive_node(i, j, k, grid, loc...)
        c̄ += ifelse(inactive, 0, c[i, j, k])
        n += ifelse(inactive, 0, 1)
    end
    @inbounds data[i′, j′, k] = ifelse(n == 0,  0,  c̄ / n)
end

function update_pole_value!(bc::PolarValue, c, grid, loc)
    j = bc.side == :north ? grid.Ny : 1
    Nz = size(c, 3)
    Oz = c.offsets[3]
    params = KernelParameters(1:1, 1:1, 1+Oz:Nz+Oz)
    launch!(architecture(grid), grid, params, _average_pole_value!, bc.data, c, j, grid, loc)
    return nothing
end

function fill_south_halo!(c, bc::PolarBoundaryCondition, size, offset, loc, arch, grid, args...; only_local_halos=false, kwargs...)
    update_pole_value!(bc.condition, c, grid, loc)
    return launch!(arch, grid, KernelParameters(size, offset),
                   _fill_only_south_halo!, c, bc, loc, grid, Tuple(args); kwargs...)
end

function fill_north_halo!(c, bc::PolarBoundaryCondition, size, offset, loc, arch, grid, args...; only_local_halos=false, kwargs...)
    update_pole_value!(bc.condition, c, grid, loc)
    return launch!(arch, grid, KernelParameters(size, offset),
                   _fill_only_north_halo!, c, bc, loc, grid, Tuple(args); kwargs...)
end

function fill_south_and_north_halo!(c, south_bc::PolarBoundaryCondition, north_bc, size, offset, loc, arch, grid, args...; only_local_halos=false, kwargs...)
    update_pole_value!(south_bc.condition, c, grid, loc)
    return launch!(arch, grid, KernelParameters(size, offset),
                   _fill_south_and_north_halo!, c, south_bc, north_bc, loc, grid, Tuple(args); kwargs...)
end

function fill_south_and_north_halo!(c, south_bc, north_bc::PolarBoundaryCondition, size, offset, loc, arch, grid, args...; only_local_halos=false, kwargs...)
    update_pole_value!(north_bc.condition, c, grid, loc)
    return launch!(arch, grid, KernelParameters(size, offset),
                   _fill_south_and_north_halo!, c, south_bc, north_bc, loc, grid, Tuple(args); kwargs...)
end

function fill_south_and_north_halo!(c, south_bc::PolarBoundaryCondition, north_bc::PolarBoundaryCondition, size, offset, loc, arch, grid, args...; only_local_halos=false, kwargs...)
    update_pole_value!(south_bc.condition, c, grid, loc)
    update_pole_value!(north_bc.condition, c, grid, loc)
    return launch!(arch, grid, KernelParameters(size, offset),
                   _fill_south_and_north_halo!, c, south_bc, north_bc, loc, grid, Tuple(args); kwargs...)
end


