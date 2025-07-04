
@inline zerofunction(args...) = 0
@inline onefunction(args...) = 1

T_zerofunction = typeof(zerofunction)
T_onefunction = typeof(onefunction)

Base.summary(::T_zerofunction) = "0"
Base.summary(::T_onefunction) = "1"

"""
    struct Relaxation{R, M, T}

Callable object for restoring fields to a `target` at
some `rate` and within a `mask`ed region in `x, y, z`.
"""
struct Relaxation{R, M, T}
      rate :: R
      mask :: M
    target :: T
end

"""
    Relaxation(; rate, mask=onefunction, target=zerofunction)

Returns a `Forcing` that restores a field to `target(X..., t)`
at the specified `rate`, in the region `mask(X...)`.

The functions `onefunction` and `zerofunction` always return 1 and 0, respectively.
Thus the default `mask` leaves the whole domain uncovered, and the default `target` is zero.

Example
=======

* Restore a field to zero on a timescale of "3600" (equal
  to one hour if the time units of the simulation are seconds).

```jldoctest relaxation
using Oceananigans

damping = Relaxation(rate = 1/3600)

# output
Relaxation{Float64, typeof(Oceananigans.Forcings.onefunction), typeof(Oceananigans.Forcings.zerofunction)}
├── rate: 0.0002777777777777778
├── mask: 1
└── target: 0
```

* Restore a field to a linear z-gradient within the bottom 1/4 of a domain
  on a timescale of "60" (equal to one minute if the time units of the simulation
  are seconds).

```jldoctest relaxation
dTdz = 0.001 # ⁰C m⁻¹, temperature gradient

T₀ = 20 # ⁰C, surface temperature at z=0

Lz = 100 # m, depth of domain

bottom_sponge_layer = Relaxation(; rate = 1/60,
                                   target = LinearTarget{:z}(intercept=T₀, gradient=dTdz),
                                   mask = GaussianMask{:z}(center=-Lz, width=Lz/4))

# output
Relaxation{Float64, GaussianMask{:z, Float64}, LinearTarget{:z, Float64}}
├── rate: 0.016666666666666666
├── mask: exp(-(z + 100.0)^2 / (2 * 25.0^2))
└── target: 20.0 + 0.001 * z
```
"""
Relaxation(; rate, mask=onefunction, target=zerofunction) = Relaxation(rate, mask, target)

""" Wrap `forcing::Relaxation` in `ContinuousForcing` and add the appropriate field dependency. """
function regularize_forcing(forcing::Relaxation, field, field_name, model_field_names)
    continuous_relaxation = ContinuousForcing(forcing, field_dependencies=field_name)
    return regularize_forcing(continuous_relaxation, field, field_name, model_field_names)
end

@inline (f::Relaxation)(x, y, z, t, field) =
    f.rate * f.mask(x, y, z) * (f.target(x, y, z, t) - field)

@inline (f::Relaxation{R, M, <:Number})(x, y, z, t, field) where {R, M} =
    f.rate * f.mask(x, y, z) * (f.target - field)

# Methods for grids with Flat dimensions:
# Here, the meaning of the coordinate xₙ depends on which dimension is Flat:
# for example, in the below method (x₁, x₂) may be (ξ, η), (ξ, r), or (η, r), where
# ξ, η, and r are the first, second, and third coordinates respectively.
@inline (f::Relaxation)(x₁, x₂, t, field) =
    f.rate * f.mask(x₁, x₂) * (f.target(x₁, x₂, t) - field)

@inline (f::Relaxation{R, M, <:Number})(x₁, x₂, t, field) where {R, M} =
    f.rate * f.mask(x₁, x₂) * (f.target - field)

# Below, the coordinate x₁ can be ξ, η, or r (see above)
@inline (f::Relaxation)(x₁, t, field) =
    f.rate * f.mask(x₁) * (f.target(x₁, t) - field)

@inline (f::Relaxation{R, M, <:Number})(x₁, t, field) where {R, M} =
    f.rate * f.mask(x₁) * (f.target - field)

"""Show the innards of a `Relaxation` in the REPL."""
Base.show(io::IO, relaxation::Relaxation{R, M, T}) where {R, M, T} =
    print(io, "Relaxation{$R, $M, $T}", "\n",
        "├── rate: $(relaxation.rate)", "\n",
        "├── mask: $(summary(relaxation.mask))", "\n",
        "└── target: $(summary(relaxation.target))")

