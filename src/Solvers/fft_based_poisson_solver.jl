using Oceananigans.Fields: indices, offset_compute_index

import Oceananigans.Architectures: architecture

struct FFTBasedPoissonSolver{G, Λ, S, B, T}
            grid :: G
     eigenvalues :: Λ
         storage :: S
          buffer :: B
      transforms :: T
end

architecture(solver::FFTBasedPoissonSolver) = architecture(solver.grid)

transform_str(transform) = string(typeof(transform).name.wrapper, ", ")

function transform_list_str(transform_list)
    transform_strs = (transform_str(t) for t in transform_list)
    list = string(transform_strs...)
    list = list[1:end-2]
    return list
end

Base.summary(solver::FFTBasedPoissonSolver) = "FFTBasedPoissonSolver"

Base.show(io::IO, solver::FFTBasedPoissonSolver) =
    print(io, "FFTBasedPoissonSolver on ", string(typeof(architecture(solver))), ": \n",
              "├── grid: $(summary(solver.grid))\n",
              "├── storage: $(typeof(solver.storage))\n",
              "├── buffer: $(typeof(solver.buffer))\n",
              "└── transforms:\n",
              "    ├── forward: ", transform_list_str(solver.transforms.forward), "\n",
              "    └── backward: ", transform_list_str(solver.transforms.backward))

"""
    FFTBasedPoissonSolver(grid, planner_flag=FFTW.PATIENT)

Return an `FFTBasedPoissonSolver` that solves the "generalized" Poisson equation,

```math
(∇² + m) ϕ = b,
```

where ``m`` is a number, using a eigenfunction expansion of the discrete Poisson operator
on a staggered grid and for periodic or Neumann boundary conditions.

In-place transforms are applied to ``b``, which means ``b`` must have complex-valued
elements (typically the same type as `solver.storage`).

See [`solve!`](@ref) for more information about the FFT-based Poisson solver algorithm.
"""
function FFTBasedPoissonSolver(grid, planner_flag=FFTW.PATIENT)
    topo = (TX, TY, TZ) =  topology(grid)

    λx = poisson_eigenvalues(grid.Nx, grid.Lx, 1, TX())
    λy = poisson_eigenvalues(grid.Ny, grid.Ly, 2, TY())
    λz = poisson_eigenvalues(grid.Nz, grid.Lz, 3, TZ())

    arch = architecture(grid)

    eigenvalues = (λx = on_architecture(arch, λx),
                   λy = on_architecture(arch, λy),
                   λz = on_architecture(arch, λz))

    storage = on_architecture(arch, zeros(complex(eltype(grid)), size(grid)...))

    transforms = plan_transforms(grid, storage, planner_flag)

    # Need buffer for index permutations and transposes.
    buffer_needed = arch isa GPU && Bounded in topo
    buffer = buffer_needed ? similar(storage) : nothing

    return FFTBasedPoissonSolver(grid, eigenvalues, storage, buffer, transforms)
end

"""
    solve!(ϕ, solver::FFTBasedPoissonSolver, b, m=0)

Solve the "generalized" Poisson equation,

```math
(∇² + m) ϕ = b,
```

where ``m`` is a number, using a eigenfunction expansion of the discrete Poisson operator
on a staggered grid and for periodic or Neumann boundary conditions.

In-place transforms are applied to ``b``, which means ``b`` must have complex-valued
elements (typically the same type as `solver.storage`).

!!! info "Alternative names for 'generalized' Poisson equation"
    Equation ``(∇² + m) ϕ = b`` is sometimes referred to as the "screened Poisson" equation
    when ``m < 0``, or the Helmholtz equation when ``m > 0``.
"""
function solve!(ϕ, solver::FFTBasedPoissonSolver, b=solver.storage, m=0)
    arch = architecture(solver)
    topo = TX, TY, TZ = topology(solver.grid)
    Nx, Ny, Nz = size(solver.grid)
    λx, λy, λz = solver.eigenvalues

    # Temporarily store the solution in ϕc
    ϕc = solver.storage

    # Transform b *in-place* to eigenfunction space
    for transform! in solver.transforms.forward
        transform!(b, solver.buffer)
    end

    # Solve the discrete screened Poisson equation (∇² + m) ϕ = b.
    @. ϕc = - b / (λx + λy + λz - m)

    # If m === 0, the "zeroth mode" at `i, j, k = 1, 1, 1` is undetermined;
    # we set this to zero by default. Another slant on this "problem" is that
    # λx[1, 1, 1] + λy[1, 1, 1] + λz[1, 1, 1] = 0, which yields ϕ[1, 1, 1] = Inf or NaN.
    m === 0 && @allowscalar ϕc[1, 1, 1] = 0

    # Apply backward transforms in order
    for transform! in solver.transforms.backward
        transform!(ϕc, solver.buffer)
    end

    launch!(arch, solver.grid, :xyz, copy_real_component!, ϕ, ϕc, indices(ϕ))

    return ϕ
end

# We have to pass the offset explicitly to this kernel (we cannot use KA implicit
# index offsetting) since ϕc and ϕ and indexed with different indices
@kernel function copy_real_component!(ϕ, ϕc, index_ranges)
    i, j, k = @index(Global, NTuple)

    i′ = offset_compute_index(index_ranges[1], i)
    j′ = offset_compute_index(index_ranges[2], j)
    k′ = offset_compute_index(index_ranges[3], k)

    @inbounds ϕ[i′, j′, k′] = real(ϕc[i, j, k])
end
