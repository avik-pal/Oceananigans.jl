# Fallback constructor for diffusivity types without precomputed diffusivities.
DiffusivityFields(arch::AbstractArchitecture, grid::AbstractGrid, args...) = nothing

DiffusivityFields(arch::AbstractArchitecture, grid::AbstractGrid, tracers, closure_tuple::Tuple) =
    Tuple(DiffusivityFields(arch, grid, tracers, closure) for closure in closure_tuple)

#####
##### For closures that only require an eddy viscosity νₑ field.
#####

const NuClosures = Union{AbstractSmagorinsky, AbstractLeith}

DiffusivityFields(
    arch::AbstractArchitecture, grid::AbstractGrid, tracers, ::NuClosures;
    νₑ = CellField(arch, grid, DiffusivityBoundaryConditions(grid), zeros(arch, grid))
) = (νₑ=νₑ,)

function DiffusivityFields(arch::AbstractArchitecture, grid::AbstractGrid, tracers,
                           bcs::NamedTuple, ::NuClosures)
    νₑ_bcs = :νₑ ∈ keys(bcs) ? bcs[:νₑ] : DiffusivityBoundaryConditions(grid)
    νₑ = CellField(arch, grid, νₑ_bcs, zeros(arch, grid))
    return (νₑ=νₑ,)
end

#####
##### For closures that also require tracer diffusivity fields κₑ on each tracer.
#####

const NuKappaClosures = Union{VAMD, RAMD}

function KappaFields(arch, grid, tracer_names; kwargs...)
    κ_fields =
        Tuple(c ∈ keys(kwargs) ?
              kwargs[c] :
              CellField(arch, grid, DiffusivityBoundaryConditions(grid), zeros(arch, grid))
              for c in tracer_names)
    return NamedTuple{tracer_names}(κ_fields)
end

function KappaFields(arch, grid, tracer_names, bcs::NamedTuple)
    κ_fields =
        Tuple(c ∈ keys(bcs) ?
              CellField(arch, grid, bcs[c],                              zeros(arch, grid)) :
              CellField(arch, grid, DiffusivityBoundaryConditions(grid), zeros(arch, grid))
              for c in tracer_names)
    return NamedTuple{tracer_names}(κ_fields)
end

function DiffusivityFields(
    arch::AbstractArchitecture, grid::AbstractGrid, tracers, ::NuKappaClosures;
    νₑ = CellField(arch, grid, DiffusivityBoundaryConditions(grid), zeros(arch, grid)), kwargs...)
    κₑ = KappaFields(arch, grid, tracers; kwargs...)
    return (νₑ=νₑ, κₑ=κₑ)
end

function DiffusivityFields(arch::AbstractArchitecture, grid::AbstractGrid, tracers,
                           bcs::NamedTuple, ::NuKappaClosures)

    νₑ_bcs = :νₑ ∈ keys(bcs) ? bcs[:νₑ] : DiffusivityBoundaryConditions(grid)
    νₑ = CellField(arch, grid, νₑ_bcs, zeros(arch, grid))

    κₑ = :κₑ ∈ keys(bcs) ?
        KappaFields(arch, grid, tracers, bcs[:κₑ]) :
        KappaFields(arch, grid, tracers)

    return (νₑ=νₑ, κₑ=κₑ)
end
