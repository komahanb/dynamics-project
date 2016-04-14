!=====================================================================!
! Module that contains common procedures for any physical system
! subject to governing equations
!
! Author: Komahan Boopathy (komahan@gatech.edu)
!=====================================================================!

module physics_class

  !-------------------------------------------------------------------!
  ! Type that models any physical phenomenon
  !-------------------------------------------------------------------!

  type, abstract :: physics

   contains

     procedure(residual_assembly_interface), deferred :: assembleResidual
     procedure(jacobian_assembly_interface), deferred :: assembleJacobian

  end type physics

  interface

     !----------------------------------------------------------------!
     ! Interface for residual assembly at each time step
     !----------------------------------------------------------------!

     subroutine residual_assembly_interface(this, res, time, u, udot, uddot)

       import physics

       class(physics) :: this
       real(8), intent(inout), dimension(:) :: res
       real(8), intent(in) :: time
       real(8), intent(in), dimension(:) :: u, udot, uddot

     end subroutine residual_assembly_interface

     !----------------------------------------------------------------!
     ! Interface for jacobian assembly at each time step
     !----------------------------------------------------------------!

     subroutine jacobian_assembly_interface(this, jac, alpha, beta, gamma, &
          & time, u, udot, uddot)

       import physics

       class(physics) :: this
       real(8), intent(inout), dimension(:,:) :: jac
       real(8), intent(in) :: alpha, beta, gamma
       real(8), intent(in) :: time
       real(8), intent(in), dimension(:) :: u, udot, uddot

     end subroutine jacobian_assembly_interface

  end interface

end module physics_class

!=====================================================================!
! Module that contains all the implementation of a rigid body 
!
! Author: Komahan Boopathy (komahan@gatech.edu)
!=====================================================================!

module rigid_body_class

  use utils, only : vector, matrix, skew, unskew, &
       & operator(*), operator(+), operator(-), &
       & norm, array, dp

  use rotation

  implicit none

  private

  public :: rigid_body

  !-------------------------------------------------------------------!
  ! Rigid body type that contains pertaining data and routines that
  ! operate over the type variables
  ! 
  ! Usage: After creating this body, be sure to call set on
  ! this body with mandatory parameters
  ! 
  ! type(rigid_body) :: bodyA
  ! .
  ! .
  ! bodyA % set(...)
  ! -------------------------------------------------------------------!

  type :: rigid_body

     !----------------------------------------------------------------!
     ! Position state variables (all in body frame when stored)
     !----------------------------------------------------------------!

     type(vector) :: r              
     type(vector) :: theta          
     type(vector) :: v              
     type(vector) :: omega          

     !----------------------------------------------------------------!
     ! Velocity state variables (all in body frame when stored)
     !----------------------------------------------------------------!

     type(vector) :: rdot
     type(vector) :: thetadot
     type(vector) :: vdot
     type(vector) :: omegadot

     !----------------------------------------------------------------!
     ! Inertial Properties (all in body frame when stored)
     !----------------------------------------------------------------!
     ! First moment of mass
     ! C = [ cx,  cy,  cz ]
     !----------------------------------------------------------------!
     ! Second moment of mass
     ! J = [ Jxx,  Jxy,  Jxz ] = [ J[0],  J[1],  J[2] ]
     ! . = [    ,  Jyy,  Jyz ] = [     ,  J[3],  J[4] ]
     ! . = [    ,     ,  Jzz ] = [     ,      ,  J[5] ]
     !----------------------------------------------------------------!

     real(dp)     :: mass    ! mass of the body
     type(vector) :: c       ! first moment of inertia
     type(matrix) :: J       ! second moment of inertia

     !----------------------------------------------------------------!
     ! Rotation matrices (rotates from body to inertial frame)
     !----------------------------------------------------------------!

     type(matrix) :: TIB, TIBdot ! Transformation matrix and its derivatives
     type(matrix) :: S, SDOT     ! angular velocity matrix and its derivative

     !----------------------------------------------------------------!
     ! Handy force and torque vectors
     !----------------------------------------------------------------!

     !     type(vector) :: rforce   ! external/reaction force
     !     type(vector) :: rtorque  ! external/reaction torque
     type(vector) :: grav     ! gravity vector in local frame

     !----------------------------------------------------------------!
     ! Used for energy conservation check
     !----------------------------------------------------------------!

     real(dp) :: KE          ! kinetic energy of the body
     real(dp) :: PE          ! potential energy of the body
     real(dp) :: TE          ! total energy of the body

   contains

     procedure :: set
     procedure :: update
     procedure :: get_residual 
     procedure :: get_jacobian

  end type rigid_body

