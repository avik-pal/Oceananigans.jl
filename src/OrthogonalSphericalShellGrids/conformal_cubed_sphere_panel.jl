using CubedSphere
using JLD2

struct CubedSphereConformalMapping{Rotation, Fξ, Fη, Cξ, Cη}
    rotation :: Rotation
    ξᶠᵃᵃ :: Fξ
    ηᵃᶠᵃ :: Fη
    ξᶜᵃᵃ :: Cξ
    ηᵃᶜᵃ :: Cη

    CubedSphereConformalMapping(
        rotation::Rotation,
        ξᶠᵃᵃ::Fξ,
        ηᵃᶠᵃ::Fη,
        ξᶜᵃᵃ::Cξ,
        ηᵃᶜᵃ::Cη
    ) where {Rotation, Fξ, Fη, Cξ, Cη} = new{Rotation, Fξ, Fη, Cξ, Cη}(rotation, ξᶠᵃᵃ, ηᵃᶠᵃ, ξᶜᵃᵃ, ηᵃᶜᵃ)
end

function on_architecture(architecture, conformal_mapping::CubedSphereConformalMapping)
    return CubedSphereConformalMapping(
        conformal_mapping.rotation,
        on_architecture(architecture, conformal_mapping.ξᶠᵃᵃ),
        on_architecture(architecture, conformal_mapping.ηᵃᶠᵃ),
        on_architecture(architecture, conformal_mapping.ξᶜᵃᵃ),
        on_architecture(architecture, conformal_mapping.ηᵃᶜᵃ)
    )
end

function Adapt.adapt_structure(to, conformal_mapping::CubedSphereConformalMapping)
    return CubedSphereConformalMapping(
        adapt(to, conformal_mapping.rotation),
        adapt(to, conformal_mapping.ξᶠᵃᵃ),
        adapt(to, conformal_mapping.ηᵃᶠᵃ),
        adapt(to, conformal_mapping.ξᶜᵃᵃ),
        adapt(to, conformal_mapping.ηᵃᶜᵃ))
end

const ConformalCubedSpherePanelGrid{FT, TX, TY, TZ, CZ, CC, FC, CF, FF, Arch} = 
    OrthogonalSphericalShellGrid{FT, TX, TY, TZ, CZ, <:CubedSphereConformalMapping, CC, FC, CF, FF, Arch}
const ConformalCubedSpherePanelGridOfSomeKind{FT, TX, TY, TZ, CZ, CC, FC, CF, FF, Arch} = 
    Union{ConformalCubedSpherePanelGrid{FT, TX, TY, TZ, CZ, CC, FC, CF, FF, Arch},
          ImmersedBoundaryGrid{<:Any, <:Any, <:Any, <:Any, <:ConformalCubedSpherePanelGrid{FT, TX, TY, TZ, CZ, CC, FC, CF, FF, Arch}}}

# architecture = CPU() by default, assuming that a DataType positional arg is specifying the floating point type.
ConformalCubedSpherePanelGrid(FT::DataType; kwargs...) = ConformalCubedSpherePanelGrid(CPU(), FT; kwargs...)

function load_and_offset_cubed_sphere_data(file, FT, arch, field_name, loc, topo, N, H)
    data = on_architecture(arch, file[field_name])
    data = convert.(FT, data)

    return offset_data(data, loc[1:2], topo[1:2], N[1:2], H[1:2])
end

