using Printf
using Statistics
using Random
using Oceananigans
using Oceananigans.Units
using GLMakie
using Oceananigans.TurbulenceClosures: IsopycnalSkewSymmetricDiffusivity
using Oceananigans.TurbulenceClosures: TriadIsopycnalSkewSymmetricDiffusivity
using Oceananigans.TurbulenceClosures: FluxTapering

gradient = "y"
filename = "coarse_baroclinic_adjustment_" * gradient

# Domain
Ly = 1000kilometers  # north-south extent [m]
Lz = 1kilometers     # depth [m]
Ny = 20
Nz = 20
save_fields_interval = 0.5day
stop_time = 30days
Δt = 10minutes

grid = RectilinearGrid(architecture;
                       topology = (Bounded, Bounded, Bounded),
                       size = (Ny, Ny, Nz),
                       x = (-Ly/2, Ly/2),
                       y = (-Ly/2, Ly/2),
                       z = (-Lz, 0),
                       halo = (3, 3, 3))

coriolis = FPlane(latitude = -45)

gerdes_koberle_willebrand_tapering = FluxTapering(1e-2)
triad_closure = TriadIsopycnalSkewSymmetricDiffusivity(VerticallyImplicitTimeDiscretization(),
                                                       κ_skew = 0,
                                                       κ_symmetric = 1e3,
                                                       slope_limiter = gerdes_koberle_willebrand_tapering)

cox_closure = IsopycnalSkewSymmetricDiffusivity(VerticallyImplicitTimeDiscretization(),
                                                κ_skew = 0,
                                                κ_symmetric = 1e3,
                                                slope_limiter = gerdes_koberle_willebrand_tapering)

@info "Building a model..."

model = HydrostaticFreeSurfaceModel(; grid, coriolis,
                                    closure = triad_closure,
                                    buoyancy = BuoyancyTracer(),
                                    tracers = (:b, :c),
                                    momentum_advection = WENO(order=5),
                                    tracer_advection = WENO(order=5),
                                    free_surface = ImplicitFreeSurface())

@info "Built $model."

"""
Linear ramp from 0 to 1 between -Δy/2 and +Δy/2.

For example:

y < y₀           => ramp = 0
y₀ < y < y₀ + Δy => ramp = y / Δy
y > y₀ + Δy      => ramp = 1
"""
function ramp(x, y, Δ)
    gradient == "x" && return min(max(0, x / Δ + 1/2), 1)
    gradient == "y" && return min(max(0, y / Δ + 1/2), 1)
end

# Parameters
N² = 4e-6 # [s⁻²] buoyancy frequency / stratification
M² = 8e-8 # [s⁻²] horizontal buoyancy gradient

Δy = 100kilometers
Δz = 100

Δc = 2Δy
Δb = Δy * M²
ϵb = 1e-2 * Δb # noise amplitude

bᵢ(x, y, z) = N² * z + Δb * ramp(x, y, Δy)
cᵢ(x, y, z) = exp(-y^2 / 2Δc^2) * exp(-(z + Lz/4)^2 / 2Δz^2)

set!(model, b=bᵢ, c=cᵢ)

#####
##### Simulation building
#####

simulation = Simulation(model; Δt, stop_time)

wall_clock = Ref(time_ns())

function progress(sim)
    @printf("[%05.2f%%] i: %d, t: %s, wall time: %s, max(u): (%6.3e, %6.3e, %6.3e) m/s, next Δt: %s\n",
            100 * (sim.model.clock.time / sim.stop_time),
            sim.model.clock.iteration,
            prettytime(sim.model.clock.time),
            prettytime(1e-9 * (time_ns() - wall_clock[])),
            maximum(abs, sim.model.velocities.u),
            maximum(abs, sim.model.velocities.v),
            maximum(abs, sim.model.velocities.w),
            prettytime(sim.Δt))

    wall_clock[] = time_ns()
    
    return nothing
end

add_callback!(simulation, progress, IterationInterval(10))

simulation.output_writers[:fields] = JLD2Writer(model, merge(model.velocities, model.tracers),
                                                schedule = TimeInterval(save_fields_interval),
                                                filename = filename * "_fields",
                                                verwrite_existing = true)

@info "Running the simulation..."

run!(simulation)

@info "Simulation completed in " * prettytime(simulation.run_wall_time)

#####
##### Visualize
#####

fig = Figure(size=(1400, 700))

filepath = filename * "_fields.jld2"

ut = FieldTimeSeries(filepath, "u")
bt = FieldTimeSeries(filepath, "b")
ct = FieldTimeSeries(filepath, "c")

# Build coordinates, rescaling the vertical coordinate
x, y, z = nodes(bt)

zscale = 1
z = z .* zscale

#####
##### Plot buoyancy...
#####

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
min_u = - max_u

axu = Axis(fig[2, 1], xlabel="$gradient (km)", ylabel="z (km)", title="Zonal velocity")
axc = Axis(fig[3, 1], xlabel="$gradient (km)", ylabel="z (km)", title="Tracer concentration")
slider = Slider(fig[4, 1:2], range=1:Nt, startvalue=1)
n = slider.value

u = @lift un($n)
b = @lift bn($n)
c = @lift cn($n)

hm = heatmap!(axu, y * 1e-3, z * 1e-3, u, colorrange=(min_u, max_u), colormap=:balance)
contour!(axu, y * 1e-3, z * 1e-3, b, levels = 25, color=:black, linewidth=2)
cb = Colorbar(fig[2, 2], hm)

hm = heatmap!(axc, y * 1e-3, z * 1e-3, c, colorrange=(0, 0.5), colormap=:speed)
contour!(axc, y * 1e-3, z * 1e-3, b, levels = 25, color=:black, linewidth=2)
cb = Colorbar(fig[3, 2], hm)

title_str = @lift "Baroclinic adjustment with GM at t = " * prettytime(times[$n])
ax_t = fig[1, 1:2] = Label(fig, title_str)

display(fig)

record(fig, filename * ".mp4", 1:Nt, framerate=8) do i
    @info "Plotting frame $i of $Nt"
    n[] = i
end

