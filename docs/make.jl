push!(LOAD_PATH, "..")

using Documenter
using Bibliography
using Literate
using Plots  # to avoid capturing precompilation output by Literate
using Oceananigans
using Oceananigans.Operators
using Oceananigans.Grids
using Oceananigans.Diagnostics
using Oceananigans.OutputWriters
using Oceananigans.TurbulenceClosures
using Oceananigans.TimeSteppers
using Oceananigans.AbstractOperations

bib_filepath = joinpath(dirname(@__FILE__), "oceananigans.bib")
const BIBLIOGRAPHY = import_bibtex(bib_filepath)
@info "Bibliography: found $(length(BIBLIOGRAPHY)) entries."

include("bibliography.jl")
include("citations.jl")

#####
##### Generate examples
#####

# Gotta set this environment variable when using the GR run-time on Travis CI.
# This happens as examples will use Plots.jl to make plots and movies.
# See: https://github.com/jheinen/GR.jl/issues/278
ENV["GKSwstype"] = "100"

const EXAMPLES_DIR = joinpath(@__DIR__, "..", "examples")
const OUTPUT_DIR   = joinpath(@__DIR__, "src/generated")

examples = [
    # "one_dimensional_diffusion.jl",
    # "two_dimensional_turbulence.jl",
    # "ocean_wind_mixing_and_convection.jl",
    # "ocean_convection_with_plankton.jl",
    # "internal_wave.jl",
    # "langmuir_turbulence.jl",
]

for example in examples
    example_filepath = joinpath(EXAMPLES_DIR, example)
    Literate.markdown(example_filepath, OUTPUT_DIR, documenter=true)
end

#####
##### Don't forget any modules!
#####

modules = [
    Oceananigans,
    Oceananigans.Architectures,
    Oceananigans.Utils,
    Oceananigans.Logger,
    Oceananigans.Grids,
    Oceananigans.Operators,
    Oceananigans.BoundaryConditions,
    Oceananigans.Fields,
    Oceananigans.Coriolis,
    Oceananigans.Buoyancy,
    Oceananigans.SurfaceWaves,
    Oceananigans.TurbulenceClosures,
    Oceananigans.Solvers,
    Oceananigans.Forcing,
    Oceananigans.Models,
    Oceananigans.TimeSteppers,
    Oceananigans.Diagnostics,
    Oceananigans.OutputWriters,
    Oceananigans.Simulations,
    Oceananigans.AbstractOperations
]

#####
##### Organize page hierarchies
#####

example_pages = [
    "Architecture" => "model_setup/architecture.md",
    "Number type" => "model_setup/number_type.md",
    "Grid" => "model_setup/grids.md",
    "Clock" => "model_setup/clock.md",
    "Coriolis (rotation)" => "model_setup/coriolis.md",
    "Tracers" => "model_setup/tracers.md",
    "Buoyancy and equation of state" => "model_setup/buoyancy_and_equation_of_state.md",
    "Boundary conditions" => "model_setup/boundary_conditions.md",
    "Forcing functions" => "model_setup/forcing_functions.md",
    "Turbulent diffusivity closures and LES models" => "model_setup/turbulent_diffusivity_closures_and_les_models.md",
    "Diagnostics" => "model_setup/diagnostics.md",
    "Output writers" => "model_setup/output_writers.md",
    "Checkpointing" => "model_setup/checkpointing.md",
    "Time stepping" => "model_setup/time_stepping.md",
    "Setting initial conditions" => "model_setup/setting_initial_conditions.md"
]