function ConformalCubedSpherePanelGrid(filepath::AbstractString, architecture = CPU(), FT = Float64;
                                       panel, Nz, z,
                                       topology = (FullyConnected, FullyConnected, Bounded),
                                         radius = R_Earth,
                                           halo = (4, 4, 4),
                                       rotation = nothing)

    TX, TY, TZ = topology
    Hx, Hy, Hz = halo

    ## Read everything from the file except the z-coordinates.

    file = jldopen(filepath, "r")["panel$panel"]

    Nξ, Nη = size(file["λᶠᶠᵃ"])
    Hξ, Hη = halo[1], halo[2]
    Nξ -= 2Hξ
    Nη -= 2Hη

    N = (Nξ, Nη, Nz)
    H = halo

    loc_cc = (Center, Center)
    loc_fc = (Face,   Center)
    loc_cf = (Center, Face)
    loc_ff = (Face,   Face)

    # Use a regular rectilinear grid for the face of the cube.
    ξη_grid_topology = (Bounded, Bounded, TZ)

    ξ = (-1, 1)
    η = (-1, 1)

    ξη_grid = RectilinearGrid(architecture, FT;
                              size = (Nξ, Nη, Nz),
                              topology = ξη_grid_topology,
                              x = ξ, y = η, z, halo)

     ξᶠᵃᵃ = xnodes(ξη_grid, Face())
     ξᶜᵃᵃ = xnodes(ξη_grid, Center())
     ηᵃᶠᵃ = ynodes(ξη_grid, Face())
     ηᵃᶜᵃ = ynodes(ξη_grid, Center())

     λᶜᶜᵃ = load_and_offset_cubed_sphere_data(file, FT, architecture, "λᶜᶜᵃ", loc_cc, topology, N, H)
     λᶠᶠᵃ = load_and_offset_cubed_sphere_data(file, FT, architecture, "λᶠᶠᵃ", loc_ff, topology, N, H)

     φᶜᶜᵃ = load_and_offset_cubed_sphere_data(file, FT, architecture, "φᶜᶜᵃ", loc_cc, topology, N, H)
     φᶠᶠᵃ = load_and_offset_cubed_sphere_data(file, FT, architecture, "φᶠᶠᵃ", loc_ff, topology, N, H)

    Δxᶜᶜᵃ = load_and_offset_cubed_sphere_data(file, FT, architecture, "Δxᶜᶜᵃ", loc_cc, topology, N, H)
    Δxᶠᶜᵃ = load_and_offset_cubed_sphere_data(file, FT, architecture, "Δxᶠᶜᵃ", loc_fc, topology, N, H)
    Δxᶜᶠᵃ = load_and_offset_cubed_sphere_data(file, FT, architecture, "Δxᶜᶠᵃ", loc_cf, topology, N, H)
    Δxᶠᶠᵃ = load_and_offset_cubed_sphere_data(file, FT, architecture, "Δxᶠᶠᵃ", loc_ff, topology, N, H)

    Δyᶜᶜᵃ = load_and_offset_cubed_sphere_data(file, FT, architecture, "Δyᶜᶜᵃ", loc_cc, topology, N, H)
    Δyᶠᶜᵃ = load_and_offset_cubed_sphere_data(file, FT, architecture, "Δyᶠᶜᵃ", loc_fc, topology, N, H)
    Δyᶜᶠᵃ = load_and_offset_cubed_sphere_data(file, FT, architecture, "Δyᶜᶠᵃ", loc_cf, topology, N, H)
    Δyᶠᶠᵃ = load_and_offset_cubed_sphere_data(file, FT, architecture, "Δyᶠᶠᵃ", loc_ff, topology, N, H)

    Azᶜᶜᵃ = load_and_offset_cubed_sphere_data(file, FT, architecture, "Azᶜᶜᵃ", loc_cc, topology, N, H)
    Azᶠᶜᵃ = load_and_offset_cubed_sphere_data(file, FT, architecture, "Azᶠᶜᵃ", loc_fc, topology, N, H)
    Azᶜᶠᵃ = load_and_offset_cubed_sphere_data(file, FT, architecture, "Azᶜᶠᵃ", loc_cf, topology, N, H)
    Azᶠᶠᵃ = load_and_offset_cubed_sphere_data(file, FT, architecture, "Azᶠᶠᵃ", loc_ff, topology, N, H)

    ## Maybe we won't need these?
    Txᶠᶜ = total_length(loc_fc[1](), topology[1](), N[1], H[1])
    Txᶜᶠ = total_length(loc_cf[1](), topology[1](), N[1], H[1])
    Tyᶠᶜ = total_length(loc_fc[2](), topology[2](), N[2], H[2])
    Tyᶜᶠ = total_length(loc_cf[2](), topology[2](), N[2], H[2])

    λᶠᶜᵃ = offset_data(zeros(architecture, FT, Txᶠᶜ, Tyᶠᶜ), loc_fc, topology[1:2], N[1:2], H[1:2])
    λᶜᶠᵃ = offset_data(zeros(architecture, FT, Txᶜᶠ, Tyᶜᶠ), loc_cf, topology[1:2], N[1:2], H[1:2])
    φᶠᶜᵃ = offset_data(zeros(architecture, FT, Txᶠᶜ, Tyᶠᶜ), loc_fc, topology[1:2], N[1:2], H[1:2])
    φᶜᶠᵃ = offset_data(zeros(architecture, FT, Txᶜᶠ, Tyᶜᶠ), loc_cf, topology[1:2], N[1:2], H[1:2])

    ## The vertical coordinates can come out of the regular rectilinear grid!
    Lz, z  = generate_coordinate(FT, topology, (Nξ, Nη, Nz), halo, z,  :z, 3, architecture)

    conformal_mapping = CubedSphereConformalMapping(rotation, ξᶠᵃᵃ, ηᵃᶠᵃ, ξᶜᵃᵃ, ηᵃᶜᵃ)
    conformal_mapping = on_architecture(architecture, conformal_mapping)

    return OrthogonalSphericalShellGrid{TX, TY, TZ}(architecture, Nξ, Nη, Nz, Hx, Hy, Hz, Lz,
                                                     λᶜᶜᵃ,  λᶠᶜᵃ,  λᶜᶠᵃ,  λᶠᶠᵃ,
                                                     φᶜᶜᵃ,  φᶠᶜᵃ,  φᶜᶠᵃ,  φᶠᶠᵃ,
                                                     z,
                                                    Δxᶜᶜᵃ, Δxᶠᶜᵃ, Δxᶜᶠᵃ, Δxᶠᶠᵃ,
                                                    Δyᶜᶜᵃ, Δyᶠᶜᵃ, Δyᶜᶠᵃ, Δyᶠᶠᵃ,
                                                    Azᶜᶜᵃ, Azᶠᶜᵃ, Azᶜᶠᵃ, Azᶠᶠᵃ,
                                                    radius,
                                                    conformal_mapping)
end

function with_halo(new_halo, old_grid::ConformalCubedSpherePanelGrid; arch=architecture(old_grid), rotation=nothing)
    size = (old_grid.Nx, old_grid.Ny, old_grid.Nz)
    topo = topology(old_grid)

    z = cpu_face_constructor_z(old_grid)

    provided_conformal_mapping = old_grid.conformal_mapping

    new_grid = ConformalCubedSpherePanelGrid(arch, eltype(old_grid);
                                             size, z,
                                             topology = topo,
                                             radius = old_grid.radius,
                                             halo = new_halo,
                                             rotation,
                                             provided_conformal_mapping)

    return new_grid
end