Base.summary(relaxation::Relaxation) =
    "Relaxation(rate=$(relaxation.rate), mask=$(summary(relaxation.mask)), target=$(summary(relaxation.target)))"

#####
##### Sponge layer functions
#####

"""
    GaussianMask{D}(center, width)

Callable object that returns a Gaussian masking function centered on
`center`, with `width`, and varying along direction `D`, i.e.,

```
exp(-(D - center)^2 / (2 * width^2))
```

Example
=======

Create a Gaussian mask centered on `z=0` with width `1` meter.

```jldoctest
julia> using Oceananigans

julia> mask = GaussianMask{:z}(center=0, width=1)
GaussianMask{:z, Int64}(0, 1)
```
"""
struct GaussianMask{D, T}
    center :: T
     width :: T

    function GaussianMask{D}(; center, width) where D
        T = promote_type(typeof(center), typeof(width))
        return new{D, T}(center, width)
    end
end

@inline (g::GaussianMask{:x})(x, y, z) = exp(-(x - g.center)^2 / (2 * g.width^2))
@inline (g::GaussianMask{:y})(x, y, z) = exp(-(y - g.center)^2 / (2 * g.width^2))
@inline (g::GaussianMask{:z})(x, y, z) = exp(-(z - g.center)^2 / (2 * g.width^2))

show_exp_arg(D, c) = c == 0 ? "$D^2" :
                     c > 0  ? "($D - $c)^2" :
                              "($D + $(-c))^2"

Base.summary(g::GaussianMask{D}) where D =
    "exp(-$(show_exp_arg(D, g.center)) / (2 * $(g.width)^2))"


"""
    PiecewiseLinearMask{D}(center, width)

Callable object that returns a piecewise linear masking function centered on
`center`, with `width`, and varying along direction `D`. The mask is:
- 0 when |D - center| > width
- 1 when D = center
- Linear interpolation between 0 and 1 when |D - center| ≤ width

Example
=======

Create a piecewise linear mask centered on `z=0` with width `1` meter.

```jldoctest
julia> using Oceananigans

julia> mask = PiecewiseLinearMask{:z}(center=0, width=1)
PiecewiseLinearMask{:z, Int64}(0, 1)

julia> mask(0, 0, 0) == 1
true

julia> mask(0, 0, 1) == mask(0, 0, -1) == 0
true
```
"""
struct PiecewiseLinearMask{D, T}
    center :: T
     width :: T

    function PiecewiseLinearMask{D}(; center, width) where D
        T = promote_type(typeof(center), typeof(width))
        return new{D, T}(center, width)
    end
end

@inline function (p::PiecewiseLinearMask{:x})(x, y, z)
    d = 1 - abs(x - p.center) / p.width
    return max(0, d)
end

@inline function (p::PiecewiseLinearMask{:y})(x, y, z)
    d = 1 - abs(y - p.center) / p.width
    return max(0, d)
end

@inline function (p::PiecewiseLinearMask{:z})(x, y, z)
    d = 1 - abs(z - p.center) / p.width
    return max(0, d)
end

Base.summary(p::PiecewiseLinearMask{D}) where D =
    "piecewise_linear($D, center=$(p.center), width=$(p.width))"


#####
##### Linear target functions
#####

"""
    LinearTarget{D}(intercept, gradient)

Callable object that returns a Linear target function
with `intercept` and `gradient`, and varying along direction `D`, i.e.,

```
intercept + D * gradient
```

Example
=======

Create a linear target function varying in `z`, equal to `0` at
`z=0` and with gradient 10⁻⁶:

```julia
julia> target = LinearTarget{:z}(intercept=0, gradient=1e-6)
```
"""
struct LinearTarget{D, T}
    intercept :: T
     gradient :: T

    function LinearTarget{D}(; intercept, gradient) where D
        T = promote_type(typeof(gradient), typeof(intercept))
        return new{D, T}(intercept, gradient)
    end
end

@inline (p::LinearTarget{:x})(x, y, z, t) = p.intercept + p.gradient * x
@inline (p::LinearTarget{:y})(x, y, z, t) = p.intercept + p.gradient * y
@inline (p::LinearTarget{:z})(x, y, z, t) = p.intercept + p.gradient * z

Base.summary(l::LinearTarget{:x}) = "$(l.intercept) + $(l.gradient) * x"
Base.summary(l::LinearTarget{:y}) = "$(l.intercept) + $(l.gradient) * y"
Base.summary(l::LinearTarget{:z}) = "$(l.intercept) + $(l.gradient) * z"
