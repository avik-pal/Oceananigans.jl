# # [Wind- and convection-driven mixing in an ocean surface boundary layer](@id gpu_example)
#
# This example simulates mixing by three-dimensional turbulence in an ocean surface
# boundary layer driven by atmospheric winds and convection. It demonstrates:
#
#   * How to set-up a grid with varying spacing in the vertical direction
#   * How to use the `SeawaterBuoyancy` model for buoyancy with `TEOS10EquationOfState`.
#   * How to use a turbulence closure for large eddy simulation.
#   * How to use a function to impose a boundary condition.
#
# ## Install dependencies
#
# First let's make sure we have all required packages installed.

# ```julia
# using Pkg
# pkg"add Oceananigans, CairoMakie, SeawaterPolynomials, CUDA"
# ```

# We start by importing all of the packages and functions that we'll need for this
# example.

using Oceananigans
using Oceananigans.Units

using CUDA
using Random
using Printf
using CairoMakie
using SeawaterPolynomials.TEOS10: TEOS10EquationOfState

# ## The grid
#
# We use 128²×64 grid points with 1 m grid spacing in the horizontal and
# varying spacing in the vertical, with higher resolution closer to the
# surface. Here we use a stretching function for the vertical nodes that
# maintains relatively constant vertical spacing in the mixed layer, which
# is desirable from a numerical standpoint:

Nx = Ny = 128    # number of points in each of horizontal directions
Nz = 64          # number of points in the vertical direction

Lx = Ly = 128    # (m) domain horizontal extents
Lz = 64          # (m) domain depth

refinement = 1.2 # controls spacing near surface (higher means finer spaced)
stretching = 12  # controls rate of stretching at bottom

## Normalized height ranging from 0 to 1
h(k) = (k - 1) / Nz

## Linear near-surface generator
ζ₀(k) = 1 + (h(k) - 1) / refinement

## Bottom-intensified stretching function
Σ(k) = (1 - exp(-stretching * h(k))) / (1 - exp(-stretching))

## Generating function
z_interfaces(k) = Lz * (ζ₀(k) * Σ(k) - 1)

grid = RectilinearGrid(GPU(),
                       size = (Nx, Nx, Nz),
                       x = (0, Lx),
                       y = (0, Ly),
                       z = z_interfaces)

# We plot vertical spacing versus depth to inspect the prescribed grid stretching:

fig = Figure(size=(1200, 800))
ax = Axis(fig[1, 1], ylabel = "z (m)", xlabel = "Vertical spacing (m)")

lines!(ax, zspacings(grid, Center()))
scatter!(ax, zspacings(grid, Center()))

current_figure() #hide
fig

# ## Buoyancy that depends on temperature and salinity
#
# We use the `SeawaterBuoyancy` model with the TEOS10 equation of state,

ρₒ = 1026 # kg m⁻³, average density at the surface of the world ocean
equation_of_state = TEOS10EquationOfState(reference_density=ρₒ)
buoyancy = SeawaterBuoyancy(; equation_of_state)

# ## Boundary conditions
#
# We calculate the surface temperature flux associated with surface cooling of
# 200 W m⁻², reference density `ρₒ`, and heat capacity `cᴾ`,

Q = 200   # W m⁻², surface _heat_ flux
cᴾ = 3991 # J K⁻¹ kg⁻¹, typical heat capacity for seawater

Jᵀ = Q / (ρₒ * cᴾ) # K m s⁻¹, surface _temperature_ flux

# Finally, we impose a temperature gradient `dTdz` both initially (see "Initial conditions"
# section below) and at the bottom of the domain, culminating in the boundary conditions on
# temperature,

dTdz = 0.01 # K m⁻¹

T_bcs = FieldBoundaryConditions(top = FluxBoundaryCondition(Jᵀ),
                                bottom = GradientBoundaryCondition(dTdz))

