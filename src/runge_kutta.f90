!=====================================================================!
! A Diagonally Implicit Runge Kutta integrator module for first and
! second order systems.
!
! Author: Komahan Boopathy (komahan@gatech.edu)
!=====================================================================!

module runge_kutta_integrator

  use iso_fortran_env , only : dp => real64
  use integrator_class, only : integrator
  use physics_class,    only : physics

  implicit none

  private
  public :: DIRK

  !===================================================================! 
  ! Abstract Runge-Kutta type
  !===================================================================! 

  type, abstract, extends(integrator) :: RK

     integer :: num_stages = 1 ! default number of stages
     integer :: order = 2      ! order of accuracy, only for informatory purposes
     integer :: current_stage = 0

     !----------------------------------------------------------------!
     ! The Butcher Tableau 
     !----------------------------------------------------------------!

     real(dp), dimension(:,:), allocatable :: A ! forms the coeff matrix
     real(dp), dimension(:), allocatable   :: B ! multiplies the state derivatives
     real(dp), dimension(:), allocatable   :: C ! multiplies the time

     !----------------------------------------------------------------!
     ! The stage time and its corresponding derivatives
     !----------------------------------------------------------------!

     real(dp), dimension(:), allocatable     :: T
     real(dp), dimension(:,:,:), allocatable :: Q
     real(dp), dimension(:,:,:), allocatable :: QDOT
     real(dp), dimension(:,:,:), allocatable :: QDDOT

     !----------------------------------------------------------------!
     ! The lagrange multipliers
     !----------------------------------------------------------------!
     
     real(dp), dimension(:,:,:), allocatable   :: psi

   contains

     !----------------------------------------------------------------!
     ! Implemented common procedures (visible to the user)
     !----------------------------------------------------------------!

     procedure :: finalize, integrate

     !----------------------------------------------------------------!
     ! Implemented procedures (not callable by the user)
     !----------------------------------------------------------------!

     procedure, private :: TimeMarch
     procedure, private :: CheckButcherTableau

     !----------------------------------------------------------------!
     ! Deferred common procedures
     !----------------------------------------------------------------!

     procedure(computeStageStateValues_interface), private, deferred :: ComputeStageStateValues
     procedure(buthcher_interface), private, deferred                :: SetupButcherTableau

  end type RK

  !-------------------------------------------------------------------!  
  ! Diagonally implicit Runge-Kutta
  !-------------------------------------------------------------------!  

  type, extends(RK) :: DIRK

   contains

     private

     procedure :: setupButcherTableau => ButcherDIRK
     procedure :: computeStageStateValues

     !----------------------------------------------------------------!
     ! Adjoint procedures
     !----------------------------------------------------------------!
     procedure, public  :: marchBackwards
     procedure, private :: assembleRHS
     procedure, private :: computeTotalDerivative

     procedure, public  :: evalFunc

  end type DIRK

  !===================================================================!
  ! Interfaces for deferred specialized procedures 
  !===================================================================!

  interface

     !================================================================!
     ! Interface for finding the stage derivatives at each time step
     !================================================================!

     subroutine computeStageStateValues_interface(this, q, qdot)
       use iso_fortran_env , only : dp => real64
       import RK
       class(RK) :: this
       real(dp), intent(in), dimension(:,:)           :: q
       real(dp), OPTIONAL, intent(in), dimension(:,:) :: qdot
     end subroutine computeStageStateValues_interface

     !================================================================!
     ! Interface for setting the Butcher tableau for each type of RK
     ! scheme
     !================================================================!

     subroutine buthcher_interface(this)
       use iso_fortran_env , only : dp => real64
       import RK
       class(RK) :: this
     end subroutine buthcher_interface

  end interface
  
  interface DIRK
     module procedure initialize
  end interface DIRK