"""
    ConformalCubedSpherePanelGrid(architecture::AbstractArchitecture = CPU(),
                                  FT::DataType = Float64;
                                  size,
                                  z,
                                  topology = (Bounded, Bounded, Bounded),
                                  ξ = (-1, 1),
                                  η = (-1, 1),
                                  radius = R_Earth,
                                  halo = (1, 1, 1),
                                  rotation = nothing,
                                  non_uniform_conformal_mapping = false,
                                  spacing_type = "geometric",
                                  provided_conformal_mapping = nothing)

Create a `OrthogonalSphericalShellGrid` that represents a section of a sphere after it has been conformally mapped from
the face of a cube. The cube's coordinates are `ξ` and `η` (which, by default, both take values in the range
``[-1, 1]``.

The mapping from the face of the cube to the sphere is done via the
[CubedSphere.jl](https://github.com/CliMA/CubedSphere.jl) package.

Positional arguments
====================

- `architecture`: Specifies whether arrays of coordinates and spacings are stored on the CPU or GPU. Default: `CPU()`.

- `FT` : Floating point data type. Default: `Float64`.

Keyword arguments
=================

- `size` (required): A 3-tuple prescribing the number of grid points each direction.

- `z` (required): Either a
    1. 2-tuple that specify the end points of the ``z``-domain,
    2. one-dimensional array specifying the cell interface locations, or
    3. a single-argument function that takes an index and returns cell interface location.

- `topology`: A 3-tuple `(TX, TY, TZ)` specifying the topology of the domain. `TX`, `TY`, and `TZ` specify whether the
              `x`-, `y`-, and `z` directions are `Periodic`, `Bounded`, `Flat` or `FullyConnected`. The topology `Flat`
              indicates that a model does not vary in those directions so that derivatives and interpolation are zero.
              The default is `topology = (Bounded, Bounded, Bounded)`.

- `ξ`, `η`: Tuples specifying the ranges of the one-dimensional computational coordinates of the cubed sphere panel
            grid. Defaults to (-1, 1) for both.

- `radius`: The radius of the sphere the grid lives on. By default this is equal to the radius of Earth.

- `halo`: A 3-tuple of integers specifying the size of the halo region of cells surrounding the physical interior. The
          default is 1 halo cell in every direction.

- `rotation :: Rotation`: Rotation of the conformal cubed sphere panel about some axis that passes through the center of
                          the sphere. If `nothing` is provided (default), then the panel includes the North Pole of the
                          sphere in its center. For example, to construct a grid that includes tha South Pole we can
                          pass either `rotation = RotX(π)` or `rotation = RotY(π)`.

- `non_uniform_conformal_mapping`: If `true`, the cubed sphere panel grid will be generated using a non-uniform
                                   conformal mapping. The default is `false`.

- `spacing_type`: Specifies the spacing scheme for the non-uniform conformal mapping. Options are `"geometric"`
                  (default) or `"exponential"`.

- `provided_conformal_mapping`: The conformal mapping supplied by the user. Defaults to nothing.

Examples
========

* The default conformal cubed sphere panel grid with `Float64` type:

```jldoctest
julia> using Oceananigans, Oceananigans.OrthogonalSphericalShellGrids

julia> grid = ConformalCubedSpherePanelGrid(size=(36, 34, 25), z=(-1000, 0))
36×34×25 OrthogonalSphericalShellGrid{Float64, Bounded, Bounded, Bounded} on CPU with 1×1×1 halo and with precomputed metrics
├── centered at: North Pole, (λ, φ) = (0.0, 90.0)
├── longitude: Bounded  extent 90.0 degrees variably spaced with min(Δλ)=0.616164, max(Δλ)=2.58892
├── latitude:  Bounded  extent 90.0 degrees variably spaced with min(Δφ)=0.664958, max(Δφ)=2.74119
└── z:         Bounded  z ∈ [-1000.0, 0.0]  regularly spaced with Δz=40.0
```

* The conformal cubed sphere panel that includes the South Pole with `Float32` type:

```jldoctest
julia> using Oceananigans, Oceananigans.OrthogonalSphericalShellGrids, Rotations

julia> grid = ConformalCubedSpherePanelGrid(Float32, size=(36, 34, 25), z=(-1000, 0), rotation=RotY(π))
36×34×25 OrthogonalSphericalShellGrid{Float32, Bounded, Bounded, Bounded} on CPU with 1×1×1 halo and with precomputed metrics
├── centered at: South Pole, (λ, φ) = (0.0, -90.0)
├── longitude: Bounded  extent 90.0 degrees variably spaced with min(Δλ)=0.616167, max(Δλ)=2.58891
├── latitude:  Bounded  extent 90.0 degrees variably spaced with min(Δφ)=0.664956, max(Δφ)=2.7412
└── z:         Bounded  z ∈ [-1000.0, 0.0]  regularly spaced with Δz=40.0
```
"""
function ConformalCubedSpherePanelGrid(architecture::AbstractArchitecture = CPU(),
                                       FT::DataType = Oceananigans.defaults.FloatType;
                                       size,
                                       z,
                                       topology = (Bounded, Bounded, Bounded),
                                       ξ = (-1, 1),
                                       η = (-1, 1),
                                       radius = R_Earth,
                                       halo = (1, 1, 1),
                                       rotation = nothing,
                                       non_uniform_conformal_mapping = false,
                                       spacing_type = "geometric",
                                       provided_conformal_mapping = nothing)

    radius = FT(radius)
    TX, TY, TZ = topology
    Nξ, Nη, Nz = size
    Hx, Hy, Hz = halo

    # Use a regular rectilinear grid for the face of the cube. 
    ξη_grid_topology = (Bounded, Bounded, topology[3])

    # Construct the grid on CPU and convert to architecture later...
    ξη_grid = RectilinearGrid(CPU(), FT;
                              size = (Nξ, Nη, Nz),
                              topology = ξη_grid_topology,
                              x = ξ, y = η, z, halo)

    if !isnothing(provided_conformal_mapping)
        ξᶠᵃᵃ = on_architecture(CPU(), provided_conformal_mapping.ξᶠᵃᵃ)
        ηᵃᶠᵃ = on_architecture(CPU(), provided_conformal_mapping.ηᵃᶠᵃ)
        ξᶜᵃᵃ = on_architecture(CPU(), provided_conformal_mapping.ξᶜᵃᵃ)
        ηᵃᶜᵃ = on_architecture(CPU(), provided_conformal_mapping.ηᵃᶜᵃ)
    else
        if non_uniform_conformal_mapping
            ξᶠᵃᵃ, ηᵃᶠᵃ, xᶠᶠᵃ, yᶠᶠᵃ, z = (
            optimized_non_uniform_conformal_cubed_sphere_coordinates(Nξ+1, Nη+1, spacing_type))
            ξᶠᵃᵃ = map(FT, ξᶠᵃᵃ)
            ηᵃᶠᵃ = map(FT, ηᵃᶠᵃ)
            ξᶜᵃᵃ = [FT(0.5 * (ξᶠᵃᵃ[i] + ξᶠᵃᵃ[i+1])) for i in 1:Nξ]
            ηᵃᶜᵃ = [FT(0.5 * (ηᵃᶠᵃ[j] + ηᵃᶠᵃ[j+1])) for j in 1:Nη]
        else
            ξᶠᵃᵃ = xnodes(ξη_grid, Face())
            ξᶜᵃᵃ = xnodes(ξη_grid, Center())
            ηᵃᶠᵃ = ynodes(ξη_grid, Face())
            ηᵃᶜᵃ = ynodes(ξη_grid, Center())
        end
    end

    ## The vertical coordinates and metrics can come out of the regular rectilinear grid!
    zc = ξη_grid.z
    Lz = ξη_grid.Lz

    ## Compute staggered grid latitude-longitude (φ, λ) coordinates.

    λᶜᶜᵃ = zeros(FT, Nξ  , Nη  )
    λᶠᶜᵃ = zeros(FT, Nξ+1, Nη  )
    λᶜᶠᵃ = zeros(FT, Nξ  , Nη+1)
    λᶠᶠᵃ = zeros(FT, Nξ+1, Nη+1)

    φᶜᶜᵃ = zeros(FT, Nξ  , Nη  )
    φᶠᶜᵃ = zeros(FT, Nξ+1, Nη  )
    φᶜᶠᵃ = zeros(FT, Nξ  , Nη+1)
    φᶠᶠᵃ = zeros(FT, Nξ+1, Nη+1)

    ξS = (ξᶜᵃᵃ, ξᶠᵃᵃ, ξᶜᵃᵃ, ξᶠᵃᵃ)
    ηS = (ηᵃᶜᵃ, ηᵃᶜᵃ, ηᵃᶠᵃ, ηᵃᶠᵃ)
    λS = (λᶜᶜᵃ, λᶠᶜᵃ, λᶜᶠᵃ, λᶠᶠᵃ)
    φS = (φᶜᶜᵃ, φᶠᶜᵃ, φᶜᶠᵃ, φᶠᶠᵃ)

    for (ξ, η, λ, φ) in zip(ξS, ηS, λS, φS)
        for j in 1:length(η), i in 1:length(ξ)
            x, y, z = @inbounds conformal_cubed_sphere_mapping(ξ[i], η[j])

            if !isnothing(rotation)
                x, y, z = rotation * [x, y, z]
            end

            @inbounds φ[i, j], λ[i, j] = cartesian_to_lat_lon(x, y, z)
        end
    end

    any(any.(isnan, λS)) &&
        @warn "OrthogonalSphericalShellGrid contains a grid point at a pole whose longitude is undefined (NaN)."

    ## Grid metrics

    # Horizontal distances

    #=
    Distances Δx and Δy are computed via the haversine formula provided by the Distances.jl package. For example,
    Δx = Δσ * radius, where Δσ is the central angle subtended between the two endpoints that define the distance Δx.

    For cells near the boundary of the conformal cubed sphere panel, one of the points defining, e.g., Δx might lie
    outside the grid! For instance, the central angle Δxᶠᶜᵃ[1, j] is given by:

        Δxᶠᶜᵃ[1, j] = haversine((λᶜᶜᵃ[1, j], φᶜᶜᵃ[1, j]), (λᶜᶜᵃ[0, j], φᶜᶜᵃ[0, j]), radius)

    Notice that, e.g., point (φᶜᶜᵃ[0, j], λᶜᶜᵃ[0, j]) is outside the boundaries of the grid. In those cases, we employ
    symmetry arguments and compute, e.g, Δxᶠᶜᵃ[1, j] via

        Δxᶠᶜᵃ[1, j] = 2 * haversine((λᶜᶜᵃ[1, j], φᶜᶜᵃ[1, j]), (λᶠᶜᵃ[1, j], φᶠᶜᵃ[1, j]), radius)
    =#

    Δxᶜᶜᵃ = zeros(FT, Nξ  , Nη  )
    Δxᶠᶜᵃ = zeros(FT, Nξ+1, Nη  )
    Δxᶜᶠᵃ = zeros(FT, Nξ  , Nη+1)
    Δxᶠᶠᵃ = zeros(FT, Nξ+1, Nη+1)

    @inbounds begin
        #Δxᶜᶜᵃ

        for i in 1:Nξ, j in 1:Nη
            Δxᶜᶜᵃ[i, j] = haversine((λᶠᶜᵃ[i+1, j], φᶠᶜᵃ[i+1, j]), (λᶠᶜᵃ[i, j], φᶠᶜᵃ[i, j]), radius)
        end

        # Δxᶠᶜᵃ

        for j in 1:Nη, i in 2:Nξ
            Δxᶠᶜᵃ[i, j] = haversine((λᶜᶜᵃ[i, j], φᶜᶜᵃ[i, j]), (λᶜᶜᵃ[i-1, j], φᶜᶜᵃ[i-1, j]), radius)
        end

        for j in 1:Nη
            i = 1
            Δxᶠᶜᵃ[i, j] = 2haversine((λᶜᶜᵃ[i, j], φᶜᶜᵃ[i, j]), (λᶠᶜᵃ[ i , j], φᶠᶜᵃ[ i , j]), radius)
        end

        for j in 1:Nη
            i = Nξ+1
            Δxᶠᶜᵃ[i, j] = 2haversine((λᶠᶜᵃ[i, j], φᶠᶜᵃ[i, j]), (λᶜᶜᵃ[i-1, j], φᶜᶜᵃ[i-1, j]), radius)
        end

        # Δxᶜᶠᵃ

        for j in 1:Nη+1, i in 1:Nξ
            Δxᶜᶠᵃ[i, j] = haversine((λᶠᶠᵃ[i+1, j], φᶠᶠᵃ[i+1, j]), (λᶠᶠᵃ[i, j], φᶠᶠᵃ[i, j]), radius)
        end

        # Δxᶠᶠᵃ

        for j in 1:Nη+1, i in 2:Nξ
            Δxᶠᶠᵃ[i, j] = haversine((λᶜᶠᵃ[i, j], φᶜᶠᵃ[i, j]), (λᶜᶠᵃ[i-1, j], φᶜᶠᵃ[i-1, j]), radius)
        end

        for j in 1:Nη+1
            i = 1
            Δxᶠᶠᵃ[i, j] = 2haversine((λᶜᶠᵃ[i, j], φᶜᶠᵃ[i, j]), (λᶠᶠᵃ[ i , j], φᶠᶠᵃ[ i , j]), radius)
        end

        for j in 1:Nη+1
            i = Nξ+1
            Δxᶠᶠᵃ[i, j] = 2haversine((λᶠᶠᵃ[i, j], φᶠᶠᵃ[i, j]), (λᶜᶠᵃ[i-1, j], φᶜᶠᵃ[i-1, j]), radius)
        end
    end

    Δyᶜᶜᵃ = zeros(FT, Nξ  , Nη  )
    Δyᶠᶜᵃ = zeros(FT, Nξ+1, Nη  )
    Δyᶜᶠᵃ = zeros(FT, Nξ  , Nη+1)
    Δyᶠᶠᵃ = zeros(FT, Nξ+1, Nη+1)

    @inbounds begin
        # Δyᶜᶜᵃ

        for j in 1:Nη, i in 1:Nξ
            Δyᶜᶜᵃ[i, j] = haversine((λᶜᶠᵃ[i, j+1], φᶜᶠᵃ[i, j+1]), (λᶜᶠᵃ[i, j], φᶜᶠᵃ[i, j]), radius)
        end

        # Δyᶜᶠᵃ

        for j in 2:Nη, i in 1:Nξ
            Δyᶜᶠᵃ[i, j] = haversine((λᶜᶜᵃ[i, j], φᶜᶜᵃ[i, j]), (λᶜᶜᵃ[i, j-1], φᶜᶜᵃ[i, j-1]), radius)
        end

        for i in 1:Nξ
            j = 1
            Δyᶜᶠᵃ[i, j] = 2haversine((λᶜᶜᵃ[i, j], φᶜᶜᵃ[i, j]), (λᶜᶠᵃ[i,  j ], φᶜᶠᵃ[i,  j ]), radius)
        end

        for i in 1:Nξ
            j = Nη+1
            Δyᶜᶠᵃ[i, j] = 2haversine((λᶜᶠᵃ[i, j], φᶜᶠᵃ[i, j]), (λᶜᶜᵃ[i, j-1], φᶜᶜᵃ[i, j-1]), radius)
        end

        # Δyᶠᶜᵃ

        for j in 1:Nη, i in 1:Nξ+1
            Δyᶠᶜᵃ[i, j] = haversine((λᶠᶠᵃ[i, j+1], φᶠᶠᵃ[i, j+1]), (λᶠᶠᵃ[i, j], φᶠᶠᵃ[i, j]), radius)
        end

        # Δyᶠᶠᵃ

        for j in 2:Nη, i in 1:Nξ+1
            Δyᶠᶠᵃ[i, j] = haversine((λᶠᶜᵃ[i, j], φᶠᶜᵃ[i, j]), (λᶠᶜᵃ[i, j-1], φᶠᶜᵃ[i, j-1]), radius)
        end

        for i in 1:Nξ+1
            j = 1
            Δyᶠᶠᵃ[i, j] = 2haversine((λᶠᶜᵃ[i, j], φᶠᶜᵃ[i, j]), (λᶠᶠᵃ[i,  j ], φᶠᶠᵃ[i,  j ]), radius)
        end

        for i in 1:Nξ+1
            j = Nη+1
            Δyᶠᶠᵃ[i, j] = 2haversine((λᶠᶠᵃ[i, j], φᶠᶠᵃ[i, j]), (λᶠᶜᵃ[i, j-1], φᶠᶜᵃ[i, j-1]), radius)
        end
    end

    # Area metrics

    #=
    The areas Az correspond to spherical quadrilaterals. To compute Az first we find the vertices a, b, c, d of the
    corresponding quadrilateral and then use

        Az = spherical_area_quadrilateral(a, b, c, d) * radius^2

    For quadrilaterals near the boundary of the conformal cubed sphere panel, some of the vertices lie outside the grid!
    For example, the area Azᶠᶜᵃ[1, j] corresponds to a quadrilateral with vertices:

        a = (φᶜᶠᵃ[0,  j ], λᶜᶠᵃ[0,  j ])
        b = (φᶜᶠᵃ[1,  j ], λᶜᶠᵃ[1,  j ])
        c = (φᶜᶠᵃ[1, j+1], λᶜᶠᵃ[1, j+1])
        d = (φᶜᶠᵃ[0, j+1], λᶜᶠᵃ[0, j+1])

    Notice that vertices a and d are outside the boundaries of the grid. In those cases, we employ symmetry arguments
    and, e.g., compute Azᶠᶜᵃ[1, j] as

        2 * spherical_area_quadrilateral(ã, b, c, d̃) * radius^2

    where, ã = (φᶠᶠᵃ[1, j], λᶠᶠᵃ[1, j]) and d̃ = (φᶠᶠᵃ[1, j+1], λᶠᶠᵃ[1, j+1])
    =#

    Azᶜᶜᵃ = zeros(FT, Nξ  , Nη  )
    Azᶠᶜᵃ = zeros(FT, Nξ+1, Nη  )
    Azᶜᶠᵃ = zeros(FT, Nξ  , Nη+1)
    Azᶠᶠᵃ = zeros(FT, Nξ+1, Nη+1)

    @inbounds begin
        # Azᶜᶜᵃ

        for j in 1:Nη, i in 1:Nξ
            a = lat_lon_to_cartesian(φᶠᶠᵃ[ i ,  j ], λᶠᶠᵃ[ i ,  j ], 1)
            b = lat_lon_to_cartesian(φᶠᶠᵃ[i+1,  j ], λᶠᶠᵃ[i+1,  j ], 1)
            c = lat_lon_to_cartesian(φᶠᶠᵃ[i+1, j+1], λᶠᶠᵃ[i+1, j+1], 1)
            d = lat_lon_to_cartesian(φᶠᶠᵃ[ i , j+1], λᶠᶠᵃ[ i , j+1], 1)

            Azᶜᶜᵃ[i, j] = spherical_area_quadrilateral(a, b, c, d) * radius^2
        end

        # Azᶠᶜᵃ

        for j in 1:Nη, i in 2:Nξ
            a = lat_lon_to_cartesian(φᶜᶠᵃ[i-1,  j ], λᶜᶠᵃ[i-1,  j ], 1)
            b = lat_lon_to_cartesian(φᶜᶠᵃ[ i ,  j ], λᶜᶠᵃ[ i ,  j ], 1)
            c = lat_lon_to_cartesian(φᶜᶠᵃ[ i , j+1], λᶜᶠᵃ[ i , j+1], 1)
            d = lat_lon_to_cartesian(φᶜᶠᵃ[i-1, j+1], λᶜᶠᵃ[i-1, j+1], 1)

            Azᶠᶜᵃ[i, j] = spherical_area_quadrilateral(a, b, c, d) * radius^2
        end

        for j in 1:Nη
            i = 1
            a = lat_lon_to_cartesian(φᶠᶠᵃ[ i ,  j ], λᶠᶠᵃ[ i ,  j ], 1)
            b = lat_lon_to_cartesian(φᶜᶠᵃ[ i ,  j ], λᶜᶠᵃ[ i ,  j ], 1)
            c = lat_lon_to_cartesian(φᶜᶠᵃ[ i , j+1], λᶜᶠᵃ[ i , j+1], 1)
            d = lat_lon_to_cartesian(φᶠᶠᵃ[ i , j+1], λᶠᶠᵃ[ i , j+1], 1)

            Azᶠᶜᵃ[i, j] = 2 * spherical_area_quadrilateral(a, b, c, d) * radius^2
        end

        for j in 1:Nη
            i = Nξ+1
            a = lat_lon_to_cartesian(φᶜᶠᵃ[i-1,  j ], λᶜᶠᵃ[i-1,  j ], 1)
            b = lat_lon_to_cartesian(φᶠᶠᵃ[ i ,  j ], λᶠᶠᵃ[ i ,  j ], 1)
            c = lat_lon_to_cartesian(φᶠᶠᵃ[ i , j+1], λᶠᶠᵃ[ i , j+1], 1)
            d = lat_lon_to_cartesian(φᶜᶠᵃ[i-1, j+1], λᶜᶠᵃ[i-1, j+1], 1)

            Azᶠᶜᵃ[i, j] = 2 * spherical_area_quadrilateral(a, b, c, d) * radius^2
        end

        # Azᶜᶠᵃ

        for j in 2:Nη, i in 1:Nξ
            a = lat_lon_to_cartesian(φᶠᶜᵃ[ i , j-1], λᶠᶜᵃ[ i , j-1], 1)
            b = lat_lon_to_cartesian(φᶠᶜᵃ[i+1, j-1], λᶠᶜᵃ[i+1, j-1], 1)
            c = lat_lon_to_cartesian(φᶠᶜᵃ[i+1,  j ], λᶠᶜᵃ[i+1,  j ], 1)
            d = lat_lon_to_cartesian(φᶠᶜᵃ[ i ,  j ], λᶠᶜᵃ[ i ,  j ], 1)

            Azᶜᶠᵃ[i, j] = spherical_area_quadrilateral(a, b, c, d) * radius^2
        end

        for i in 1:Nξ
            j = 1
            a = lat_lon_to_cartesian(φᶠᶠᵃ[ i , j ], λᶠᶠᵃ[ i , j ], 1)
            b = lat_lon_to_cartesian(φᶠᶠᵃ[i+1, j ], λᶠᶠᵃ[i+1, j ], 1)
            c = lat_lon_to_cartesian(φᶠᶜᵃ[i+1, j ], λᶠᶜᵃ[i+1, j ], 1)
            d = lat_lon_to_cartesian(φᶠᶜᵃ[ i , j ], λᶠᶜᵃ[ i , j ], 1)

            Azᶜᶠᵃ[i, j] = 2 * spherical_area_quadrilateral(a, b, c, d) * radius^2
        end

        for i in 1:Nξ
            j = Nη+1
            a = lat_lon_to_cartesian(φᶠᶜᵃ[ i , j-1], λᶠᶜᵃ[ i , j-1], 1)
            b = lat_lon_to_cartesian(φᶠᶜᵃ[i+1, j-1], λᶠᶜᵃ[i+1, j-1], 1)
            c = lat_lon_to_cartesian(φᶠᶠᵃ[i+1,  j ], λᶠᶠᵃ[i+1,  j ], 1)
            d = lat_lon_to_cartesian(φᶠᶠᵃ[ i ,  j ], λᶠᶠᵃ[ i ,  j ], 1)

            Azᶜᶠᵃ[i, j] = 2 * spherical_area_quadrilateral(a, b, c, d) * radius^2
        end

        # Azᶠᶠᵃ

        for j in 2:Nη, i in 2:Nξ
            a = lat_lon_to_cartesian(φᶜᶜᵃ[i-1, j-1], λᶜᶜᵃ[i-1, j-1], 1)
            b = lat_lon_to_cartesian(φᶜᶜᵃ[ i , j-1], λᶜᶜᵃ[ i , j-1], 1)
            c = lat_lon_to_cartesian(φᶜᶜᵃ[ i ,  j ], λᶜᶜᵃ[ i ,  j ], 1)
            d = lat_lon_to_cartesian(φᶜᶜᵃ[i-1,  j ], λᶜᶜᵃ[i-1,  j ], 1)

            Azᶠᶠᵃ[i, j] = spherical_area_quadrilateral(a, b, c, d) * radius^2
        end

        for i in 2:Nξ
            j = 1
            a = lat_lon_to_cartesian(φᶜᶠᵃ[i-1, j ], λᶜᶠᵃ[i-1, j ], 1)
            b = lat_lon_to_cartesian(φᶜᶠᵃ[ i , j ], λᶜᶠᵃ[ i , j ], 1)
            c = lat_lon_to_cartesian(φᶜᶜᵃ[ i , j ], λᶜᶜᵃ[ i , j ], 1)
            d = lat_lon_to_cartesian(φᶜᶜᵃ[i-1, j ], λᶜᶜᵃ[i-1, j ], 1)

            Azᶠᶠᵃ[i, j] = 2 * spherical_area_quadrilateral(a, b, c, d) * radius^2
        end

        for i in 2:Nξ
            j = Nη+1
            a = lat_lon_to_cartesian(φᶜᶜᵃ[i-1, j-1], λᶜᶜᵃ[i-1, j-1], 1)
            b = lat_lon_to_cartesian(φᶜᶜᵃ[ i , j-1], λᶜᶜᵃ[ i , j-1], 1)
            c = lat_lon_to_cartesian(φᶜᶠᵃ[ i ,  j ], λᶜᶠᵃ[ i ,  j ], 1)
            d = lat_lon_to_cartesian(φᶜᶠᵃ[i-1,  j ], λᶜᶠᵃ[i-1,  j ], 1)

            Azᶠᶠᵃ[i, j] = 2 * spherical_area_quadrilateral(a, b, c, d) * radius^2
        end

        for j in 2:Nη
            i = 1
            a = lat_lon_to_cartesian(φᶠᶜᵃ[ i , j-1], λᶠᶜᵃ[ i , j-1], 1)
            b = lat_lon_to_cartesian(φᶜᶜᵃ[ i , j-1], λᶜᶜᵃ[ i , j-1], 1)
            c = lat_lon_to_cartesian(φᶜᶜᵃ[ i ,  j ], λᶜᶜᵃ[ i ,  j ], 1)
            d = lat_lon_to_cartesian(φᶠᶜᵃ[ i ,  j ], λᶠᶜᵃ[ i ,  j ], 1)

            Azᶠᶠᵃ[i, j] = 2 * spherical_area_quadrilateral(a, b, c, d) * radius^2
        end

        for j in 2:Nη
            i = Nξ+1
            a = lat_lon_to_cartesian(φᶜᶜᵃ[i-1, j-1], λᶜᶜᵃ[i-1, j-1], 1)
            b = lat_lon_to_cartesian(φᶠᶜᵃ[ i , j-1], λᶠᶜᵃ[ i , j-1], 1)
            c = lat_lon_to_cartesian(φᶠᶜᵃ[ i ,  j ], λᶠᶜᵃ[ i ,  j ], 1)
            d = lat_lon_to_cartesian(φᶜᶜᵃ[i-1,  j ], λᶜᶜᵃ[i-1,  j ], 1)

            Azᶠᶠᵃ[i, j] = 2 * spherical_area_quadrilateral(a, b, c, d) * radius^2
        end

        i = 1
        j = 1
        a = lat_lon_to_cartesian(φᶠᶠᵃ[i, j], λᶠᶠᵃ[i, j], 1)
        b = lat_lon_to_cartesian(φᶜᶠᵃ[i, j], λᶜᶠᵃ[i, j], 1)
        c = lat_lon_to_cartesian(φᶜᶜᵃ[i, j], λᶜᶜᵃ[i, j], 1)
        d = lat_lon_to_cartesian(φᶠᶜᵃ[i, j], λᶠᶜᵃ[i, j], 1)

        Azᶠᶠᵃ[i, j] = 4 * spherical_area_quadrilateral(a, b, c, d) * radius^2

        i = Nξ+1
        j = Nη+1
        a = lat_lon_to_cartesian(φᶜᶜᵃ[i-1, j-1], λᶜᶜᵃ[i-1, j-1], 1)
        b = lat_lon_to_cartesian(φᶠᶜᵃ[ i , j-1], λᶠᶜᵃ[ i , j-1], 1)
        c = lat_lon_to_cartesian(φᶠᶠᵃ[ i ,  j ], λᶠᶠᵃ[ i ,  j ], 1)
        d = lat_lon_to_cartesian(φᶜᶠᵃ[i-1,  j ], λᶜᶠᵃ[i-1,  j ], 1)

        Azᶠᶠᵃ[i, j] = 4 * spherical_area_quadrilateral(a, b, c, d) * radius^2

        i = Nξ+1
        j = 1
        a = lat_lon_to_cartesian(φᶜᶠᵃ[i-1, j ], λᶜᶠᵃ[i-1, j], 1)
        b = lat_lon_to_cartesian(φᶠᶠᵃ[ i , j ], λᶠᶠᵃ[ i , j], 1)
        c = lat_lon_to_cartesian(φᶠᶜᵃ[ i , j ], λᶠᶜᵃ[ i , j ], 1)
        d = lat_lon_to_cartesian(φᶜᶜᵃ[i-1, j ], λᶜᶜᵃ[i-1, j ], 1)

        Azᶠᶠᵃ[i, j] = 4 * spherical_area_quadrilateral(a, b, c, d) * radius^2

        i = 1
        j = Nη+1
        a = lat_lon_to_cartesian(φᶠᶜᵃ[ i , j-1], λᶠᶜᵃ[ i , j-1], 1)
        b = lat_lon_to_cartesian(φᶜᶜᵃ[ i , j-1], λᶜᶜᵃ[ i , j-1], 1)
        c = lat_lon_to_cartesian(φᶜᶠᵃ[ i ,  j ], λᶜᶠᵃ[ i ,  j ], 1)
        d = lat_lon_to_cartesian(φᶠᶠᵃ[ i ,  j ], λᶠᶠᵃ[ i ,  j ], 1)

        Azᶠᶠᵃ[i, j] = 4 * spherical_area_quadrilateral(a, b, c, d) * radius^2
    end

    # In all computations above we used (Bounded, Bounded, topology[3]) for ξ-η grid. This was done to ensure that we
    # had information for the faces at the boundary of the grid.
    #
    # Now we take care the coordinate and metric arrays given the `topology` prescribed.

    warnings = false

    args = topology, (Nξ, Nη, Nz), (Hx, Hy, Hz)

     λᶜᶜᵃ = add_halos(λᶜᶜᵃ,  (Center, Center, Nothing), args...; warnings)
     λᶠᶜᵃ = add_halos(λᶠᶜᵃ,  (Face,   Center, Nothing), args...; warnings)
     λᶜᶠᵃ = add_halos(λᶜᶠᵃ,  (Center, Face,   Nothing), args...; warnings)
     λᶠᶠᵃ = add_halos(λᶠᶠᵃ,  (Face,   Face,   Nothing), args...; warnings)

     φᶜᶜᵃ = add_halos(φᶜᶜᵃ,  (Center, Center, Nothing), args...; warnings)
     φᶠᶜᵃ = add_halos(φᶠᶜᵃ,  (Face,   Center, Nothing), args...; warnings)
     φᶜᶠᵃ = add_halos(φᶜᶠᵃ,  (Center, Face,   Nothing), args...; warnings)
     φᶠᶠᵃ = add_halos(φᶠᶠᵃ,  (Face,   Face,   Nothing), args...; warnings)

    Δxᶜᶜᵃ = add_halos(Δxᶜᶜᵃ, (Center, Center, Nothing), args...; warnings)
    Δxᶠᶜᵃ = add_halos(Δxᶠᶜᵃ, (Face,   Center, Nothing), args...; warnings)
    Δxᶜᶠᵃ = add_halos(Δxᶜᶠᵃ, (Center, Face,   Nothing), args...; warnings)
    Δxᶠᶠᵃ = add_halos(Δxᶠᶠᵃ, (Face,   Face,   Nothing), args...; warnings)

    Δyᶜᶜᵃ = add_halos(Δyᶜᶜᵃ, (Center, Center, Nothing), args...; warnings)
    Δyᶠᶜᵃ = add_halos(Δyᶠᶜᵃ, (Face,   Center, Nothing), args...; warnings)
    Δyᶜᶠᵃ = add_halos(Δyᶜᶠᵃ, (Center, Face,   Nothing), args...; warnings)
    Δyᶠᶠᵃ = add_halos(Δyᶠᶠᵃ, (Face,   Face,   Nothing), args...; warnings)

    Azᶜᶜᵃ = add_halos(Azᶜᶜᵃ, (Center, Center, Nothing), args...; warnings)
    Azᶠᶜᵃ = add_halos(Azᶠᶜᵃ, (Face,   Center, Nothing), args...; warnings)
    Azᶜᶠᵃ = add_halos(Azᶜᶠᵃ, (Center, Face,   Nothing), args...; warnings)
    Azᶠᶠᵃ = add_halos(Azᶠᶠᵃ, (Face,   Face,   Nothing), args...; warnings)

    coordinate_arrays = (λᶜᶜᵃ, λᶠᶜᵃ, λᶜᶠᵃ, λᶠᶠᵃ,
                         φᶜᶜᵃ, φᶠᶜᵃ, φᶜᶠᵃ, φᶠᶠᵃ,
                         zc)

    metric_arrays = (Δxᶜᶜᵃ, Δxᶠᶜᵃ, Δxᶜᶠᵃ, Δxᶠᶠᵃ,
                     Δyᶜᶜᵃ, Δyᶠᶜᵃ, Δyᶜᶠᵃ, Δyᶠᶠᵃ,
                     Azᶜᶜᵃ, Azᶠᶜᵃ, Azᶜᶠᵃ, Azᶠᶠᵃ)

    conformal_mapping = CubedSphereConformalMapping(rotation, ξᶠᵃᵃ, ηᵃᶠᵃ, ξᶜᵃᵃ, ηᵃᶜᵃ)

    # Now we can create the grid.

    grid = OrthogonalSphericalShellGrid{TX, TY, TZ}(CPU(), Nξ, Nη, Nz, Hx, Hy, Hz, Lz,
                                                    coordinate_arrays...,
                                                    metric_arrays...,
                                                    radius,
                                                    conformal_mapping)

    fill_metric_halo_regions!(grid)

    # Now convert to proper architecture.

    coordinate_arrays = (grid.λᶜᶜᵃ, grid.λᶠᶜᵃ, grid.λᶜᶠᵃ, grid.λᶠᶠᵃ,
                         grid.φᶜᶜᵃ, grid.φᶠᶜᵃ, grid.φᶜᶠᵃ, grid.φᶠᶠᵃ,
                         grid.z)

    metric_arrays = (grid.Δxᶜᶜᵃ, grid.Δxᶠᶜᵃ, grid.Δxᶜᶠᵃ, grid.Δxᶠᶠᵃ,
                     grid.Δyᶜᶜᵃ, grid.Δyᶠᶜᵃ, grid.Δyᶜᶠᵃ, grid.Δyᶠᶠᵃ,
                     grid.Azᶜᶜᵃ, grid.Azᶠᶜᵃ, grid.Azᶜᶠᵃ, grid.Azᶠᶠᵃ)

    conformal_mapping = grid.conformal_mapping

    coordinate_arrays = map(a -> on_architecture(architecture, a), coordinate_arrays)

    metric_arrays = map(a -> on_architecture(architecture, a), metric_arrays)

    conformal_mapping = on_architecture(architecture, conformal_mapping)

    grid = OrthogonalSphericalShellGrid{TX, TY, TZ}(architecture, Nξ, Nη, Nz, Hx, Hy, Hz, Lz,
                                                    coordinate_arrays...,
                                                    metric_arrays...,
                                                    radius,
                                                    conformal_mapping)

    return grid
