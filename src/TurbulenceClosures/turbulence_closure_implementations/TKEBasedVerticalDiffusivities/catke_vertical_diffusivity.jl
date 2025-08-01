struct CATKEVerticalDiffusivity{TD, CL, FT, DT, TKE} <: AbstractScalarDiffusivity{TD, VerticalFormulation, 2}
    mixing_length :: CL
    turbulent_kinetic_energy_equation :: TKE
    maximum_tracer_diffusivity :: FT
    maximum_tke_diffusivity :: FT
    maximum_viscosity :: FT
    minimum_tke :: FT
    minimum_convective_buoyancy_flux :: FT
    negative_tke_damping_time_scale :: FT
    tke_time_step :: DT
end

function CATKEVerticalDiffusivity{TD}(mixing_length::CL,
                                      turbulent_kinetic_energy_equation::TKE,
                                      maximum_tracer_diffusivity::FT,
                                      maximum_tke_diffusivity::FT,
                                      maximum_viscosity::FT,
                                      minimum_tke::FT,
                                      minimum_convective_buoyancy_flux::FT,
                                      negative_tke_damping_time_scale::FT,
                                      tke_time_step::DT) where {TD, CL, FT, DT, TKE}

    return CATKEVerticalDiffusivity{TD, CL, FT, DT, TKE}(mixing_length,
                                                         turbulent_kinetic_energy_equation,
                                                         maximum_tracer_diffusivity,
                                                         maximum_tke_diffusivity,
                                                         maximum_viscosity,
                                                         minimum_tke,
                                                         minimum_convective_buoyancy_flux,
                                                         negative_tke_damping_time_scale,
                                                         tke_time_step)
end

CATKEVerticalDiffusivity(FT::DataType; kw...) =
    CATKEVerticalDiffusivity(VerticallyImplicitTimeDiscretization(), FT; kw...)

const CATKEVD{TD} = CATKEVerticalDiffusivity{TD} where TD
const CATKEVDArray{TD} = AbstractArray{<:CATKEVD{TD}} where TD
const FlavorOfCATKE{TD} = Union{CATKEVD{TD}, CATKEVDArray{TD}} where TD

