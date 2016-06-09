!=====================================================================!
! Module that implements an Aero-Elastic Oscillator reported in:
! Zhao, L. and Yang, Z., ``Chaotic motions of an airfoil with
! non-linear stiffness in incompressible flow,'' Journal of Sound and
! Vibration, Vol. 138, No. 2, 1990, pp. 245–254.
! =====================================================================!

module aero_elastic_oscillator_class
  
  use iso_fortran_env , only : dp => real64
  use physics_class   , only : physics
  
  implicit none

  private

  public :: aero_elastic_oscillator

  !-------------------------------------------------------------------!
  ! Type that implements the aero-elastic oscillator (2 state vars)
  !-------------------------------------------------------------------!
  
  type, extends(physics) :: aero_elastic_oscillator

     ! Define constants and other parameters needed for residual and
     ! jacobian assembly here

     real(dp) :: Q = 8.0d0 ! reduced dynamic pressure
     
   contains

     procedure :: assembleResidual
     procedure :: assembleJacobian
     procedure :: getInitialStates
     
  end type aero_elastic_oscillator

contains
  
  !-------------------------------------------------------------------!
  ! Residual assembly at each time step. 
  ! u(1) is the plunging state of the oscillator
  ! u(2) is the pitching state of the oscillator
  ! -------------------------------------------------------------------!
  
  subroutine assembleResidual( this, res, time, u, udot, uddot )

    class(aero_elastic_oscillator) :: this
    real(8), intent(inout), dimension(:) :: res
    real(8), intent(in) :: time
    real(8), intent(in), dimension(:) :: u, udot, uddot

    res(1) = uddot(1) + 0.25d0*udot(2) + 0.1d0*udot(1) &
         & + 0.2d0*u(1) + 0.1d0*this % Q*u(2)

    res(2) = 0.25d0*uddot(1) + 0.5d0*uddot(2) + 0.1d0*udot(2) &
         & + 0.5d0*u(2) + 20.0d0*u(2)*u(2)*u(2) - 0.1d0*this % Q*u(2)

  end subroutine assembleResidual

  !-------------------------------------------------------------------!
  ! Jacobian assembly at each time step. If you don't provide the
  ! analytical jacobian, set setApproximateJacobian(.true.) into the
  ! integrator object. We use finite-difference method to approximate
  ! the Jacobian.
  !
  ! Jacobian is the matrix of partial derivatives. Each row in the
  ! Jacobian matrix arises from differntiating a single equation. Each
  ! column in the Jacobian comes from a variable in the problem. Note
  ! the NEQN should be equal to NVARS for the system to be solved.
  !
  ! Note: alpha, beta and gamma are scalars that need to be multiplied
  ! with the partial derivatives DRDQ, DRDQdot and DRDQddot
  ! respectively.
  ! -------------------------------------------------------------------!

  subroutine assembleJacobian( this, jac, alpha, beta, gamma, &
       & time, u, udot, uddot )

    class(aero_elastic_oscillator) :: this
    real(8), intent(inout), dimension(:,:) :: jac
    real(8), intent(in) :: alpha, beta, gamma
    real(8), intent(in) :: time
    real(8), intent(in), dimension(:) :: u, udot, uddot
    
    ! Zero all entries first
    jac = 0.0d0

    !-----------------------------------------------------------------!
    ! Add dR/dQ
    !-----------------------------------------------------------------!

    ! derivative of first equation
    
    jac(1,1) = jac(1,1) + alpha*0.2d0
    jac(1,2) = jac(1,2) + alpha*0.1d0 * this % Q

    ! derivative of second equation
    
    jac(2,1) = jac(2,1) + alpha*0.0d0
    jac(2,2) = jac(2,2) + alpha*(0.5d0 + 60.0d0*u(2)*u(2) - 0.1d0 * this % Q)
    
    !-----------------------------------------------------------------!
    ! Add dR/dQDOT
    !-----------------------------------------------------------------!
    
    ! derivative of first equation
    
    jac(1,1) = jac(1,1) + beta*0.10d0
    jac(1,2) = jac(1,2) + beta*0.25d0

    ! derivative of second equation

    jac(2,1) = jac(2,1) + beta*0.0d0
    jac(2,2) = jac(2,2) + beta*0.1d0

    !-----------------------------------------------------------------!
    ! Add dR/dQDDOT
    !-----------------------------------------------------------------!
    
    ! derivative of first equation
    
    jac(1,1) = jac(1,1) + gamma*1.0d0
    jac(1,2) = jac(1,2) + gamma*0.0d0

    ! derivative of second equation

    jac(2,1) = jac(2,1) + gamma*0.25d0
    jac(2,2) = jac(2,2) + gamma*0.50d0

  end subroutine assembleJacobian

  !---------------------------------------------------------------------!
  ! Sets the initial condition for use in the integator. If first order
  ! system just set initial Q, if a second order system set initial Q
  ! and udot
  !---------------------------------------------------------------------!

  subroutine getInitialStates(this, time, u, udot)

    class(aero_elastic_oscillator) :: this

    real(8), intent(in) :: time
    real(8), intent(inout), dimension(:) :: u, udot
    
    u(1) = 2.0d0
    u(2) = 1.0d0

    udot(1) = 0.2d0
    udot(2) = -0.1d0
    
  end subroutine getInitialStates
 
end Module aero_elastic_oscillator_class
