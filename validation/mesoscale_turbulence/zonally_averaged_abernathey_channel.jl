ENV["GKSwstype"] = "100"

using Printf
using Statistics
using Plots

using Oceananigans
using Oceananigans.Units
using Oceananigans.OutputReaders: FieldTimeSeries
using Oceananigans.ImmersedBoundaries: ImmersedBoundaryGrid, GridFittedBoundary
using Oceananigans.TurbulenceClosures: Vertical, Horizontal

#####
##### Grid
#####

# Architecture
architecture  = CPU()

# number of grid points
Nx = 100
Ny = 200
Nz = 35

# stretched grid
k_center = collect(1:Nz)
Δz_center = @. 10 * 1.104^(Nz - k_center)

const Lz = sum(Δz_center)

z_faces = vcat([-Lz], -Lz .+ cumsum(Δz_center))
z_faces[Nz+1] = 0

grid = RectilinearGrid(architecture,
                       topology = (Flat, Bounded, Bounded),
                       size = (Ny, Nz),
                       halo = (3, 3),
                       y = (0, Ly),
                       z = z_faces)

@info "Built a grid: $grid."


#=
# We visualize the cell interfaces by plotting the cell height
# as a function of depth,

p = plot(grid.Δzᵃᵃᶜ[1:Nz], grid.zᵃᵃᶜ[1:Nz],
         marker = :circle,
         ylabel = "Depth (m)",
         xlabel = "Vertical spacing (m)",
         legend = nothing)

display(p)
=#

#####
##### Boundary conditions: buoyancy flux
#####

Qᵇ = 1e-8            # buoyancy flux magnitude [m² s⁻³]
y_shutoff = 5/6 * Ly # shutoff location for buoyancy flux [m]
τ = 1e-4             # surface kinematic wind stress [m² s⁻²]
μ = 1 / 100days      # bottom drag damping time-scale [s⁻¹]

@inline buoyancy_flux(x, y, t, p) = ifelse(y < p.y_shutoff, p.Qᵇ * cos(3π * y / p.Ly), 0)

buoyancy_flux_bc = FluxBoundaryCondition(buoyancy_flux, parameters=(Ly=grid.Ly, y_shutoff=y_shutoff, Qᵇ=Qᵇ))

#####
##### Boundary conditions: wind stress
#####

@inline u_stress(x, y, t, p) = - p.τ * sin(π * y / p.Ly)

u_stress_bc = FluxBoundaryCondition(u_stress, parameters=(τ=τ, Ly=grid.Ly))

#####
##### Boundary conditions: linear bottom drag
#####

@inline u_drag(x, y, t, u, μ) = - μ * u
@inline v_drag(x, y, t, v, μ) = - μ * v

u_drag_bc = FluxBoundaryCondition(u_drag, field_dependencies=:u, parameters=μ)
v_drag_bc = FluxBoundaryCondition(v_drag, field_dependencies=:v, parameters=μ)

b_bcs = FieldBoundaryConditions(top = buoyancy_flux_bc)
u_bcs = FieldBoundaryConditions(top = u_stress_bc, bottom = u_drag_bc)
v_bcs = FieldBoundaryConditions(bottom = v_drag_bc)

#####
##### Coriolis forces
#####

coriolis = BetaPlane(latitude=-45)

const N²₀ = 1.6e-5   # surface vertical buoyancy gradient [s⁻²]
const h = 1kilometer # decay scale of stable stratification [m]

#####
##### Initial stratification and restoring
#####

@inline b_stratification(z) = N²₀ * h * exp(z / h) / (1 - exp(-Lz / h))

const y_sponge = 19/20 * Ly # southern boundary of sponge layer [m]

## Mask that limits sponge layer to a thin region near the northern boundary
@inline northern_mask(x, y, z) = max(0, y - y_sponge) / (Ly - y_sponge)

## Target and initial buoyancy profile
@inline b_target(x, y, z, t) = b_stratification(z)

b_forcing = Relaxation(target=b_target, mask=northern_mask, rate=1/7days)

using Oceananigans.TurbulenceClosures
using Oceananigans.Fields: TracerFields, FunctionField

tracers = TracerFields(tuple(:b), architecture, grid)

b = tracers.b

const f₀ = coriolis.f₀
const β = coriolis.β
const K₀ = 100

K_func(x, y, z) = K₀ + 3000 * sin(π * y / Ly)
f²_func(x, y, z) = (f₀ + β * y)^2

K = FunctionField{Center, Center, Center}(K_func, grid)
f² = FunctionField{Center, Center, Center}(f²_func, grid)