contains

  !-------------------------------------------------------------------!
  ! Routine to set the states into the body and compute rotation
  ! matrices for the set state. This function is to be called during
  ! initialization or the first time step
  ! -------------------------------------------------------------------!

  subroutine set(body, mass, q, qdot, qddot)

    class(rigid_body)    :: body
    real(dp), intent(in) :: mass
    real(dp), intent(in) :: q(12), qdot(12), qddot(12)

    ! Set the rotation parameters
    body % theta    = vector(q(4:6))

    ! Set inertial properties
    body % mass     = mass
    body % c % x    = 0.0d0       ! Assuming body frame is located at CG
    body % J % PSI  = mass/6.0d0 ! Assuming atleast two planes of symmetry and a cube side = 1

    ! Set the gravity in global frame (this is converted to body frame
    ! during residual and jacobian assembly)
    body % grav % x(3) = -9.81d0

    ! Get rotation and angular rate matrices based on theta    
    body % TIB     = get_rotation(body % theta)
    body % S       = get_angrate(body % theta)
    body % SDOT    = get_angrate_dot(body % theta, body % thetadot)

    ! Set the state into the body
    body % r        = body % TIB*vector(q(1:3))   ! convert to body frame
    body % v        = body % TIB*vector(q(7:9))   ! convert to body frame
    body % omega    = body % TIB*vector(q(10:12)) ! convert to body frame

    ! Set the time derivatives of state into the body
    body % rdot     = vector(qdot(1:3)) 
    body % thetadot = vector(qdot(4:6))
    body % vdot     = vector(qdot(7:9))
    body % omegadot = vector(qdot(10:12))

  end subroutine set

  !-------------------------------------------------------------------!
  ! Routine to update the states into the body and compute rotation
  ! matrices for the new state. This function is to be called during
  ! during subsequent time steps
  !-------------------------------------------------------------------!

  subroutine update(body, q, qdot, qddot)

    class(rigid_body)    :: body
    real(dp), intent(in) :: q(12), qdot(12), qddot(12)

    body % theta    = vector(q(4:6))

    ! Get rotation and angular rate matrices based on theta    
    body % TIB     = get_rotation(body % theta)
    body % S       = get_angrate(body % theta)
    body % SDOT    = get_angrate_dot(body % theta, body % thetadot)

    ! Set the state into the body
    body % r        = vector(q(1:3))
    body % v        = vector(q(7:9))
    body % omega    = vector(q(10:12))

    ! Set the time derivatives of state into the body
    body % rdot     = vector(qdot(1:3))
    body % thetadot = vector(qdot(4:6))
    body % vdot     = vector(qdot(7:9))
    body % omegadot = vector(qdot(10:12))

  end subroutine update

  !-------------------------------------------------------------------!
  ! Residual of the kinematic and dynamic equations in state-space
  ! representation. The vector form of the residual 'R' can be
  ! converted into scalar form of 12 equations just by using
  ! 'array(R)'
  !-------------------------------------------------------------------!

  function get_residual(body) result(R)

    class(rigid_body) :: body
    type(vector) :: R(4)

    !-----------------------------------------------------------------!
    ! Translational Kinematics
    !-----------------------------------------------------------------!
    ! [T] r_dot - v = 0
    !-----------------------------------------------------------------!

    !! May have to transform things into a frame
    R(1)  = body % TIB * body % rdot - body % v

    !-----------------------------------------------------------------!
    ! Rotational Kinematics
    !-----------------------------------------------------------------!
    ! [S] theta_dot - omega = 0
    !-----------------------------------------------------------------!

    !! May have to transform things into a frame
    R(2)  = body % S*body % thetadot - body % omega

    !-----------------------------------------------------------------!
    ! Translational Dynamics (8 terms) (Force Equation)
    !-----------------------------------------------------------------!
    ! m (vdot - TIB*g) - c x omegadot + omega x (m v - c x omega) - fr = 0
    !-----------------------------------------------------------------!

    !! May have to transform things into a frame
    R(3)  =  body % mass*(body % vdot - body % TIB * body % grav) &
         & - skew(body % c)*body % omegadot &
         & + skew(body % omega)*(body % mass * body % v - skew(body % c)*body % omega) !&
    !& - body % rforce

    !-----------------------------------------------------------------!
    ! Rotational Dynamics (9-terms) (Moment Equation)
    !-----------------------------------------------------------------!
    ! c x vdot + J omegadot  + c x omega x v + omega x J - c x TIB*g - gr = 0
    !-----------------------------------------------------------------!

    !! May have to transform things into a frame
    R(4)  = skew(body % c) * body % vdot &
         & + body % J * body % omegadot &
         & + skew(body % c) * skew(body % omega)*body % v &
         & + skew(body % omega) * body % J * body % omega &
         & - skew(body % c) * body % TIB * body % grav !&
    !& - body % rtorque

  end function get_residual

  !-------------------------------------------------------------------!
  ! Jacobian of the kinematic and dynamic equations in state-space
  ! representation
  !-------------------------------------------------------------------!

  subroutine get_jacobian(this)

    class(rigid_body) :: this

  end subroutine get_jacobian

end module rigid_body_class

!=====================================================================!
! Module that contains all the implementation of rigid body dynamics
! related physics. 
!
! Author: Komahan Boopathy (komahan@gatech.edu)
!=====================================================================!

module rigid_body_dynamics_class

  use physics_class
  use rigid_body_class

  implicit none

  private

  public :: rigid_body_dynamics
  
  !-------------------------------------------------------------------!
  ! Type that models rigid body dynamics
  !-------------------------------------------------------------------!
  
  type, extends(physics) :: rigid_body_dynamics
     
     type(rigid_body) :: body
     
   contains
     
     procedure :: assembleResidual
     procedure :: assembleJacobian

  end type rigid_body_dynamics
  
contains

  !-------------------------------------------------------------------!
  ! Residual assembly at each time step
  !-------------------------------------------------------------------!

  subroutine assembleResidual(this, res, time, u, udot, uddot)

    class(rigid_body_dynamics) :: this

    real(8), intent(inout), dimension(:) :: res
    real(8), intent(in) :: time
    real(8), intent(in), dimension(:) :: u, udot, uddot

    print*, "DUMMY residual"

  end subroutine assembleResidual

  !-------------------------------------------------------------------!
  ! Jacobian assembly at each time step
  !-------------------------------------------------------------------!

  subroutine assembleJacobian(this, jac, alpha, beta, gamma, &
       & time, u, udot, uddot)

    class(rigid_body_dynamics) :: this
    real(8), intent(inout), dimension(:,:) :: jac
    real(8), intent(in) :: alpha, beta, gamma
    real(8), intent(in) :: time
    real(8), intent(in), dimension(:) :: u, udot, uddot

    print*, "DUMMY jacobian"

  end subroutine assembleJacobian

end module rigid_body_dynamics_class
