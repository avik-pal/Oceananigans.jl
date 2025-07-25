module AbstractOperations

export ∂x, ∂y, ∂z, @at, @unary, @binary, @multiary
export Δx, Δy, Δz, Ax, Ay, Az, volume
export Average, Integral, CumulativeIntegral, KernelFunctionOperation
export UnaryOperation, Derivative, BinaryOperation, MultiaryOperation, ConditionalOperation


using Base: @propagate_inbounds

using Oceananigans.Architectures
using Oceananigans.Grids
using Oceananigans.Operators
using Oceananigans.BoundaryConditions
using Oceananigans.Fields
using Oceananigans.Utils

using Oceananigans: location, AbstractModel
using Oceananigans.Operators: interpolation_operator
using Oceananigans.Architectures: device

import Adapt

import Oceananigans.Architectures: architecture, on_architecture
import Oceananigans.BoundaryConditions: fill_halo_regions!
import Oceananigans.Fields: compute_at!, indices

#####
##### Basic functionality
#####

abstract type AbstractOperation{LX, LY, LZ, G, T} <: AbstractField{LX, LY, LZ, G, T, 3} end

const AF = AbstractField # used in unary_operations.jl, binary_operations.jl, etc

# We have no halos to fill
@inline fill_halo_regions!(::AbstractOperation, args...; kwargs...) = nothing

architecture(a::AbstractOperation) = architecture(a.grid)

# AbstractOperation macros add their associated functions to this list
const operators = Set()

"""
    at(loc, abstract_operation)

Return `abstract_operation` relocated to `loc`ation.
"""
at(loc, f) = f # fallback

include("grid_validation.jl")
include("grid_metrics.jl")
include("metric_field_reductions.jl")
include("unary_operations.jl")
include("binary_operations.jl")
include("multiary_operations.jl")
include("derivatives.jl")
include("constant_field_abstract_operations.jl")
include("kernel_function_operation.jl")
include("conditional_operations.jl")
include("computed_field.jl")
include("at.jl")
include("broadcasting_abstract_operations.jl")
include("show_abstract_operations.jl")

# Make some operators!

# Some operators:
import Base: -, +, /, ^, *
import Base: sqrt, sin, cos, exp, tanh, abs
import Base: log10, log, tan, sinh, cosh

@unary sqrt sin cos exp tanh abs log10 log tan sinh cosh
@unary -
@unary +

@binary +
@binary -
@binary /
@binary ^

@multiary +

# For unknown reasons, the operator definition macros @binary and @multiary fail to work
# properly for :*. We thus manually define :* for fields.
import Base: *

eval(define_binary_operator(:*))
push!(operators, :*)
push!(binary_operators, :*)

eval(define_multiary_operator(:*))
push!(operators, :*)
push!(multiary_operators, :*)

end # module