contains

  !===================================================================!
  ! Initialize the dirk datatype and construct the tableau
  !===================================================================!
  
  type(DIRK) function initialize( system, tinit, tfinal, h, second_order, num_stages ) result(this)
    
    class(physics), target :: system
    integer  , OPTIONAL, intent(in) :: num_stages
    real(dp) , OPTIONAL, intent(in) :: tinit, tfinal
    real(dp) , OPTIONAL, intent(in) :: h
    logical  , OPTIONAL, intent(in) :: second_order

    print *, "======================================"
    print *, ">> Diagonally-Implicit-Runge-Kutta  <<"
    print *, "======================================"

    !-----------------------------------------------------------------!
    ! Set the physical system in to the integrator                    !
    !-----------------------------------------------------------------!
    
    call this % setPhysicalSystem(system)

    !-----------------------------------------------------------------!
    ! Fetch the number of state variables from the system object
    !-----------------------------------------------------------------!
    this % nsvars = system % getNumStateVars()
    print '("  >> Number of variables    : ",i4)', this % nsvars

    if ( .not. (this % nsvars .gt. 0) ) then
       stop ">> Error: Zero state variable. Stopping."
    end if

    !-----------------------------------------------------------------!
    ! Set the order of the governing equations
    !-----------------------------------------------------------------!
    
    if (present(second_order)) then
       this % second_order = second_order
    end if
    print '("  >> Second order           : ",L1)', this % second_order

    !-----------------------------------------------------------------!
    ! Set the initial and final time
    !-----------------------------------------------------------------!

    if (present(tinit)) then
       this % tinit = tinit
    end if
    print '("  >> Start time             : ",F8.3)', this % tinit

    if (present(tfinal)) then
       this % tfinal = tfinal
    end if
    print '("  >> End time               : ",F8.3)', this % tfinal

    !-----------------------------------------------------------------!
    ! Set the order of integration
    !-----------------------------------------------------------------!

    if (present(num_stages)) then
       this % num_stages = num_stages
    end if
    print '("  >> Number of stages       : ",i4)', this % num_stages

    !-----------------------------------------------------------------!
    ! Set the user supplied initial step size
    !-----------------------------------------------------------------!

    if (present(h)) then
       this % h = h 
    end if
    print '("  >> Step size              : ",E9.3)', this % h

    !-----------------------------------------------------------------!
    ! Find the number of time steps required during integration
    !-----------------------------------------------------------------!

    this % num_steps = int((this % tfinal - this % tinit)/this % h) + 1 
    print '("  >> Number of steps        : ",i6)', this % num_steps
    
    !-----------------------------------------------------------------!
    ! Allocate space for the tableau
    !-----------------------------------------------------------------!

    allocate(this % A(this % num_stages, this % num_stages))
    this % A = 0.0d0

    allocate(this % B(this % num_stages))    
    this % B = 0.0d0

    allocate(this % C(this % num_stages))
    this % C = 0.0d0

    !-----------------------------------------------------------------!
    ! Allocate space for the stage states and time
    !-----------------------------------------------------------------!

    allocate(this % T(this % num_stages))
    this % T = 0.0d0

    allocate(this % Q(this % num_steps, this % num_stages, this % nsvars))
    this % Q = 0.0d0

    allocate(this % QDOT(this % num_steps, this % num_stages, this % nsvars))
    this % QDOT = 0.0d0

    allocate(this % QDDOT(this % num_steps, this % num_stages, this % nsvars))
    this % QDDOT = 0.0d0

    !-----------------------------------------------------------------!
    ! Allocate space for the lagrange multipliers
    !-----------------------------------------------------------------!
    
    allocate(this % psi(this % num_steps, this % num_stages, this % nsvars))
    this % psi = 0.0d0

    !-----------------------------------------------------------------!
    ! Allocate space for the global states and time
    !-----------------------------------------------------------------!

    allocate(this % time(this % num_steps))
    this % time = 0.0d0

    allocate(this % U(this % num_steps, this % nsvars))
    this % U = 0.0d0

    allocate(this % uDOT(this % num_steps, this % nsvars))
    this % UDOT = 0.0d0

    allocate(this % UDDOT(this % num_steps, this % nsvars))
    this % UDDOT = 0.0d0

    !-----------------------------------------------------------------!
    ! Put values into the Butcher tableau
    !-----------------------------------------------------------------!

    call this % setupButcherTableau()

    !-----------------------------------------------------------------!
    ! Sanity check for consistency of Butcher Tableau
    !-----------------------------------------------------------------!

    call this % checkButcherTableau()

    ! set the start time
    this % time(1) = this % tinit

  end function initialize

  !===================================================================!
  ! Routine that checks if the Butcher Tableau entries are valid for
  ! the chosen number of stages/order
  !===================================================================!

  subroutine checkButcherTableau(this)

    class(RK) :: this
    integer :: i

    do i = 1, this  % num_stages
       if (abs(this % C(i) - sum(this % A(i,:))) .gt. 5.0d-16) then
          print *, "WARNING: sum(A(i,j)) != C(i)", i, this % num_stages
       end if
    end do

    if ((sum(this % B) - 1.0d0) .gt. 5.0d-16) then
       print *, "WARNING: sum(B) != 1", this % num_stages
    end if

  end subroutine checkButcherTableau

  !===================================================================!
  ! Deallocate the allocated variables
  !===================================================================!

  subroutine finalize(this)

    class(RK) :: this

    ! Clear butcher's tableau
    if(allocated(this % A)) deallocate(this % A)
    if(allocated(this % B)) deallocate(this % B)
    if(allocated(this % C)) deallocate(this % C)

    ! Clear stage value
    if(allocated(this % QDDOT)) deallocate(this % QDDOT)
    if(allocated(this % QDOT)) deallocate(this % QDOT)
    if(allocated(this % Q)) deallocate(this % Q)
    if(allocated(this % T)) deallocate(this % T)

    ! Clear global states and time
    if(allocated(this % UDDOT)) deallocate(this % UDDOT)
    if(allocated(this % UDOT)) deallocate(this % UDOT)
    if(allocated(this % U)) deallocate(this % U)
    if(allocated(this % time)) deallocate(this % time)

    if(allocated(this % psi)) deallocate(this % psi)

  end subroutine finalize

  !===================================================================!
  ! Time integration logic
  !===================================================================!

  subroutine Integrate(this)

    class(RK) :: this
    integer :: k

    ! Set states to zero

    this % U     = 0.0d0
    this % UDOT  = 0.0d0
    this % UDDOT = 0.0d0
    this % time  = 0.0d0

    this % Q     = 0.0d0
    this % QDOT  = 0.0d0
    this % QDDOT = 0.0d0
    this % T     = 0.0d0

    call this % system % getInitialStates(this % time(1), &
         & this % u(1,:), this % udot(1,:))
    
    this % current_step = 1

    ! March in time
    time: do k = 2, this % num_steps

       this % current_step = k

       ! Find the stage derivatives at the current step
       call this % computeStageStateValues(this % u, this % udot)

       ! Advance the state to the current step
       call this % timeMarch(this % u, this % udot, this % uddot)
       
    end do time

  end subroutine Integrate
  
  !===================================================================!
  ! Time backwards in stage and backwards in time to solve for the
  ! adjoint variables
  !===================================================================!
  
  subroutine marchBackwards(this)

    class(DIRK) :: this
    integer     :: k, i
    real(dp)    :: alpha, beta, gamma

    time: do k = this % num_steps, 2, -1
       
       this % current_step = k
       
       stage: do i = this % num_stages, 1, -1

          this % current_stage = i
          
          !--------------------------------------------------------------!
          ! Determine the linearization coefficients for the Jacobian
          !--------------------------------------------------------------!
          
          if (this % second_order) then
             gamma = this % B(i) / this % h / this % h
             beta  = this % B(i) * this % A(i,i) / this % h
             alpha = this % B(i) * this % A(i,i) * this % A(i,i) 
          else
             gamma = 0
             beta  = this % B(i) / this % h
             alpha = this % B(i) * this % A(i,i)
          end if
          
          !--------------------------------------------------------------!
          ! Solve the adjoint equation at each step
          !--------------------------------------------------------------!

          call this % adjointSolve(this % psi(k,i,:), alpha, beta, gamma, &
               & this % T(i), this % Q(k,i,:), this % QDOT(k,i,:), this % QDDOT(k,i,:))
          
