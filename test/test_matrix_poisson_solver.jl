include("dependencies_for_runtests.jl")

using Oceananigans.Solvers: solve!, HeptadiagonalIterativeSolver, sparse_approximate_inverse
using Oceananigans.Operators: volume, Δyᶠᶜᵃ, Δyᶜᶠᵃ, Δyᶜᶜᵃ, Δxᶠᶜᵃ, Δxᶜᶠᵃ, Δxᶜᶜᵃ, Δyᵃᶜᵃ, Δxᶜᵃᵃ, Δzᵃᵃᶠ, Δzᵃᵃᶜ, ∇²ᶜᶜᶜ

function identity_operator!(b, x)
    parent(b) .= parent(x)
    return nothing
end

function run_identity_operator_test(grid)
    N = size(grid)
    M = prod(N)

    A = zeros(grid, N...)
    D = zeros(grid, N...)
    C = zeros(grid, N...)
    fill!(C, 1)

    solver = HeptadiagonalIterativeSolver((A, A, A, C, D), grid = grid)

    b = on_architecture(architecture(grid), rand(M))

    arch = architecture(grid)
    storage = on_architecture(arch, zeros(size(b)))
    solve!(storage, solver, b, 1.0)

    @test norm(Array(storage) .- Array(b)) .< solver.tolerance
end

@kernel function _multiply_by_volume!(r, grid)
    i, j, k = @index(Global, NTuple)
    r[i, j, k] *= volume(i, j, k, grid, Center(), Center(), Center())
end

@kernel function _compute_poisson_weights(Ax, Ay, Az, grid)
    i, j, k = @index(Global, NTuple)
    Ax[i, j, k] = Δzᵃᵃᶜ(i, j, k, grid) * Δyᶠᶜᵃ(i, j, k, grid) / Δxᶠᶜᵃ(i, j, k, grid)
    Ay[i, j, k] = Δzᵃᵃᶜ(i, j, k, grid) * Δxᶜᶠᵃ(i, j, k, grid) / Δyᶜᶠᵃ(i, j, k, grid)
    Az[i, j, k] = Δxᶜᶜᵃ(i, j, k, grid) * Δyᶜᶜᵃ(i, j, k, grid) / Δzᵃᵃᶠ(i, j, k, grid)
end

function compute_poisson_weights(grid)
    N = size(grid)
    Ax = on_architecture(architecture(grid), zeros(N...))
    Ay = on_architecture(architecture(grid), zeros(N...))
    Az = on_architecture(architecture(grid), zeros(N...))
    C  = on_architecture(architecture(grid), zeros(grid, N...))
    D  = on_architecture(architecture(grid), zeros(grid, N...))

    launch!(architecture(grid), grid, :xyz, _compute_poisson_weights, Ax, Ay, Az, grid)

    return (Ax, Ay, Az, C, D)
end

poisson_rhs!(r, grid) = launch!(architecture(grid), grid, :xyz, _multiply_by_volume!, r, grid)

random_numbers(x, y=0, z=0) = rand()

function run_poisson_equation_test(grid)
    arch = architecture(grid)

    # Solve ∇²ϕ = r
    ϕ_truth = CenterField(grid)

    # Initialize zero-mean "truth" solution with random numbers
    set!(ϕ_truth, random_numbers)
    parent(ϕ_truth) .-= mean(ϕ_truth)
    fill_halo_regions!(ϕ_truth)

    # Calculate Laplacian of "truth"
    ∇²ϕ = CenterField(grid)
    compute_∇²!(∇²ϕ, ϕ_truth, arch, grid)

    rhs = deepcopy(∇²ϕ)
    poisson_rhs!(rhs, grid)
    rhs = copy(interior(rhs))
    rhs = reshape(rhs, length(rhs))
    weights = compute_poisson_weights(grid)
    solver  = HeptadiagonalIterativeSolver(weights, grid = grid, preconditioner_method = nothing)

    # Solve Poisson equation
    ϕ_solution = CenterField(grid)

    arch = architecture(grid)
    storage = on_architecture(arch, zeros(size(rhs)))
    solve!(storage, solver, rhs, 1.0)
    set!(ϕ_solution, reshape(storage, solver.problem_size...))
    fill_halo_regions!(ϕ_solution)

    # Diagnose Laplacian of solution
    ∇²ϕ_solution = CenterField(grid)
    compute_∇²!(∇²ϕ_solution, ϕ_solution, arch, grid)

    parent(ϕ_solution) .-= mean(ϕ_solution)

    @allowscalar begin
        @test all(interior(∇²ϕ_solution) .≈ interior(∇²ϕ))
        @test all(interior(ϕ_solution)   .≈ interior(ϕ_truth))
    end

    return nothing
end

@testset "HeptadiagonalIterativeSolver" begin
    topologies = [(Periodic, Periodic, Flat), (Bounded, Bounded, Flat), (Periodic, Bounded, Flat), (Bounded, Periodic, Flat)]

    for arch in archs, topo in topologies
        @info "Testing 2D HeptadiagonalIterativeSolver [$(typeof(arch)) $topo]..."

        grid = RectilinearGrid(arch, size=(4, 8), extent=(1, 3), topology = topo)
        run_identity_operator_test(grid)
        run_poisson_equation_test(grid)
    end

    topologies = [(Periodic, Periodic, Periodic), (Bounded, Bounded, Periodic), (Periodic, Bounded, Periodic), (Bounded, Periodic, Bounded)]

    for arch in archs, topo in topologies
        @info "Testing 3D HeptadiagonalIterativeSolver [$(typeof(arch)) $topo]..."

        grid = RectilinearGrid(arch, size=(4, 8, 6), extent=(1, 3, 4), topology=topo)
        run_identity_operator_test(grid)
        run_poisson_equation_test(grid)
    end

    stretched_faces = [0, 1.5, 3, 7, 8.5, 10]
    topo = (Periodic, Periodic, Periodic)
    sz = (5, 5, 5)

    for arch in archs
        grids = [RectilinearGrid(arch, size = sz, x = stretched_faces, y = (0, 10), z = (0, 10), topology = topo),
                 RectilinearGrid(arch, size = sz, x = (0, 10), y = stretched_faces, z = (0, 10), topology = topo),
                 RectilinearGrid(arch, size = sz, x = (0, 10), y = (0, 10), z = stretched_faces, topology = topo)]

        for (grid, stretched_direction) in zip(grids, [:x, :y, :z])
            @info "  Testing HeptadiagonalIterativeSolver [stretched in $stretched_direction, $(typeof(arch))]..."
            run_poisson_equation_test(grid)
        end

        if arch isa CPU
            @info "  Testing Sparse Approximate Inverse..."

            A   = sprand(10, 10, 0.1)
            A   = A + A' + 1I
            A⁻¹ = sparse(inv(Array(A)))
            M   = sparse_approximate_inverse(A, ε = eps(eltype(A)), nzrel = size(A, 1))

            @test all(Array(M) .≈ A⁻¹)
        end
    end
end
