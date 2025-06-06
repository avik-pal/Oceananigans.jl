using Printf
using Statistics
using Random
using Oceananigans
using Oceananigans.Units
using GLMakie

namelist = (; κskew=1e3, κsymmetric=1e3, tapering=1e-2, scale=2.0)
gradient = "y"
filename = "coarse_baroclinic_adjustment_" * gradient

# Architecture
architecture = CPU()

# Domain
Lx = 1000kilometers
Ly = 1000kilometers  # north-south extent [m]
Lz = 1kilometers     # depth [m]
Nx = 20
Ny = 20
Nz = 20
save_fields_interval = 0.5day
stop_time = 30days
Δt = 20minutes

zfaces = -Lz .+ (-0.5 * (cos.(range(0.0, π, length=Nz + 1))) .+ 0.5) .* Lz # range(-Lz, 0.0, length = Nz+1)
zfaces = range(-Lz, 0.0, length=Nz + 1)

grid = RectilinearGrid(architecture;
    topology=(Bounded, Bounded, Bounded),
    size=(Nx, Ny, Nz),
    x=(-Lx / 2, Lx / 2),
    y=(-Ly / 2, Ly / 2),
    z=zfaces,
    halo=(3, 3, 3))

coriolis = FPlane(latitude=-45)

println("The diffusive timescale is ", (zfaces[1] - zfaces[2])^2 / 1e3)

Δy = Ly / Ny
@show κh = νh = Δy^4 / 10days
vertical_closure = VerticalScalarDiffusivity(ν=1e-2, κ=1e-4)
horizontal_closure = HorizontalScalarBiharmonicDiffusivity(ν=νh, κ=κh)

gerdes_koberle_willebrand_tapering = FluxTapering(namelist.tapering)
gent_mcwilliams_diffusivity = IsopycnalSkewSymmetricDiffusivity(κ_skew=namelist.κskew,
    κ_symmetric=namelist.κsymmetric,
    slope_limiter=gerdes_koberle_willebrand_tapering)

closures = (vertical_closure, horizontal_closure, gent_mcwilliams_diffusivity)

@info "Building a model..."

model = HydrostaticFreeSurfaceModel(grid=grid,
    coriolis=coriolis,
    buoyancy=BuoyancyTracer(),
    closure=closures,
    tracers=(:b, :c),
    momentum_advection=WENO5(),
    tracer_advection=WENO5(),
    free_surface=ImplicitFreeSurface())

@info "Built $model."

"""
Linear ramp from 0 to 1 between -Δy/2 and +Δy/2.

For example:

y < y₀           => ramp = 0
y₀ < y < y₀ + Δy => ramp = y / Δy
y > y₀ + Δy      => ramp = 1
"""
function ramp(x, y, Δ)
    gradient == "x" && return min(max(0, x / Δ + 1 / 2), 1)
    gradient == "y" && return min(max(0, y / Δ + 1 / 2), 1)
    gradient == "xy" && return 0.5 * (min(max(0, x / Δ + 1 / 2), 1) + min(max(0, y / Δ + 1 / 2), 1))
end

# Parameters
N² = 4e-6 # [s⁻²] buoyancy frequency / stratification
M² = 8e-8 # [s⁻²] horizontal buoyancy gradient

Δy = 100kilometers * 1.0
Δz = 100

Δc = 2Δy
Δb = Δy * M²
ϵb = 0e-2 * Δb # noise amplitude

bᵢ(x, y, z) = N² * z + namelist.scale * Δb * ramp(x, y, Δy)
cᵢ(x, y, z) = 00.25 # exp(-x^2 / 2Δc^2) * exp(-y^2 / 2Δc^2) * exp(-(z + Lz/4)^2 / 2Δz^2)

set!(model, b=bᵢ, c=cᵢ)

#####
##### Simulation building
#####

simulation = Simulation(model; Δt, stop_time)

