module Simulations

export TimeStepWizard, conjure_time_step_wizard!
export Simulation
export run!
export Callback, add_callback!
export iteration

using Oceananigans
using Oceananigans.OutputWriters
using Oceananigans.TimeSteppers
using Oceananigans.Utils

using Oceananigans.Advection: cell_advection_timescale
using Oceananigans: AbstractDiagnostic, AbstractOutputWriter, fields

using OrderedCollections: OrderedDict

import Base: show

# To be extended in the `Models` module
timestepper(model) = nothing

include("callback.jl")
include("simulation.jl")
include("run.jl")
include("time_step_wizard.jl")

end # module