model_setup_pages = [
    "Overview" => "model_setup/overview.md",
    "Architecture" => "model_setup/architecture.md",
    "Number type" => "model_setup/number_type.md",
    "Grid" => "model_setup/grids.md",
    "Clock" => "model_setup/clock.md",
    "Coriolis (rotation)" => "model_setup/coriolis.md",
    "Tracers" => "model_setup/tracers.md",
    "Buoyancy and equation of state" => "model_setup/buoyancy_and_equation_of_state.md",
    "Boundary conditions" => "model_setup/boundary_conditions.md",
    "Forcing functions" => "model_setup/forcing_functions.md",
    "Turbulent diffusivity closures and LES models" => "model_setup/turbulent_diffusivity_closures_and_les_models.md",
    "Diagnostics" => "model_setup/diagnostics.md",
    "Output writers" => "model_setup/output_writers.md",
    "Checkpointing" => "model_setup/checkpointing.md",
    "Time stepping" => "model_setup/time_stepping.md",
    "Setting initial conditions" => "model_setup/setting_initial_conditions.md"
]

physics_pages = [
    "Navier-Stokes and tracer conservation equations" => "physics/navier_stokes_and_tracer_conservation.md",
    "Coordinate system and notation" => "physics/coordinate_system_and_notation.md",
    "The Boussinesq approximation" => "physics/boussinesq_approximation.md",
    "Coriolis forces" => "physics/coriolis_forces.md",
    "Buoyancy model and equations of state" => "physics/buoyancy_and_equations_of_state.md",
    "Turbulence closures" => "physics/turbulence_closures.md",
    "Surface gravity waves and the Craik-Leibovich approximation" => "physics/surface_gravity_waves.md"
]

numerical_pages = [
    "Pressure decomposition" => "numerical_implementation/pressure_decomposition.md",
    "Time stepping" => "numerical_implementation/time_stepping.md",
    "Finite volume method" => "numerical_implementation/finite_volume.md",
    "Spatial operators" => "numerical_implementation/spatial_operators.md",
    "Boundary conditions" => "numerical_implementation/boundary_conditions.md",
    "Poisson solvers" => "numerical_implementation/poisson_solvers.md",
    "Large eddy simulation" => "numerical_implementation/large_eddy_simulation.md"
]

verification_pages = [
    "Taylor-Green vortex" => "verification/taylor_green_vortex.md",
    "Stratified Couette flow" => "verification/stratified_couette_flow.md"
]

appendix_pages = [
    "Staggered grid" => "appendix/staggered_grid.md",
    "Fractional step method" => "appendix/fractional_step.md"
]

pages = [
    "Home" => "index.md",
    "Installation instructions" => "installation_instructions.md",
    "Using GPUs" => "using_gpus.md",
    "Examples" => example_pages,
    "Model setup" => model_setup_pages,
    "Physics" => physics_pages,
    "Numerical implementation" => numerical_pages,
    "Verification experiments" => verification_pages,
    "Gallery" => "gallery.md",
    "Performance benchmarks" => "benchmarks.md",
    "Contributor's guide" => "contributing.md",
    "Library" => "library.md",
    "Appendix" => appendix_pages,
    "Function index" => "function_index.md",
    "References" => "references.md"
]

#####
##### Build and deploy docs
#####

# Set up a timer to print a dot '.' every 60 seconds. This is to avoid Travis CI
# timing out when building demanding Literate.jl examples.
dot_timer = Timer(t -> println("."), 0, interval=60)

format = Documenter.HTML(
    collapselevel = 1,
       prettyurls = get(ENV, "CI", nothing) == "true",
        canonical = "https://clima.github.io/OceananigansDocumentation/latest/"
)

makedocs(
   modules = modules,
   doctest = true,
    strict = true,
   clean   = true,
 checkdocs = :all,
    format = format,
   authors = "Ali Ramadhan, Gregory Wagner, John Marshall, Jean-Michel Campin, Chris Hill",
  sitename = "Oceananigans.jl",
     pages = pages
)

withenv("TRAVIS_REPO_SLUG" => "CliMA/OceananigansDocumentation") do
    deploydocs(
              repo = "github.com/CliMA/OceananigansDocumentation.git",
          versions = ["stable" => "v^", "v#.#.#"],
      push_preview = true
    )
end

close(dot_timer)