# add timestep wizard callback
# wizard = TimeStepWizard(cfl=0.1, max_change=1.1, max_Δt=Δt)
# simulation.callbacks[:wizard] = Callback(wizard, IterationInterval(20))

# add progress callback
wall_clock = [time_ns()]

function print_progress(sim)
    @printf("[%05.2f%%] i: %d, t: %s, wall time: %s, max(u): (%6.3e, %6.3e, %6.3e) m/s, next Δt: %s\n",
        100 * (sim.model.clock.time / sim.stop_time),
        sim.model.clock.iteration,
        prettytime(sim.model.clock.time),
        prettytime(1e-9 * (time_ns() - wall_clock[1])),
        maximum(abs, sim.model.velocities.u),
        maximum(abs, sim.model.velocities.v),
        maximum(abs, sim.model.velocities.w),
        prettytime(sim.Δt))

    wall_clock[1] = time_ns()

    return nothing
end

simulation.callbacks[:print_progress] = Callback(print_progress, IterationInterval(20))

simulation.output_writers[:fields] = JLD2Writer(model, merge(model.velocities, model.tracers),
                                                schedule=TimeInterval(save_fields_interval),
                                                filename=filename * "_fields",
                                                overwrite_existing=true)

@info "Running the simulation..."

run!(simulation)

@info "Simulation completed in " * prettytime(simulation.run_wall_time)
println("done with gradient in ", gradient)

#####
##### Visualize
#####

fig = Figure(size=(1400, 700))

filepath = filename * "_fields.jld2"

ut = FieldTimeSeries(filepath, "u")
bt = FieldTimeSeries(filepath, "b")
ct = FieldTimeSeries(filepath, "c")

# Build coordinates, rescaling the vertical coordinate
x, y, z = nodes((Center, Center, Center), grid)

zscale = 1
z = z .* zscale

#####
##### Plot buoyancy...
#####

println("The extrema of c at the end is ", extrema(interior(ct)[:, :, :, end]))

times = bt.times
Nt = length(times)

if gradient == "y" # average in x
    un(n) = interior(mean(ut[n], dims=1), 1, :, :)
    bn(n) = interior(mean(bt[n], dims=1), 1, :, :)
    cn(n) = interior(mean(ct[n], dims=1), 1, :, :)
else # average in y
    un(n) = interior(mean(ut[n], dims=2), :, 1, :)
    bn(n) = interior(mean(bt[n], dims=2), :, 1, :)
    cn(n) = interior(mean(ct[n], dims=2), :, 1, :)
end

@show min_c = 0
@show max_c = 1
@show max_u = maximum(abs, un(Nt))
min_u = -max_u

axu = Axis(fig[2, 1], xlabel="$gradient (km)", ylabel="z (km)", title="Zonal velocity")
axc = Axis(fig[3, 1], xlabel="$gradient (km)", ylabel="z (km)", title="Tracer concentration")
slider = Slider(fig[4, 1:2], range=1:Nt, startvalue=1)
n = slider.value

u = @lift un($n)
b = @lift bn($n)
c = @lift cn($n)

hm = heatmap!(axu, y * 1e-3, z * 1e-3, u, colorrange=(min_u, max_u), colormap=:balance, interpolate=true)
contour!(axu, y * 1e-3, z * 1e-3, b, levels=25, color=:black, linewidth=2)
cb = Colorbar(fig[2, 2], hm)

hm = heatmap!(axc, y * 1e-3, z * 1e-3, c, colorrange=(0, 0.5), colormap=:balance, interpolate=true)
contour!(axc, y * 1e-3, z * 1e-3, b, levels=25, color=:black, linewidth=2)
cb = Colorbar(fig[3, 2], hm)

title_str = @lift "Baroclinic adjustment with GM at t = " * prettytime(times[$n])
ax_t = fig[1, 1:2] = Label(fig, title_str)

display(fig)


record(fig, filename * ".mp4", 1:Nt, framerate=8) do i
    @info "Plotting frame $i of $Nt"
    n[] = i
end