# Note that a positive temperature flux at the surface of the ocean
# implies cooling. This is because a positive temperature flux implies
# that temperature is fluxed upwards, out of the ocean.
#
# For the velocity field, we imagine a wind blowing over the ocean surface
# with an average velocity at 10 meters `u₁₀`, and use a drag coefficient `cᴰ`
# to estimate the kinematic stress (that is, stress divided by density) exerted
# by the wind on the ocean:

u₁₀ = 10  # m s⁻¹, average wind velocity 10 meters above the ocean
cᴰ = 2e-3 # dimensionless drag coefficient
ρₐ = 1.2  # kg m⁻³, approximate average density of air at sea-level
τx = - ρₐ / ρₒ * cᴰ * u₁₀ * abs(u₁₀) # m² s⁻²

# The boundary conditions on `u` are thus

u_bcs = FieldBoundaryConditions(top = FluxBoundaryCondition(τx))

# For salinity, `S`, we impose an evaporative flux of the form

@inline Jˢ(x, y, t, S, evaporation_rate) = - evaporation_rate * S # [salinity unit] m s⁻¹
nothing #hide

# where `S` is salinity. We use an evaporation rate of 1 millimeter per hour,

evaporation_rate = 1e-3 / hour # m s⁻¹

# We build the `Flux` evaporation `BoundaryCondition` with the function `Jˢ`,
# indicating that `Jˢ` depends on salinity `S` and passing
# the parameter `evaporation_rate`,

evaporation_bc = FluxBoundaryCondition(Jˢ, field_dependencies=:S, parameters=evaporation_rate)

# The full salinity boundary conditions are

S_bcs = FieldBoundaryConditions(top=evaporation_bc)

# ## Model instantiation
#
# We fill in the final details of the model here, i.e., Coriolis forces,
# and the `AnisotropicMinimumDissipation` closure for large eddy simulation
# to model the effect of turbulent motions at scales smaller than the grid scale
# that are not explicitly resolved.

model = NonhydrostaticModel(; grid, buoyancy,
                            tracers = (:T, :S),
                            coriolis = FPlane(f=1e-4),
                            closure = AnisotropicMinimumDissipation(),
                            boundary_conditions = (u=u_bcs, T=T_bcs, S=S_bcs))

# Note: To use the Smagorinsky-Lilly turbulence closure (with a constant model coefficient) rather than
# `AnisotropicMinimumDissipation`, use `closure = SmagorinskyLilly()` in the model constructor.

# ## Initial conditions
#
# Our initial condition for temperature consists of a linear stratification superposed with
# random noise damped at the walls, while our initial condition for velocity consists
# only of random noise.

## Random noise damped at top and bottom
Ξ(z) = randn() * z / model.grid.Lz * (1 + z / model.grid.Lz) # noise

## Temperature initial condition: a stable density gradient with random noise superposed.
Tᵢ(x, y, z) = 20 + dTdz * z + dTdz * model.grid.Lz * 1e-6 * Ξ(z)

## Velocity initial condition: random noise scaled by the friction velocity.
uᵢ(x, y, z) = sqrt(abs(τx)) * 1e-3 * Ξ(z)

## `set!` the `model` fields using functions or constants:
set!(model, u=uᵢ, w=uᵢ, T=Tᵢ, S=35)

# ## Setting up a simulation
#
# We set-up a simulation with an initial time-step of 10 seconds
# that stops at 2 hours, with adaptive time-stepping and progress printing.

simulation = Simulation(model, Δt=10, stop_time=2hours)

# The `TimeStepWizard` helps ensure stable time-stepping
# with a Courant-Freidrichs-Lewy (CFL) number of 1.0.

wizard = TimeStepWizard(cfl=1, max_change=1.1, max_Δt=1minute)
simulation.callbacks[:wizard] = Callback(wizard, IterationInterval(10))

# Nice progress messaging is helpful:

## Print a progress message
progress_message(sim) = @printf("Iteration: %04d, time: %s, Δt: %s, max(|w|) = %.1e ms⁻¹, wall time: %s\n",
                                iteration(sim), prettytime(sim), prettytime(sim.Δt),
                                maximum(abs, sim.model.velocities.w), prettytime(sim.run_wall_time))