end

#####
##### Support for simulations on conformal cubed sphere panel grids
#####

import Oceananigans.Operators: δxᶠᶜᶜ, δxᶠᶜᶠ, δyᶜᶠᶜ, δyᶜᶠᶠ

@inline δxᶠᶜᶜ(i, j, k, grid::ConformalCubedSpherePanelGridOfSomeKind, c) =
    @inbounds ifelse((i == 1) & (j < 1),               c[1, j, k]           - c[j, 1, k],
              ifelse((i == grid.Nx+1) & (j < 1),       c[grid.Nx-j+1, 1, k] - c[grid.Nx, j, k],
              ifelse((i == grid.Nx+1) & (j > grid.Ny), c[j, grid.Ny, k]     - c[grid.Nx, j, k],
              ifelse((i == 1) & (j > grid.Ny),         c[1, j, k]           - c[grid.Ny-j+1, grid.Ny, k],
                                                       c[i, j, k]           - c[i-1, j, k]))))

@inline δxᶠᶜᶠ(i, j, k, grid::ConformalCubedSpherePanelGridOfSomeKind, c) = δxᶠᶜᶜ(i, j, k, grid, c)

@inline δyᶜᶠᶜ(i, j, k, grid::ConformalCubedSpherePanelGridOfSomeKind, c) =
    @inbounds ifelse((i < 1) & (j == 1),               c[i, 1, k]           - c[1, i, k],
              ifelse((i > grid.Nx) & (j == 1),         c[i, 1, k]           - c[grid.Nx, grid.Ny+1-i, k],
              ifelse((i > grid.Nx) & (j == grid.Ny+1), c[grid.Nx, i, k]     - c[i, grid.Ny, k],
              ifelse((i < 1) & (j == grid.Ny+1),       c[1, grid.Ny-i+1, k] - c[i, grid.Ny, k],
                                                       c[i, j, k]           - c[i, j-1, k]))))

