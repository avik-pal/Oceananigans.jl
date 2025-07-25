using Oceananigans.Utils: prettysummary

struct FunctionField{LX, LY, LZ, C, P, F, G, T} <: AbstractField{LX, LY, LZ, G, T, 3}
          func :: F
          grid :: G
         clock :: C
    parameters :: P

    @doc """
        FunctionField{LX, LY, LZ}(func, grid; clock=nothing, parameters=nothing) where {LX, LY, LZ}

    Returns a `FunctionField` on `grid` and at location `LX, LY, LZ`.

    If `clock` is not specified, then `func` must be a function with signature
    `func(x, y, z)`. If clock is specified, `func` must be a function with signature
    `func(x, y, z, t)`, where `t` is internally determined from `clock.time`.

    A `FunctionField` will return the result of `func(x, y, z [, t])` at `LX, LY, LZ` on
    `grid` when indexed at `i, j, k`.
    """
    @inline function FunctionField{LX, LY, LZ}(func::F,
                                               grid::G;
                                               clock::C=nothing,
                                               parameters::P=nothing) where {LX, LY, LZ, F, G, C, P}
        FT = eltype(grid)
        return new{LX, LY, LZ, C, P, F, G, FT}(func, grid, clock, parameters)
    end

    @inline function FunctionField{LX, LY, LZ}(f::FunctionField,
                                               grid::G;
                                               clock::C=nothing) where {LX, LY, LZ, G, C}
        P = typeof(f.parameters)
        T = eltype(grid)
        F = typeof(f.func)
        return new{LX, LY, LZ, C, P, F, G, T}(f.func, grid, clock, f.parameters)
    end
end

Adapt.parent_type(T::Type{<:FunctionField}) = T

"""Return `a`, or convert `a` to `FunctionField` if `a::Function`"""
fieldify_function(L, a, grid) = a
fieldify_function(L, a::Function, grid) = FunctionField(L, a, grid)

# This is a convenience form with `L` as positional argument.
@inline FunctionField(L::Tuple{<:Type, <:Type, <:Type}, func, grid) = FunctionField{L[1], L[2], L[3]}(func, grid)
@inline FunctionField(L::Tuple{LX, LY, LZ}, func, grid) where {LX, LY, LZ}= FunctionField{LX, LY, LZ}(func, grid)

@inline indices(::FunctionField) = (:, :, :)

# Various possibilities for calling FunctionField.func:
@inline call_func(clock,     parameters, func, x...) = func(x..., clock.time, parameters)
@inline call_func(clock,     ::Nothing,  func, x...) = func(x..., clock.time)
@inline call_func(::Nothing, parameters, func, x...) = func(x..., parameters)
@inline call_func(::Nothing, ::Nothing,  func, x...) = func(x...)

@inline Base.getindex(f::FunctionField{LX, LY, LZ}, i, j, k) where {LX, LY, LZ} =
    call_func(f.clock, f.parameters, f.func, node(i, j, k, f.grid, LX(), LY(), LZ())...)

@inline (f::FunctionField)(x...) = call_func(f.clock, f.parameters, f.func, x...)

Adapt.adapt_structure(to, f::FunctionField{LX, LY, LZ}) where {LX, LY, LZ} =
    FunctionField{LX, LY, LZ}(Adapt.adapt(to, f.func),
                           Adapt.adapt(to, f.grid),
                           clock = Adapt.adapt(to, f.clock),
                           parameters = Adapt.adapt(to, f.parameters))


on_architecture(to, f::FunctionField{LX, LY, LZ}) where {LX, LY, LZ} =
    FunctionField{LX, LY, LZ}(on_architecture(to, f.func),
                              on_architecture(to, f.grid),
                              clock = on_architecture(to, f.clock),
                              parameters = on_architecture(to, f.parameters))

Base.show(io::IO, field::FunctionField) =
    print(io, "FunctionField located at ", show_location(field), "\n",
          "├── func: $(prettysummary(field.func))", "\n",
          "├── grid: $(summary(field.grid))\n",
          "├── clock: $(summary(field.clock))\n",
          "└── parameters: $(field.parameters)")