"""
    CATKEVerticalDiffusivity([time_discretization = VerticallyImplicitTimeDiscretization(),
                             FT = Float64;]
                             mixing_length = CATKEMixingLength(),
                             turbulent_kinetic_energy_equation = CATKEEquation(),
                             maximum_tracer_diffusivity = Inf,
                             maximum_tke_diffusivity = Inf,
                             maximum_viscosity = Inf,
                             minimum_tke = 1e-9,
                             minimum_convective_buoyancy_flux = 1e-11,
                             negative_tke_damping_time_scale = 1minute,
                             tke_time_step = nothing)

Return the `CATKEVerticalDiffusivity` turbulence closure for vertical mixing by
small-scale ocean turbulence based on the prognostic evolution of subgrid
Turbulent Kinetic Energy (TKE).

!!! note "CATKE vertical diffusivity"
    `CATKEVerticalDiffusivity` is a new turbulence closure diffusivity. The default
    values for its free parameters are obtained from calibration against large eddy
    simulations. For more details please refer to [Wagner et al. (2025)](@cite Wagner25catke).

    Use with caution and report any issues with the physics at [https://github.com/CliMA/Oceananigans.jl/issues](https://github.com/CliMA/Oceananigans.jl/issues).

Arguments
=========

- `time_discretization`: Either `ExplicitTimeDiscretization()` or `VerticallyImplicitTimeDiscretization()`;
                         default `VerticallyImplicitTimeDiscretization()`.

- `FT`: Float type; default `Float64`.

Keyword arguments
=================

- `mixing_length`: The formulation for mixing length; default: `CATKEMixingLength()`.

- `turbulent_kinetic_energy_equation`: The TKE equation; default: `CATKEEquation()`.

- `maximum_tracer_diffusivity`: Maximum value for tracer diffusivity. CATKE-predicted tracer
                                diffusivities that are larger than `maximum_tracer_diffusivity`
                                are clipped. Default: `Inf`.

- `maximum_tke_diffusivity`: Maximum value for TKE diffusivity. CATKE-predicted diffusivities
                             for TKE that are larger than `maximum_tke_diffusivity` are clipped.
                             Default: `Inf`.

- `maximum_viscosity`: Maximum value for momentum diffusivity. CATKE-predicted momentum diffusivities
                       that are larger than `maximum_viscosity` are clipped. Default: `Inf`.

- `minimum_tke`: Minimum value for the turbulent kinetic energy. Can be used to model the presence
                 "background" TKE levels due to, for example, mixing by breaking internal waves.
                 Default: 1e-9.

- `minimum_convective_buoyancy_flux` Minimum value for the convective buoyancy flux. Default: 1e-11.

- `negative_tke_damping_time_scale`: Damping time-scale for spurious negative values of TKE,
                                     typically generated by oscillatory errors associated
                                     with the TKE advection. Default: 1 minute.

References
==========

Wagner, G. L., Hillier, A., Constantinou, N. C., Silvestri, S., Souza, A., Burns, K., Hill,
    C., Campin, J.-M., Marshall, J., and Ferrari, R. (2025). Formulation and calibration of CATKE,
    a one-equation parameterization for microscale ocean mixing. J. Adv. Model. Earth Sy., 17, e2024MS004522.
"""
function CATKEVerticalDiffusivity(time_discretization::TD = VerticallyImplicitTimeDiscretization(),
                                  FT = Oceananigans.defaults.FloatType;
                                  mixing_length = CATKEMixingLength(),
                                  turbulent_kinetic_energy_equation = CATKEEquation(),
                                  maximum_tracer_diffusivity = Inf,
                                  maximum_tke_diffusivity = Inf,
                                  maximum_viscosity = Inf,
                                  minimum_tke = 1e-9,
                                  minimum_convective_buoyancy_flux = 1e-11,
                                  negative_tke_damping_time_scale = 1minute,
                                  tke_time_step = nothing) where TD

    mixing_length = convert_eltype(FT, mixing_length)
    turbulent_kinetic_energy_equation = convert_eltype(FT, turbulent_kinetic_energy_equation)

    return CATKEVerticalDiffusivity{TD}(mixing_length,
                                        turbulent_kinetic_energy_equation,
                                        convert(FT, maximum_tracer_diffusivity),
                                        convert(FT, maximum_tke_diffusivity),
                                        convert(FT, maximum_viscosity),
                                        convert(FT, minimum_tke),
                                        convert(FT, minimum_convective_buoyancy_flux),
                                        convert(FT, negative_tke_damping_time_scale),
                                        tke_time_step)
end

function with_tracers(tracer_names, closure::FlavorOfCATKE)
    :e ∈ tracer_names ||
        throw(ArgumentError("Tracers must contain :e to represent turbulent kinetic energy " *
                            "for `CATKEVerticalDiffusivity`."))

    return closure
end

# For tuples of closures, we need to know _which_ closure is CATKE.
# Here we take a "simple" approach that sorts the tuple so CATKE is first.
# This is not sustainable though if multiple closures require this.
# The two other possibilities are:
# 1. Recursion to find which closure is CATKE in a compiler-inferrable way
# 2. Store the "CATKE index" inside CATKE via validate_closure.
validate_closure(closure_tuple::Tuple) = Tuple(sort(collect(closure_tuple), lt=catke_first))

catke_first(closure1, catke::FlavorOfCATKE) = false
catke_first(catke::FlavorOfCATKE, closure2) = true
catke_first(closure1, closure2) = false
catke_first(catke1::FlavorOfCATKE, catke2::FlavorOfCATKE) = error("Can't have two CATKEs in one closure tuple.")

#####
##### Diffusivities and diffusivity fields utilities
#####

struct CATKEDiffusivityFields{K, L, J, T, U, KC, LC}
    κu :: K
    κc :: K
    κe :: K
    Le :: L
    Jᵇ :: J
    previous_compute_time :: T
    previous_velocities :: U
    _tupled_tracer_diffusivities :: KC
    _tupled_implicit_linear_coefficients :: LC
end

Adapt.adapt_structure(to, catke_diffusivity_fields::CATKEDiffusivityFields) =
    CATKEDiffusivityFields(adapt(to, catke_diffusivity_fields.κu),
                           adapt(to, catke_diffusivity_fields.κc),
                           adapt(to, catke_diffusivity_fields.κe),
                           adapt(to, catke_diffusivity_fields.Le),
                           adapt(to, catke_diffusivity_fields.Jᵇ),
                           catke_diffusivity_fields.previous_compute_time[],
                           adapt(to, catke_diffusivity_fields.previous_velocities),
                           adapt(to, catke_diffusivity_fields._tupled_tracer_diffusivities),
                           adapt(to, catke_diffusivity_fields._tupled_implicit_linear_coefficients))