@inline δyᶜᶠᶠ(i, j, k, grid::ConformalCubedSpherePanelGridOfSomeKind, c) = δyᶜᶠᶜ(i, j, k, grid, c)

@inline δxᶠᶜᶜ(i, j, k, grid::ConformalCubedSpherePanelGridOfSomeKind, f::F, args...) where F<:Function =
    @inbounds ifelse((i == 1) & (j < 1),               f(1, j, k, grid, args...)           - f(j, 1, k, grid, args...),
              ifelse((i == grid.Nx+1) & (j < 1),       f(grid.Nx-j+1, 1, k, grid, args...) - f(grid.Nx, j, k, grid, args...),
              ifelse((i == grid.Nx+1) & (j > grid.Ny), f(j, grid.Ny, k, grid, args...)     - f(grid.Nx, j, k, grid, args...),
              ifelse((i == 1) & (j > grid.Ny),         f(1, j, k, grid, args...)           - f(grid.Nx-j+1, grid.Ny, k, grid, args...),
                                                       f(i, j, k, grid, args...)           - f(i-1, j, k, grid, args...)))))

@inline δxᶠᶜᶠ(i, j, k, grid::ConformalCubedSpherePanelGridOfSomeKind, f::F, args...) where F<:Function =
    δxᶠᶜᶜ(i, j, k, grid, f, args...)

