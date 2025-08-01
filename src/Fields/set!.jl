using KernelAbstractions: @kernel, @index
using Adapt: adapt_structure

using Oceananigans.Grids: on_architecture, node_names
using Oceananigans.Architectures: child_architecture, cpu_architecture, device, GPU, CPU
using Oceananigans.Utils: work_layout

#####
##### Utilities
#####

function tuple_string(tup::Tuple)
    str = prod(string(t, ", ") for t in tup)
    return str[1:end-2] # remove trailing ", "
end

tuple_string(tup::Tuple{}) = ""

#####
##### set!
#####

set!(obj, ::Nothing) = nothing

function set!(Φ::NamedTuple; kwargs...)
    for (fldname, value) in kwargs
        ϕ = getproperty(Φ, fldname)
        set!(ϕ, value)
    end
    return nothing
end

# This interface helps us do things like set distributed fields
set!(u::Field, f::Function) = set_to_function!(u, f)
set!(u::Field, a::Union{Array, OffsetArray}) = set_to_array!(u, a)
set!(u::Field, v::Field) = set_to_field!(u, v)

function set!(u::Field, a::Number)
    fill!(interior(u), a) # note all other set! only change interior
    return u # return u, not parent(u), for type-stability
end

function set!(u::Field, v)
    u .= v # fallback
    return u
end

set!(u::Field, z::ZeroField) = set!(u, zero(eltype(u)))

#####
##### Setting to specific things
#####

function set_to_function!(u, f)
    # Supports serial and distributed
    arch = architecture(u)
    child_arch = child_architecture(u)

    # Determine cpu_grid and cpu_u
    if child_arch isa GPU || child_arch isa ReactantState
        cpu_arch = cpu_architecture(arch)
        cpu_grid = on_architecture(cpu_arch, u.grid)
        cpu_u    = Field(instantiated_location(u), cpu_grid; indices = indices(u))

    elseif child_arch isa CPU
        cpu_grid = u.grid
        cpu_u = u
    end

    # Form a FunctionField from `f`
    f_field = field(location(u), f, cpu_grid)

    # Try to set the FunctionField to cpu_u
    try
        set!(cpu_u, f_field)
    catch err
        u_loc = Tuple(L() for L in location(u))

        arg_str  = tuple_string(node_names(u.grid, u_loc...))
        loc_str  = tuple_string(location(u))
        topo_str = tuple_string(topology(u.grid))

        msg = string("An error was encountered within set! while setting the field", '\n', '\n',
                     "    ", prettysummary(u), '\n', '\n',
                     "Note that to use set!(field, func::Function) on a field at location ",
                     "(", loc_str, ")", '\n',
                     "and on a grid with topology (", topo_str, "), func must be ",
                     "callable via", '\n', '\n',
                     "     func(", arg_str, ")", '\n')
        @warn msg
        throw(err)
    end

    # Transfer data to GPU if u is on the GPU
    if child_arch isa GPU || child_arch isa ReactantState
    	set!(u, cpu_u)
    end
    return u
end

function set_to_array!(u, a)
    a = on_architecture(architecture(u), a)

    try
        copyto!(interior(u), a)
    catch err
        if err isa DimensionMismatch
            Nx, Ny, Nz = size(u)
            u .= reshape(a, Nx, Ny, Nz)

            msg = string("Reshaped ", summary(a),
                         " to set! its data to ", '\n',
                         summary(u))
            @warn msg
        else
            throw(err)
        end
    end

    return u
end

function set_to_field!(u, v)
    # We implement some niceities in here that attempt to copy halo data,
    # and revert to copying just interior points if that fails.

    if child_architecture(u) === child_architecture(v)
        # Note: we could try to copy first halo point even when halo
        # regions are a different size. That's a bit more complicated than
        # the below so we leave it for the future.

        try # to copy halo regions along with interior data
            parent(u) .= parent(v)
        catch # this could fail if the halo regions are different sizes?
            # copy just the interior data
            interior(u) .= interior(v)
        end
    else
        v_data = on_architecture(child_architecture(u), v.data)

        # As above, we permit ourselves a little ambition and try to copy halo data:
        try
            parent(u) .= parent(v_data)
        catch
            interior(u) .= interior(v_data, location(v), v.grid, v.indices)
        end
    end

    return u
end

Base.copyto!(f::Field, src::Base.Broadcast.Broadcasted) = copyto!(interior(f), src)
Base.copyto!(f::Field, src::AbstractArray) = copyto!(interior(f), src)
Base.copyto!(f::Field, src::Field) = copyto!(parent(f), parent(src))