ν_op = @at (Center, Center, Center) K * f² / ∂z(b)
ν = Field(ν_op)

vertical_closure = VerticalScalarDiffusivity(ν = νv, κ = κv)

horizontal_closure = HorizontalScalarDiffusivity(ν = νh, κ = κh)

closure = (horizontal_closure, vertical_closure)

model = NonhydrostaticModel(architecture,
                            grid = grid,
                            advection = UpwindBiased(order=5),
                            buoyancy = BuoyancyTracer(),
                            coriolis = coriolis,
                            closure = closure,
                            tracers = tracers,
                            boundary_conditions = (b=b_bcs, u=u_bcs, v=v_bcs),
                            auxiliary_fields = (; ν=ν),
                            forcing = (b=b_forcing,))

@show grid === model.grid

bᵢ(x, y, z) = b_stratification(z)
uᵢ(x, y, z) = 0.0 #0.1 * (1 - z / Lz)

set!(model, u=uᵢ, b=bᵢ)

using Oceananigans.Fields: similar_cpu_field
using Oceananigans.Grids: topology, halo_size

cpu_grid(grid::RectilinearGrid) = grid

cpu_grid(grid::RectilinearGrid) = RectilinearGrid(CPU(),
                                       topology = topology(grid),
                                       size = size(grid),
                                       halo = halo_size(grid),
                                       x = (0, grid.Ly),
                                       y = (0, grid.Ly),
                                       z = grid.zᵃᵃᶠ)

function channel_plot(u_device, b_device)

    grid = cpu_grid(u_device.grid)

    u = XFaceField(CPU(), grid)
    b = CenterField(CPU(), grid)

    copyto!(parent(u), parent(u_device))
    copyto!(parent(b), parent(b_device))

    grid = u.grid

    xb, yb, zb = nodes(b)
    xu, yu, zu = nodes(u)

    ui = interior(u)[1, :, :]
    bi = interior(b)[1, :, :]

    umax = maximum(abs, ui)
    ulim = max(0.001, 0.5 * umax)
    ulevels = range(-ulim, ulim, length=31)
    umax > ulim && (ulevels = vcat([-umax], ulevels, [umax]))

    bmin = minimum(bi)
    bmax = maximum(bi)
    blevels = range(bmin, bmax, length=10)

    pl = contourf(yu * 1e-3, zu, ui',
                  xlabel = "y (km)",
                  ylabel = "z (m)",
                  aspectratio = 0.2,
                  linewidth = 0,
                  levels = ulevels,
                  clims = (-ulim, ulim),
                  xlims = (0, grid.Ly) .* 1e-3,
                  ylims = (-grid.Lz, 0),
                  color = :balance)

    contour!(pl, yb * 1e-3, zb, bi', linewidth=1, seriescolor=:gray, levels=blevels, clims=(-ulim, ulim))

    return pl
end

u, v, w = model.velocities
b = model.tracers.b

p = channel_plot(u, b)
display(p)

# # Simulation setup
#
# We set up a simulation with adaptive time-stepping and a simple progress message.

#wizard = TimeStepWizard(cfl=0.2, Δt=10minutes, max_change=1.1, max_Δt=2hours)

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

diffusion_Δt = grid.Δyᵃᶜᵃ^2 / closure.νy
@show Δt = min(10minutes, diffusion_Δt)

simulation = Simulation(model, Δt=Δt, stop_time=10years)
simulation.callbacks[:print_progress] = Callback(print_progress, IterationInterval(100))

u, v, w = model.velocities
b = model.tracers.b

outputs = merge(model.velocities, model.tracers)

#=
simulation.output_writers[:checkpointer] = Checkpointer(model,
                                                        schedule = TimeInterval(100days),
                                                        prefix = "eddying_channel",
                                                        overwrite_existing = true)

simulation.output_writers[:fields] = JLD2Writer(model, outputs;
                                                schedule = TimeInterval(10day),
                                                filename = "eddying_channel",
                                                overwrite_existing = true)

try
    run!(simulation, pickup=false)
catch err
    showerror(stdout, err)
end
=#

u_timeseries = FieldTimeSeries("eddying_channel.jld2", "u", grid=cpu_grid(grid))
b_timeseries = FieldTimeSeries("eddying_channel.jld2", "b", grid=cpu_grid(grid))

@show b_timeseries

anim = @animate for i in 5:120
    @info "Animating frame $i of $(length(b_timeseries.times))..."
    u = b_timeseries[i]
    b = b_timeseries[i]
    channel_plot(u, b)
end

mp4(anim, "zonally_averaged_abernathey_channel.mp4", fps = 8) #hide