@inline δyᶜᶠᶜ(i, j, k, grid::ConformalCubedSpherePanelGridOfSomeKind, f::F, args...) where F<:Function =
    @inbounds ifelse((i < 1) & (j == 1),               f(i, 1, k, grid, args...)           - f(1, i, k, grid, args...),
              ifelse((i > grid.Nx) & (j == 1),         f(i, 1, k, grid, args...)           - f(grid.Nx, grid.Ny+1-i, k, grid, args...),
              ifelse((i > grid.Nx) & (j == grid.Ny+1), f(grid.Nx, i, k, grid, args...)     - f(i, grid.Ny, k, grid, args...),
              ifelse((i < 1) & (j == grid.Ny+1),       f(1, grid.Ny-i+1, k, grid, args...) - f(i, grid.Ny, k, grid, args...),
                                                       f(i, j, k, grid, args...)           - f(i, j-1, k, grid, args...)))))

@inline δyᶜᶠᶠ(i, j, k, grid::ConformalCubedSpherePanelGridOfSomeKind, f::F, args...) where F<:Function =
    δyᶜᶠᶜ(i, j, k, grid, f, args...)

#####
##### Vertical circulation at the corners of the cubed sphere needs to treated in a special manner.
##### See: https://github.com/CliMA/Oceananigans.jl/issues/1584
#####