function fill_halo_regions!(catke_diffusivity_fields::CATKEDiffusivityFields, args...; kw...)
    grid = catke_diffusivity_fields.κu.grid

    κ = (catke_diffusivity_fields.κu,
         catke_diffusivity_fields.κc,
         catke_diffusivity_fields.κe)

    return fill_halo_regions!(κ, grid, args...; kw...)
end

function build_diffusivity_fields(grid, clock, tracer_names, bcs, closure::FlavorOfCATKE)

    default_diffusivity_bcs = (κu = FieldBoundaryConditions(grid, (Center(), Center(), Face())),
                               κc = FieldBoundaryConditions(grid, (Center(), Center(), Face())),
                               κe = FieldBoundaryConditions(grid, (Center(), Center(), Face())))

    bcs = merge(default_diffusivity_bcs, bcs)

    κu = ZFaceField(grid, boundary_conditions=bcs.κu)
    κc = ZFaceField(grid, boundary_conditions=bcs.κc)
    κe = ZFaceField(grid, boundary_conditions=bcs.κe)
    Le = CenterField(grid)
    Jᵇ = Field{Center, Center, Nothing}(grid)
    previous_compute_time = Ref(clock.time)

    # Note: we may be able to avoid using the "previous velocities" in favor of a "fully implicit"
    # discretization of shear production
    u⁻ = XFaceField(grid)
    v⁻ = YFaceField(grid)
    previous_velocities = (; u=u⁻, v=v⁻)

    # Secret tuple for getting tracer diffusivities with tuple[tracer_index]
    _tupled_tracer_diffusivities         = NamedTuple(name => name === :e ? κe : κc          for name in tracer_names)
    _tupled_implicit_linear_coefficients = NamedTuple(name => name === :e ? Le : ZeroField() for name in tracer_names)

    return CATKEDiffusivityFields(κu, κc, κe, Le, Jᵇ,
                                  previous_compute_time, previous_velocities,
                                  _tupled_tracer_diffusivities, _tupled_implicit_linear_coefficients)
end

@inline viscosity_location(::FlavorOfCATKE) = (c, c, f)
@inline diffusivity_location(::FlavorOfCATKE) = (c, c, f)

function update_previous_compute_time!(diffusivities, model)
    Δt = model.clock.time - diffusivities.previous_compute_time[]
    diffusivities.previous_compute_time[] = model.clock.time
    return Δt
end

function compute_diffusivities!(diffusivities, closure::FlavorOfCATKE, model; parameters = :xyz)
    arch = model.architecture
    grid = model.grid
    velocities = model.velocities
    tracers = model.tracers
    buoyancy = model.buoyancy
    clock = model.clock
    top_tracer_bcs = get_top_tracer_bcs(model.buoyancy.formulation, tracers)
    Δt = update_previous_compute_time!(diffusivities, model)

    if isfinite(model.clock.last_Δt) # Check that we have taken a valid time-step first.
        # Compute e at the current time:
        #   * update tendency Gⁿ using current and previous velocity field
        #   * use tridiagonal solve to take an implicit step
        time_step_catke_equation!(model)
    end

    # Update "previous velocities"
    u, v, w = model.velocities
    u⁻, v⁻ = diffusivities.previous_velocities
    parent(u⁻) .= parent(u)
    parent(v⁻) .= parent(v)

    launch!(arch, grid, :xy,
            compute_average_surface_buoyancy_flux!,
            diffusivities.Jᵇ, grid, closure, velocities, tracers, buoyancy, top_tracer_bcs, clock, Δt)

    launch!(arch, grid, parameters,
            compute_CATKE_diffusivities!,
            diffusivities, grid, closure, velocities, tracers, buoyancy)

    return nothing
end