!          print *, "psi=", k, i, this % psi(k,i,:)

       end do stage

    end do time
    
  end subroutine marchBackwards

  !===================================================================!
  ! Update the states based on RK Formulae
  !===================================================================!

  subroutine timeMarch(this, q, qdot, qddot)

    implicit none

    class(RK) :: this
    real(dp),  dimension(:,:) :: q, qdot, qddot ! current state
    integer :: m, k

    ! Store the current time step
    k = this % current_step

    ! Increment the time
    this % time(k) = this % time(k-1) + this % h

    ! March q to next time step
    forall(m=1:this%nsvars)
       q(k,m) = q(k-1,m) + this % h*sum(this % B(1:this%num_stages) &
            &* this % QDOT(k, 1:this%num_stages, m))
    end forall

    if (this % second_order) then

       ! March qdot
       forall(m=1:this%nsvars)
          qdot(k,m) = qdot(k-1,m) + this % h*sum(this % B(1:this%num_stages) &
               &* this % QDDOT(k, 1:this%num_stages, m))
       end forall

       ! March qddot
       forall(m=1:this%nsvars)
          qddot(k,m) = sum(this % B(1:this%num_stages) &
               &* this % QDDOT(k,1:this%num_stages,m))
       end forall

    else

       ! March qdot
       forall(m=1:this%nsvars)
          qdot(k,m) = sum(this % B(1:this%num_stages) &
               & * this % QDOT(k,1:this%num_stages,m))
       end forall

    end if

  end subroutine timeMarch

  !===================================================================!
  ! Butcher's tableau for DIRK 
  !===================================================================!

  subroutine ButcherDIRK(this)

    class(DIRK) :: this
    real(dp), parameter :: PI = 22.0d0/7.0d0
    real(dp), parameter :: tmp  = 1.0d0/(2.0d0*dsqrt(3.0d0))
    real(dp), parameter :: half = 1.0d0/2.0d0
    real(dp), parameter :: one  = 1.0d0
    real(dp), parameter :: alpha = 2.0d0*cos(PI/18.0d0)/dsqrt(3.0d0)

    ! Put the entries into the tableau (ROGER ALEXANDER 1977)
    if (this % num_stages .eq. 1) then 

       ! Implicit mid-point rule (A-stable)

       this % A(1,1)    = half
       this % B(1)      = one
       this % C(1)      = half

       this % order     = 2

