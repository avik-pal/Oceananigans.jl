# # Two dimensional turbulence example
#
# In this example, we initialize a random velocity field and observe its turbulent decay
# in a two-dimensional domain. This example demonstrates:
#
#   * How to run a model with no tracers and no buoyancy model.
#   * How to use computed `Field`s to generate output.

# ## Install dependencies
#
# First let's make sure we have all required packages installed.

# ```julia
# using Pkg
# pkg"add Oceananigans, CairoMakie"
# ```

# ## Model setup

# We instantiate the model with an isotropic diffusivity. We use a grid with 128² points,
# a fifth-order advection scheme, third-order Runge-Kutta time-stepping,
# and a small isotropic viscosity.  Note that we assign `Flat` to the `z` direction.

using Oceananigans

grid = RectilinearGrid(size=(128, 128), extent=(2π, 2π), topology=(Periodic, Periodic, Flat))

model = NonhydrostaticModel(; grid,
                            advection = UpwindBiased(order=5),
                            closure = ScalarDiffusivity(ν=1e-5))

# ## Random initial conditions
#
# Our initial condition randomizes `model.velocities.u` and `model.velocities.v`.
# We ensure that both have zero mean for aesthetic reasons.

using Statistics

u, v, w = model.velocities

uᵢ = rand(size(u)...)
vᵢ = rand(size(v)...)

uᵢ .-= mean(uᵢ)
vᵢ .-= mean(vᵢ)

set!(model, u=uᵢ, v=vᵢ)

# ## Setting up a simulation
#
# We set-up a simulation that stops at 50 time units, with an initial
# time-step of 0.1, and with adaptive time-stepping and progress printing.

simulation = Simulation(model, Δt=0.2, stop_time=50)

# The `TimeStepWizard` helps ensure stable time-stepping
# with a Courant-Freidrichs-Lewy (CFL) number of 0.7.

wizard = TimeStepWizard(cfl=0.7, max_change=1.1, max_Δt=0.5)
simulation.callbacks[:wizard] = Callback(wizard, IterationInterval(10))

# ## Logging simulation progress
#
# We set up a callback that logs the simulation iteration and time every 100 iterations.

using Printf

function progress_message(sim)
    max_abs_u = maximum(abs, sim.model.velocities.u)
    walltime = prettytime(sim.run_wall_time)

    return @info @sprintf("Iteration: %04d, time: %1.3f, Δt: %.2e, max(|u|) = %.1e, wall time: %s\n",
                          iteration(sim), time(sim), sim.Δt, max_abs_u, walltime)
end

add_callback!(simulation, progress_message, IterationInterval(100))

# ## Output
#
# We set up an output writer for the simulation that saves vorticity and speed every 20 iterations.
#
# ### Computing vorticity and speed
#
# To make our equations prettier, we unpack `u`, `v`, and `w` from
# the `NamedTuple` model.velocities:
u, v, w = model.velocities

# Next we create two `Field`s that calculate
# _(i)_ vorticity that measures the rate at which the fluid rotates
# and is defined as
#
# ```math
# ω = ∂_x v - ∂_y u \, ,
# ```

ω = ∂x(v) - ∂y(u)

# We also calculate _(ii)_ the _speed_ of the flow,
#
# ```math
# s = \sqrt{u^2 + v^2} \, .
# ```

s = sqrt(u^2 + v^2)

# We pass these operations to an output writer below to calculate and output them during the simulation.
filename = "two_dimensional_turbulence"

simulation.output_writers[:fields] = JLD2Writer(model, (; ω, s),
                                                schedule = TimeInterval(0.6),
                                                filename = filename * ".jld2",
                                                overwrite_existing = true)

# ## Running the simulation
#
# Pretty much just

run!(simulation)

# ## Visualizing the results
#
# We load the output.

ω_timeseries = FieldTimeSeries(filename * ".jld2", "ω")
s_timeseries = FieldTimeSeries(filename * ".jld2", "s")

times = ω_timeseries.times
nothing #hide

# and animate the vorticity and fluid speed.

using CairoMakie
set_theme!(Theme(fontsize = 20))

fig = Figure(size = (800, 500))

axis_kwargs = (xlabel = "x",
               ylabel = "y",
               limits = ((0, 2π), (0, 2π)),
               aspect = AxisAspect(1))

ax_ω = Axis(fig[2, 1]; title = "Vorticity", axis_kwargs...)
ax_s = Axis(fig[2, 2]; title = "Speed", axis_kwargs...)
nothing #hide

# We use Makie's `Observable` to animate the data. To dive into how `Observable`s work we
# refer to [Makie.jl's Documentation](https://docs.makie.org/stable/explanations/observables).

n = Observable(1)

# Now let's plot the vorticity and speed.

ω = @lift ω_timeseries[$n]
s = @lift s_timeseries[$n]

heatmap!(ax_ω, ω; colormap = :balance, colorrange = (-2, 2))
heatmap!(ax_s, s; colormap = :speed, colorrange = (0, 0.2))

title = @lift "t = " * string(round(times[$n], digits=2))
Label(fig[1, 1:2], title, fontsize=24, tellwidth=false)

current_figure() #hide
fig

# Finally, we record a movie.

frames = 1:length(times)

@info "Making a neat animation of vorticity and speed..."

record(fig, filename * ".mp4", frames, framerate=24) do i
    n[] = i
end
nothing #hide

# ![](two_dimensional_turbulence.mp4)