@kernel function compute_average_surface_buoyancy_flux!(Jᵇ, grid, closure, velocities, tracers,
                                                        buoyancy, top_tracer_bcs, clock, Δt)
    i, j = @index(Global, NTuple)
    k = grid.Nz

    closure = getclosure(i, j, closure)

    model_fields = merge(velocities, tracers)
    Jᵇ★ = top_buoyancy_flux(i, j, grid, buoyancy, top_tracer_bcs, clock, model_fields)
    ℓᴰ = dissipation_length_scaleᶜᶜᶜ(i, j, k, grid, closure, velocities, tracers, buoyancy, Jᵇ)

    Jᵇᵋ = closure.minimum_convective_buoyancy_flux
    Jᵇᵢⱼ = @inbounds Jᵇ[i, j, 1]
    Jᵇ⁺ = max(Jᵇᵋ, Jᵇᵢⱼ, Jᵇ★) # selects fastest (dominant) time-scale
    t★ = cbrt(ℓᴰ^2 / Jᵇ⁺)
    ϵ = Δt / t★

    @inbounds Jᵇ[i, j, 1] = (Jᵇᵢⱼ + ϵ * Jᵇ★) / (1 + ϵ)
end

@kernel function compute_CATKE_diffusivities!(diffusivities, grid, closure::FlavorOfCATKE, velocities, tracers, buoyancy)
    i, j, k = @index(Global, NTuple)

    # Ensure this works with "ensembles" of closures, in addition to ordinary single closures
    closure_ij = getclosure(i, j, closure)
    Jᵇ = diffusivities.Jᵇ

    # Note: we also compute the TKE diffusivity here for diagnostic purposes, even though it
    # is recomputed in time_step_turbulent_kinetic_energy.
    κu★ = κuᶜᶜᶠ(i, j, k, grid, closure_ij, velocities, tracers, buoyancy, Jᵇ)
    κc★ = κcᶜᶜᶠ(i, j, k, grid, closure_ij, velocities, tracers, buoyancy, Jᵇ)
    κe★ = κeᶜᶜᶠ(i, j, k, grid, closure_ij, velocities, tracers, buoyancy, Jᵇ)

    κu★ = mask_diffusivity(i, j, k, grid, κu★)
    κc★ = mask_diffusivity(i, j, k, grid, κc★)
    κe★ = mask_diffusivity(i, j, k, grid, κe★)

    @inbounds begin
        diffusivities.κu[i, j, k] = κu★
        diffusivities.κc[i, j, k] = κc★
        diffusivities.κe[i, j, k] = κe★
    end
end

@inline function κuᶜᶜᶠ(i, j, k, grid, closure, velocities, tracers, buoyancy, surface_buoyancy_flux)
    w★ = ℑzᵃᵃᶠ(i, j, k, grid, turbulent_velocityᶜᶜᶜ, closure, tracers.e)
    ℓu = momentum_mixing_lengthᶜᶜᶠ(i, j, k, grid, closure, velocities, tracers, buoyancy, surface_buoyancy_flux)
    κu = ℓu * w★
    κu_max = closure.maximum_viscosity
    κu★ = min(κu, κu_max)
    FT = eltype(grid)
    return FT(κu★)
end

@inline function κcᶜᶜᶠ(i, j, k, grid, closure, velocities, tracers, buoyancy, surface_buoyancy_flux)
    w★ = ℑzᵃᵃᶠ(i, j, k, grid, turbulent_velocityᶜᶜᶜ, closure, tracers.e)
    ℓc = tracer_mixing_lengthᶜᶜᶠ(i, j, k, grid, closure, velocities, tracers, buoyancy, surface_buoyancy_flux)
    κc = ℓc * w★
    κc_max = closure.maximum_tracer_diffusivity
    κc★ = min(κc, κc_max)
    FT = eltype(grid)
    return FT(κc★)
end

@inline function κeᶜᶜᶠ(i, j, k, grid, closure, velocities, tracers, buoyancy, surface_buoyancy_flux)
    w★ = ℑzᵃᵃᶠ(i, j, k, grid, turbulent_velocityᶜᶜᶜ, closure, tracers.e)
    ℓe = TKE_mixing_lengthᶜᶜᶠ(i, j, k, grid, closure, velocities, tracers, buoyancy, surface_buoyancy_flux)
    κe = ℓe * w★
    κe_max = closure.maximum_tke_diffusivity
    κe★ = min(κe, κe_max)
    FT = eltype(grid)
    return FT(κe)
end

@inline viscosity(::FlavorOfCATKE, diffusivities) = diffusivities.κu
@inline diffusivity(::FlavorOfCATKE, diffusivities, ::Val{id}) where id = diffusivities._tupled_tracer_diffusivities[id]

#####
##### Show
#####

function Base.summary(closure::CATKEVD)
    TD = nameof(typeof(time_discretization(closure)))
    return string("CATKEVerticalDiffusivity{$TD}")
