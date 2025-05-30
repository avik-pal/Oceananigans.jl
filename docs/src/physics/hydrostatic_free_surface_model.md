# [Hydrostatic model with a free surface](@id hydrostatic_free_surface_model)

The [`HydrostaticFreeSurfaceModel`](@ref) solves the incompressible Navier-Stokes equations under
the Boussinesq and hydrostatic approximations and with an arbitrary number of tracer conservation
equations. Physics associated with individual terms in the momentum and tracer conservation
equations -- the background rotation rate of the equation's reference frame,
gravitational effects associated with buoyant tracers under the Boussinesq
approximation, generalized stresses and tracer fluxes associated with viscous and
diffusive physics, and arbitrary "forcing functions" -- are determined by the whims of the
user.

## Mass conservation and free surface evolution equation

The mass conservation equation is
```math
    0 = \boldsymbol{\nabla}_h \boldsymbol{\cdot} \boldsymbol{u} + \partial_z w \, .
```

Given the horizontal flow ``\boldsymbol{u}`` we use the above to diagnose the vertical velocity ``w``.
We integrate the mass conservation equation from the bottom of the fluid (where ``w = 0``) up to
depth ``z`` and recover ``w(x, y, z, t)``.

The free surface displacement ``\eta(x, y, t)`` satisfies the linearized kinematic boundary
condition at the surface
```math
    \partial_t \eta = w(x, y, z=0, t) \, .
```

## The momentum conservation equation

The equations governing the conservation of momentum in a rotating fluid, including buoyancy
via the Boussinesq approximation are
```math
    \begin{align}
    \partial_t \boldsymbol{u} & = - \left ( \boldsymbol{v} \boldsymbol{\cdot} \boldsymbol{\nabla} \right ) \boldsymbol{u}
                        - \boldsymbol{f} \times \boldsymbol{u}
                        - \boldsymbol{\nabla}_h (p + g \eta)
                        - \boldsymbol{\nabla} \boldsymbol{\cdot} \boldsymbol{\tau}
                        + \boldsymbol{F_u} \, , \label{eq:momentum}\\
    0 & = b - \partial_z p \, , \label{eq:hydrostatic}
    \end{align}
```
where ``b`` the is buoyancy, ``\boldsymbol{\tau}`` is the hydrostatic kinematic stress tensor,
``\boldsymbol{F_u}`` denotes an internal forcing of the horizontal flow ``\boldsymbol{u}``,
``\boldsymbol{v} = \boldsymbol{u} + w \hat{\boldsymbol{z}}`` is the three-dimensional flow,
``p`` is kinematic pressure, ``\eta`` is the free-surface displacement, and ``\boldsymbol{f}``
is the *Coriolis parameter*, or the background vorticity associated with the specified rate of
rotation of the frame of reference.

Equation \eqref{eq:hydrostatic} above is the hydrostatic approximation and comes about as the
dominant balance of terms in the Navier-Stokes vertical momentum equation under the Boussinesq
approximation.

The terms that appear on the right-hand side of the momentum conservation equation are (in order):

* momentum advection: ``\left ( \boldsymbol{v} \boldsymbol{\cdot} \boldsymbol{\nabla} \right )
  \boldsymbol{u}``,
* Coriolis: ``\boldsymbol{f} \times \boldsymbol{u}``,
* baroclinic kinematic pressure gradient: ``\boldsymbol{\nabla} p``,
* barotropic kinematic pressure gradient: ``\boldsymbol{\nabla} (g \eta)``,
* molecular or turbulence viscous stress: ``\boldsymbol{\nabla} \boldsymbol{\cdot} \boldsymbol{\tau}``, and
* an arbitrary internal source of momentum: ``\boldsymbol{F_u}``.

## The tracer conservation equation

The conservation law for tracers is
```math
    \begin{align}
    \partial_t c = - \boldsymbol{v} \boldsymbol{\cdot} \boldsymbol{\nabla} c
                   - \boldsymbol{\nabla} \boldsymbol{\cdot} \boldsymbol{q}_c
                   + F_c \, ,
    \label{eq:tracer}
    \end{align}
```
where ``\boldsymbol{q}_c`` is the diffusive flux of ``c`` and ``F_c`` is an arbitrary source term.
An arbitrary tracers are permitted and thus an arbitrary number of tracer equations
can be solved simultaneously alongside with the momentum equations.

From left to right, the terms that appear on the right-hand side of the tracer conservation
equation are

* tracer advection: ``\boldsymbol{v} \boldsymbol{\cdot} \boldsymbol{\nabla} c``,
* molecular or turbulent diffusion: ``\boldsymbol{\nabla} \boldsymbol{\cdot} \boldsymbol{q}_c``, and
* an arbitrary internal source of tracer: ``F_c``.