!!$       ! Implicit Euler (Backward Euler) but first order accurate
!!$       this % A(1,1) = one
!!$       this % B(1)   = one
!!$       this % C(1)   = one
!!$       this % order  = 1


    else if (this % num_stages .eq. 2) then

       ! Crouzeix formula (A-stable)

       this % A(1,1)    = half + tmp
       this % A(2,1)    = -one/dsqrt(3.0d0)
       this % A(2,2)    = this % A(1,1)

       this % B(1)      = half
       this % B(2)      = half

       this % C(1)      = half + tmp
       this % C(2)      = half - tmp

       this % order     = 3

    else if (this % num_stages .eq. 3) then

       ! Crouzeix formula (A-stable)

       this % A(1,1)    = (one+alpha)*half
       this % A(2,1)    = -half*alpha
       this % A(3,1)    =  one + alpha

       this % A(2,2)    = this % A(1,1)
       this % A(3,2)    = -(one + 2.0d0*alpha)
       this % A(3,3)    = this % A(1,1)

       this % B(1)      = one/(6.0d0*alpha*alpha)
       this % B(2)      = one - one/(3.0d0*alpha*alpha)
       this % B(3)      = this % B(1)

       this % C(1)      = (one + alpha)*half
       this % C(2)      = half
       this % C(3)      = (one - alpha)*half

       this % order     = 4

    else if (this % num_stages .eq. 4) then

       stop "Four stage DIRK formula does not exist"

    else
       
       print *, this % num_stages
       stop "DIRK Butcher tableau is not implemented for the requested&
            & order/stages"

    end if

  end subroutine ButcherDIRK

  !===================================================================!
  ! Get the stage derivative array for the current step and states for
  ! DIRK
  !===================================================================!

  subroutine computeStageStateValues( this, q, qdot )

    class(DIRK)                                    :: this
    real(dp), intent(in), dimension(:,:)           :: q
    real(dp), OPTIONAL, intent(in), dimension(:,:) :: qdot
    integer                                        :: k, j, m
    real(dp)                                       :: alpha, beta, gamma

    k = this % current_step

    do j = 1, this % num_stages

       this % current_stage = j

       ! Find the stage times
       this % T(j) = this % time(k-1) + this % C(j)*this % h

       ! Guess the solution for stage states

       if (this % second_order) then
          
          ! guess qddot
          if (k .eq. 2) then ! initialize with a starting value
             this % QDDOT(k,j,:) = 1.0d0
          else 
             if (j .eq. 1) then ! copy previous global state
                this % QDDOT(k,j,:) = this % UDDOT(k-1,:)
             else ! copy previous local state
                this % QDDOT(k,j,:) = this % QDDOT(k,j-1,:)
             end if
          end if

          ! compute the stage velocities for the guessed QDDOT
          forall(m = 1 : this % nsvars)
             this % QDOT(k,j,m) = qdot(k-1,m) &
                  & + this % h*sum(this % A(j,:)&
                  & * this % QDDOT(k,:, m))
          end forall

          ! compute the stage states for the guessed QDDOT
          forall(m = 1 : this % nsvars)
             this % Q(k,j,m) = q(k-1,m) &
                  & + this % h*sum(this % A(j,:)*this % QDOT(k,:, m))
          end forall

       else

          ! guess qdot
          if (k .eq. 2) then ! initialize with a starting value
             this % QDOT(k,j,:) = 1.0d0
          else 
             if (j .eq. 1) then ! copy previous global state
                this % QDOT(k,j,:) = this % UDOT(k-1,:)
             else ! copy previous local state
                this % QDOT(k,j,:) = this % QDOT(k,j-1,:)
             end if
          end if

          ! compute the stage states for the guessed 
          forall(m = 1 : this % nsvars)
             this % Q(k,j,m) = q(k-1,m) &
                  & + this % h*sum(this % A(j,:)*this % QDOT(k,:, m))
          end forall

       end if
       
       ! solve the non linear stage equations using Newton's method for
       ! the actual stage states 
       if (this % second_order) then
          gamma = 1.0d0
          beta  = this % h * this%A(j,j)
          alpha = this % h * this%A(j,j)* this % h * this%A(j,j)
       else
          gamma = 0.0d0
          beta  = 1.0d0
          alpha = this % h * this%A(j,j)
       end if

       call this % newtonSolve(alpha, beta, gamma, &
            & this % time(k), this % q(k,j,:), this % qdot(k,j,:), this % qddot(k,j,:))
       
    end do

  end subroutine computeStageStateValues
 
  !===================================================================!
  ! Function that puts together the right hand side of the adjoint
  ! equation into the supplied rhs vector.
  !===================================================================!

  subroutine assembleRHS(this, rhs)
 
    class(DIRK)                           :: this
    real(dp), dimension(:), intent(inout) :: rhs
    real(dp)                              :: scale1=0.0d0, scale2=0.0d0
    real(dp), dimension(:,:), allocatable :: jac1, jac2
    integer :: k, j, i, p, s

    k = this % current_step
    i = this % current_stage
    s = this % num_stages

    allocate( jac1(this % nSVars, this % nSVars)  )
    allocate( jac2(this % nSVars, this % nSVars) )

    rhs = 0.0d0
    
    !-----------------------------------------------------------------!
    ! Add all the residual contributions first
    !-----------------------------------------------------------------!

    current_r: do j = i + 1, s

       scale1 = this % B(j) * this % A(j,i) / this % h
       call this % system % assembleJacobian(jac1, 0.0d0, scale1, 0.0d0, &
            & this % T(j), this % Q(k,j,:), this % QDOT(k,j,:), this % QDDOT(k,j,:))

       scale2 = 0.0d0
       do p = i, j
          scale2 = scale2 + this % B(j) * this % A(j,i) * this % A(p,i)
       end do
       call this % system % assembleJacobian(jac2,  scale2, 0.0d0, 0.0d0, &
            & this % T(j), this % Q(k,j,:), this % QDOT(k,j,:), this % QDDOT(k,j,:))

       rhs = rhs + matmul( transpose(jac1+jac2), this % psi(k,j,:) )
       
    end do current_r

    
    if ( k+1 .le. this % num_steps ) then 

       future_r: do j = i , s

          scale1 = this % B(j) * this % B(i) / this % h

          call this % system % assembleJacobian(jac1, 0.0d0, scale1, 0.0d0, &
               & this % T(j), this % Q(k+1,j,:), this % QDOT(k+1,j,:), this % QDDOT(k+1,j,:))

          scale2 = 0.0d0
          do p = i , s
             scale2 = scale2 + this % A(p,i) * this % B(p)
          end do
          do p = 1 , j
             scale2 = scale2 + this % B(i) * this % A(j,p)
          end do

          scale2 = scale2 * this % B(j) 

          call this % system % assembleJacobian(jac2, scale2, 0.0d0, 0.0d0, &
               & this % T(j), this % Q(k+1,j,:), this % QDOT(k+1,j,:), this % QDDOT(k+1,j,:))

          rhs = rhs + matmul( transpose(jac1+jac2), this % psi(k+1,j,:) )

       end do future_r

    end if

    !-----------------------------------------------------------------!
    ! Now add function contributions
    !-----------------------------------------------------------------!
    
    ! Add contribution from second derivative of state
    
    scale1 = this % B(i)/ this % h / this % h

    call this % system % func % addDFdUDDot(rhs, scale1, this % T(i), &
         & this % system % x, this % Q(k,i,:), this % qdot(k,i,:), this % qddot(k,i,:))
    
    current_f: do j = i, s

       scale1 = this % B(j) * this % A(j,i) / this % h
       call this % system % func % addDFdUDot(rhs, scale1, this % T(j), &
            & this % system % x, this % Q(k,j,:), this % qdot(k,j,:), this % qddot(k,j,:))
       
       scale2 = 0.0d0
       do p = i, j
          scale2 = scale2 + this % B(j) * this % A(j,i) * this % A(p,i)
       end do
       call this % system % func % addDFdU(rhs,  scale2, this % T(j), &
            & this % system % x, this % Q(k,j,:), this % Qdot(k,j,:), this % Qddot(k,j,:))

    end do current_f

    if ( k+1 .le. this % num_steps ) then 

       future_f: do j = i , s

          scale1 = this % B(j) * this % B(i) / this % h
          call this % system % func % addDFdUDot(rhs, scale1, this % T(j), &
               & this % system % x, this % Q(k+1,j,:), this % qdot(k+1,j,:), this % qddot(k+1,j,:))
          
          scale2 = 0.0d0
          do p = i , s
             scale2 = scale2 + this % A(p,i) * this % B(p)
          end do
          do p = 1 , j
             scale2 = scale2 + this % B(i) * this % A(j,p)
          end do

          scale2 = scale2 * this % B(j)
          call this % system % func % addDFdU(rhs, scale2, this % T(j), &
               & this % system % x, this % Q(k+1,j,:), this % Qdot(k+1,j,:), this % Qddot(k+1,j,:))

       end do future_f

    end if    

    rhs = -rhs

    if(allocated(jac1)) deallocate(jac1)
    if(allocated(jac2)) deallocate(jac2)

  end subroutine assembleRHS

  !===================================================================!
  ! Compute the total derivative of the function with respect to the
  ! design variables and return the gradient 
  !===================================================================!
  
  subroutine computeTotalDerivative( this, dfdx )

    class(DIRK)                              :: this
    real(dp) , dimension(:), intent(inout)   :: dfdx
    real(dp) , dimension(:,:), allocatable   :: dRdX
    integer                                  :: k, j

    allocate(dRdX(this % nSVars, this % nDVars))

    dfdx = 0.0d0

    !-----------------------------------------------------------------!
    ! Compute dfdx
    !-----------------------------------------------------------------!

    ! always use scale
    do k = 2, this % num_steps
       do j = 1, this % num_stages
          call this % system % func % addDFDX(dfdx, this % h * this % B(j),&
               &  this % T(j),  &
               & this % system % x, this % Q(k,j,:), this % QDOT(k,j,:), &
               & this % QDDOT(k,j,:) )
       end do
    end do

    !-----------------------------------------------------------------!
    ! Compute the total derivative
    !-----------------------------------------------------------------!

    do k = 2, this % num_steps
       do j = 1, this % num_stages
          call this % system % getResidualDVSens(dRdX, 1.0d0, this % T(j), &
               & this % system % x, this % Q(k,j,:), this % QDOT(k,j,:), this % QDDOT(k,j,:))