# South-west, south-east, north-west, north-east corners
@inline on_south_west_corner(i, j, grid) = (i == 1) & (j == 1)
@inline on_south_east_corner(i, j, grid) = (i == grid.Nx+1) & (j == 1)
@inline on_north_east_corner(i, j, grid) = (i == grid.Nx+1) & (j == grid.Ny+1)
@inline on_north_west_corner(i, j, grid) = (i == 1) & (j == grid.Ny+1)

import Oceananigans.Operators: Γᶠᶠᶜ

"""
    Γᶠᶠᶜ(i, j, k, grid, u, v)

The vertical circulation associated with horizontal velocities ``u`` and ``v``.
"""
@inline function Γᶠᶠᶜ(i, j, k, grid::ConformalCubedSpherePanelGridOfSomeKind, u, v)
    ip = max(2 - grid.Hx, i)
    jp = max(2 - grid.Hy, j)
    Γ = ifelse(on_south_west_corner(i, j, grid) | on_north_west_corner(i, j, grid),
               Δy_qᶜᶠᶜ(ip, jp, k, grid, v) - Δx_qᶠᶜᶜ(ip, jp, k, grid, u) + Δx_qᶠᶜᶜ(ip, jp-1, k, grid, u),
               ifelse(on_south_east_corner(i, j, grid) | on_north_east_corner(i, j, grid),
                      - Δy_qᶜᶠᶜ(ip-1, jp, k, grid, v) + Δx_qᶠᶜᶜ(ip, jp-1, k, grid, u) - Δx_qᶠᶜᶜ(ip, jp, k, grid, u),
                      δxᶠᶠᶜ(ip, jp, k, grid, Δy_qᶜᶠᶜ, v) - δyᶠᶠᶜ(ip, jp, k, grid, Δx_qᶠᶜᶜ, u)
                     )
              )
    return Γ
end