end

function Base.show(io::IO, clo::CATKEVD)
    print(io, summary(clo))
    print(io, '\n')
    print(io, "├── maximum_tracer_diffusivity: ", prettysummary(clo.maximum_tracer_diffusivity), '\n',
              "├── maximum_tke_diffusivity: ", prettysummary(clo.maximum_tke_diffusivity), '\n',
              "├── maximum_viscosity: ", prettysummary(clo.maximum_viscosity), '\n',
              "├── minimum_tke: ", prettysummary(clo.minimum_tke), '\n',
              "├── negative_tke_time_scale: ", prettysummary(clo.negative_tke_damping_time_scale), '\n',
              "├── minimum_convective_buoyancy_flux: ", prettysummary(clo.minimum_convective_buoyancy_flux), '\n',
              "├── tke_time_step: ", prettysummary(clo.tke_time_step), '\n',
              "├── mixing_length: ", prettysummary(clo.mixing_length), '\n',
              "│   ├── Cˢ:   ", prettysummary(clo.mixing_length.Cˢ), '\n',
              "│   ├── Cᵇ:   ", prettysummary(clo.mixing_length.Cᵇ), '\n',
              "│   ├── Cʰⁱu: ", prettysummary(clo.mixing_length.Cʰⁱu), '\n',
              "│   ├── Cʰⁱc: ", prettysummary(clo.mixing_length.Cʰⁱc), '\n',
              "│   ├── Cʰⁱe: ", prettysummary(clo.mixing_length.Cʰⁱe), '\n',
              "│   ├── Cˡᵒu: ", prettysummary(clo.mixing_length.Cˡᵒu), '\n',
              "│   ├── Cˡᵒc: ", prettysummary(clo.mixing_length.Cˡᵒc), '\n',
              "│   ├── Cˡᵒe: ", prettysummary(clo.mixing_length.Cˡᵒe), '\n',
              "│   ├── Cᵘⁿu: ", prettysummary(clo.mixing_length.Cᵘⁿu), '\n',
              "│   ├── Cᵘⁿc: ", prettysummary(clo.mixing_length.Cᵘⁿc), '\n',
              "│   ├── Cᵘⁿe: ", prettysummary(clo.mixing_length.Cᵘⁿe), '\n',
              "│   ├── Cᶜu:  ", prettysummary(clo.mixing_length.Cᶜu), '\n',
              "│   ├── Cᶜc:  ", prettysummary(clo.mixing_length.Cᶜc), '\n',
              "│   ├── Cᶜe:  ", prettysummary(clo.mixing_length.Cᶜe), '\n',
              "│   ├── Cᵉc:  ", prettysummary(clo.mixing_length.Cᵉc), '\n',
              "│   ├── Cᵉe:  ", prettysummary(clo.mixing_length.Cᵉe), '\n',
              "│   ├── Cˢᵖ:  ", prettysummary(clo.mixing_length.Cˢᵖ), '\n',
              "│   ├── CRiᵟ: ", prettysummary(clo.mixing_length.CRiᵟ), '\n',
              "│   └── CRi⁰: ", prettysummary(clo.mixing_length.CRi⁰), '\n',
              "└── turbulent_kinetic_energy_equation: ", prettysummary(clo.turbulent_kinetic_energy_equation), '\n',
              "    ├── CʰⁱD: ", prettysummary(clo.turbulent_kinetic_energy_equation.CʰⁱD),  '\n',
              "    ├── CˡᵒD: ", prettysummary(clo.turbulent_kinetic_energy_equation.CˡᵒD),  '\n',
              "    ├── CᵘⁿD: ", prettysummary(clo.turbulent_kinetic_energy_equation.CᵘⁿD),  '\n',
              "    ├── CᶜD:  ", prettysummary(clo.turbulent_kinetic_energy_equation.CᶜD),  '\n',
              "    ├── CᵉD:  ", prettysummary(clo.turbulent_kinetic_energy_equation.CᵉD),  '\n',
              "    ├── Cᵂu★: ", prettysummary(clo.turbulent_kinetic_energy_equation.Cᵂu★), '\n',
              "    ├── CᵂwΔ: ", prettysummary(clo.turbulent_kinetic_energy_equation.CᵂwΔ), '\n',
              "    └── Cᵂϵ:  ", prettysummary(clo.turbulent_kinetic_energy_equation.Cᵂϵ))
end