!          print*, this % B(j),drdx, this % psi (k,j,:)
          dfdx = dfdx + this % h * this % B(j)* matmul(this % psi(k,j,:), dRdX) ! check order
       end do
    end do

    !-----------------------------------------------------------------!
    ! Special logic for initial condition (use the adjoint variable
    ! for the second time step)
    !-----------------------------------------------------------------!

!!$    call this % system % func % addDfdx(dfdx, 1.0d0, this % time(1), &
!!$         & this % system % x, this % u(1,:), this % udot(1,:), this % uddot(2,:) )
!!$    
!!$    call this % system % getResidualDVSens(dRdX, 1.0d0, this % time(1), &
!!$         & this % system % x, this % u(1,:), this % udot(1,:), this % uddot(2,:))
!!$    dfdx = dfdx + matmul(this % psi(2,:), dRdX)

    deallocate(dRdX)

  end subroutine computeTotalDerivative

  !===================================================================!
  ! Evaluating the function of interest
  !===================================================================!
  
  subroutine evalFunc(this, x, fval)
    
    class(DIRK)                        :: this
    real(dp), dimension(:), intent(in) :: x
    real(dp), intent(inout)            :: fval
    integer                            :: k,j
    real(dp)                           :: ftmp
    
    fval =0.0d0

    do concurrent(k = 2 : this % num_steps)
       do concurrent(j = 1 : this % num_stages)
          call this % system % func % getFunctionValue(ftmp, this % T(j), &
               & x, this % Q(k,j,:), this % QDOT(k,j,:), this % QDDOT(k,j,:))
          fval = fval +  this % h * this % B(j) * ftmp
       end do
    end do
    
!!$    do concurrent(k = 1 : this % num_steps)
!!$       call this % system % func % getFunctionValue(ftmp(k), this % time(k), &
!!$            & x, this % U(k,:), this % UDOT(k,:), this % UDDOT(k,:))
!!$       ftmp(k) = this % h * ftmp(k)
!!$    end do
    
    ! fval = sum(ftmp)/dble(this % num_steps)
    ! fval = sum(ftmp)

  end subroutine evalFunc

end module runge_kutta_integrator
