using Pkg
using InteractiveUtils
using Oceananigans.Architectures

# This should be deprectated. Calls GPU() which is only
# defined when CUDA is loaded and maps to CUDAGPU()
function versioninfo_with_gpu()
    if isdefined(Main, :CUDA)
        try
            return versioninfo_with_gpu(GPU())
        catch
            return "No GPU device found."
        end
    else
        return ""
    end
end

function versioninfo_with_gpu(::CPU)
    return "No GPU device"
end

function oceananigans_versioninfo()
    project = Pkg.project()

    # If Oceananigans is listed as a dependency in a Project.toml
    # (or in the base Julia env)
    if "Oceananigans" in keys(project.dependencies)
        uuid = project.dependencies["Oceananigans"]
        pkg_info = Pkg.dependencies()[uuid]
        s = "Oceananigans v$(pkg_info.version)"
        s *= isnothing(pkg_info.git_revision) ? "" : "#$(pkg_info.git_revision)"
        return s
    end

    # If we're using the Oceananigans development environment,
    # i.e. running from the git repository. Really we should not
    # use untagged versions for real science. It's not as reproducible.
    if "Oceananigans" == project.name
        return "Oceananigans v$(project.version) (DEVELOPMENT BRANCH)"
    end

    # TODO: Get version name by parsing Project.toml via Base.find_package ?
    # @warn "Could not determine Oceananigans version info."

    return ""
end