add_callback!(simulation, progress_message, IterationInterval(40))

# We then set up the simulation:

# ## Output
#
# We use the `JLD2Writer` to save ``x, z`` slices of the velocity fields,
# tracer fields, and eddy diffusivities. The `prefix` keyword argument
# to `JLD2Writer` indicates that output will be saved in
# `ocean_wind_mixing_and_convection.jld2`.

## Create a NamedTuple with eddy viscosity
eddy_viscosity = (; νₑ = model.diffusivity_fields.νₑ)

filename = "ocean_wind_mixing_and_convection"

simulation.output_writers[:slices] =
    JLD2Writer(model, merge(model.velocities, model.tracers, eddy_viscosity),
               filename = filename * ".jld2",
               indices = (:, grid.Ny/2, :),
               schedule = TimeInterval(1minute),
               overwrite_existing = true)

# We're ready:

run!(simulation)

# ## Turbulence visualization
#
# We animate the data saved in `ocean_wind_mixing_and_convection.jld2`.
# We prepare for animating the flow by loading the data into
# `FieldTimeSeries` and defining functions for computing colorbar limits.

filepath = filename * ".jld2"

time_series = (w = FieldTimeSeries(filepath, "w"),
               T = FieldTimeSeries(filepath, "T"),
               S = FieldTimeSeries(filepath, "S"),
               νₑ = FieldTimeSeries(filepath, "νₑ"))

# We start the animation at ``t = 10`` minutes since things are pretty boring till then:

times = time_series.w.times
intro = searchsortedfirst(times, 10minutes)

# We are now ready to animate using Makie. We use Makie's `Observable` to animate
# the data. To dive into how `Observable`s work we refer to
# [Makie.jl's Documentation](https://docs.makie.org/stable/explanations/observables).

n = Observable(intro)

 wₙ = @lift time_series.w[$n]
 Tₙ = @lift time_series.T[$n]
 Sₙ = @lift time_series.S[$n]
νₑₙ = @lift time_series.νₑ[$n]

fig = Figure(size = (1800, 900))

axis_kwargs = (xlabel="x (m)",
               ylabel="z (m)",
               aspect = AxisAspect(grid.Lx/grid.Lz),
               limits = ((0, grid.Lx), (-grid.Lz, 0)))

ax_w  = Axis(fig[2, 1]; title = "Vertical velocity", axis_kwargs...)
ax_T  = Axis(fig[2, 3]; title = "Temperature", axis_kwargs...)
ax_S  = Axis(fig[3, 1]; title = "Salinity", axis_kwargs...)
ax_νₑ = Axis(fig[3, 3]; title = "Eddy viscocity", axis_kwargs...)

title = @lift @sprintf("t = %s", prettytime(times[$n]))

 wlims = (-0.05, 0.05)
 Tlims = (19.7, 19.99)
 Slims = (35, 35.005)
νₑlims = (1e-6, 5e-3)

hm_w = heatmap!(ax_w, wₙ; colormap = :balance, colorrange = wlims)
Colorbar(fig[2, 2], hm_w; label = "m s⁻¹")

hm_T = heatmap!(ax_T, Tₙ; colormap = :thermal, colorrange = Tlims)
Colorbar(fig[2, 4], hm_T; label = "ᵒC")

hm_S = heatmap!(ax_S, Sₙ; colormap = :haline, colorrange = Slims)
Colorbar(fig[3, 2], hm_S; label = "g / kg")

hm_νₑ = heatmap!(ax_νₑ, νₑₙ; colormap = :thermal, colorrange = νₑlims)
Colorbar(fig[3, 4], hm_νₑ; label = "m s⁻²")

fig[1, 1:4] = Label(fig, title, fontsize=24, tellwidth=false)

current_figure() #hide
fig

# And now record a movie.

frames = intro:length(times)

@info "Making a motion picture of ocean wind mixing and convection..."

CairoMakie.record(fig, filename * ".mp4", frames, framerate=8) do i
    n[] = i
end
nothing #hide

# ![](ocean_wind_mixing_and_convection.mp4)
