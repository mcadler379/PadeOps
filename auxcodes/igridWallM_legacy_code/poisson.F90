module poissonMod
    use kind_parameters, only: rkind
    use spectralMod, only: spectral, GetWaveNums 
    use constants, only: zero, one, two, imi
    use exits, only: GracefulExit
    use decomp_2d
    use staggOpsMod, only: staggOps

    implicit none 

    private
    public :: poisson

    complex(rkind), parameter :: zeroC = zero + imi*zero 
    type :: poisson
        private
        integer :: nx_in, ny_in, nz_in
        complex(rkind), dimension(:,:,:,:), allocatable :: tmp
        real(rkind), dimension(:,:,:), allocatable :: mfact1, mfact2, mfact3
        logical :: zperiodic = .true. 

        type(decomp_info), pointer, public :: sp_gp
        type(decomp_info), pointer, public :: sp_gpE
        type(spectral), pointer, public :: spect
        real(rkind), dimension(:,:,:), pointer :: k1, k2

        ! Stuff for thomas algorithm
        integer :: nz_inZ, nx_inZ, ny_inZ
        real(rkind), dimension(:), allocatable :: k1_inZ, k2_inZ
        real(rkind) :: dz, dzsq
        integer :: xst, xen, yst, yen, zst, zen
        type(staggOps), pointer :: Ops    
        complex(rkind), dimension(:,:,:), allocatable :: tmpbuff, tmpbuffz1C, tmpbuffz2C, tmpbuffz1E, tmpbuffz2E 

        logical :: usingWallModel = .false. 
        type(decomp_info), pointer :: gpC
        real(rkind) :: meanNorm

        contains
            procedure :: init
            procedure :: destroy
            procedure :: PressureProj
            procedure :: getPressure
            procedure :: PoissonSolveZ    
            procedure, private :: PoissonSolveZ_InPlace   
            procedure, private :: PoissonSolveZ_InPlace_WallM 
            procedure :: allocArrZ   
            procedure :: PressureProjNP
            procedure :: DivergenceCheck 
    end type 

contains


    subroutine DivergenceCheck(this,uhat,vhat,what, divergence)
        use mpi
        use exits, only: message
        use reductions, only: p_maxval
        class(poisson), intent(inout) :: this
        complex(rkind), dimension(this%sp_gp%ysz(1),this%sp_gp%ysz(2),this%sp_gp%ysz(3)), intent(inout) :: uhat, vhat
        complex(rkind), dimension(this%sp_gpE%ysz(1),this%sp_gpE%ysz(2),this%sp_gpE%ysz(3)), intent(inout) :: what

        real(rkind), dimension(this%sp_gp%xsz(1),this%sp_gp%xsz(2),this%sp_gp%xsz(3)), intent(out) :: divergence

        real(rkind) :: maxDiv
        integer :: ierr

        ! Compute dudx_hat and add dvdy_hat
        this%tmpbuff = this%spect%k1*uhat 
        this%tmpbuff = this%tmpbuff + this%spect%k2*vhat 
        this%tmpbuff = imi*this%tmpbuff

        ! Transpose y -> z
        call transpose_y_to_z(this%tmpbuff,this%tmpbuffz1C,this%sp_gp)
        call transpose_y_to_z(what,this%tmpbuffz1E,this%sp_gpE)

        ! Compute dwdz_hat and add
        call this%Ops%ddz_E2C(this%tmpbuffz1E,this%tmpbuffz2C)
        this%tmpbuffz1C = this%tmpbuffz1C + this%tmpbuffz2C

        ! Transpose back from z -> y
        call transpose_z_to_y(this%tmpbuffz1C,this%tmpbuff,this%sp_gp)

        ! Compute IFFT to go back from y -> x
        this%tmpbuff(:,this%sp_gp%ysz(2)/2+1,:) = zero
        call this%spect%ifft(this%tmpbuff,divergence,.true.)

        maxDiv = p_maxval(maxval(divergence))
        
        if (maxDiv>1D-12) then
            !call message(3,"Divergence not zero, repeating projection")
            call mpi_barrier(mpi_comm_world,ierr)
            call this%PressureProjNP(uhat,vhat,what)
            
            ! Compute dudx_hat and add dvdy_hat
            this%tmpbuff = this%spect%k1*uhat 
            this%tmpbuff = this%tmpbuff + this%spect%k2*vhat 
            this%tmpbuff = imi*this%tmpbuff

            ! Transpose y -> z
            call transpose_y_to_z(this%tmpbuff,this%tmpbuffz1C,this%sp_gp)
            call transpose_y_to_z(what,this%tmpbuffz1E,this%sp_gpE)

            ! Compute dwdz_hat and add
            call this%Ops%ddz_E2C(this%tmpbuffz1E,this%tmpbuffz2C)
            this%tmpbuffz1C = this%tmpbuffz1C + this%tmpbuffz2C

            ! Transpose back from z -> y
            call transpose_z_to_y(this%tmpbuffz1C,this%tmpbuff,this%sp_gp)

            ! Compute IFFT to go back from y -> x
            this%tmpbuff(:,this%sp_gp%ysz(2)/2+1,:) = zero
            call this%spect%ifft(this%tmpbuff,divergence,.true.)
            maxDiv = p_maxval(maxval(divergence))
            if (maxDiv > 1D-12) then 
                call message(0,"WARNING: Divergence is now:", p_maxval(maxval(abs(divergence))))
            end if 
        end if 


    end subroutine 

    subroutine allocArrZ(this,arr)
        class(poisson), intent(in) :: this
        complex(rkind),dimension(:,:,:), allocatable, intent(out) :: arr
        type(decomp_info), pointer :: gp

        gp => this%sp_gp
        allocate(arr(gp%zsz(1),gp%zsz(2),gp%zsz(3)))
        nullify(gp) 
    end subroutine


    subroutine init(this,spect,PeriodicVertical,dx,dy,dz,Ops,spectE, usingWallModel, gpC)
        class(poisson), intent(inout) :: this
        class(spectral), intent(in), target :: spect
        class(spectral), intent(in), target, optional :: spectE
        logical, intent(in), optional :: PeriodicVertical
        real(rkind), optional :: dx, dy, dz
        type(staggOps), optional, target :: Ops
        logical, intent(in), optional :: usingWallModel
        type(decomp_info), optional, target :: gpC

        if(present(usingWallModel)) then
            this%usingWallModel = usingWallModel
        else
            this%usingWallModel = .false. 
        end if  
       
        if (present(PeriodicVertical)) then
            this%zperiodic = PeriodicVertical
        end if  

        if (this%zperiodic) then
            call spect%alloc_r2c_out(this%tmp,2)
            this%nx_in = size(this%tmp,1)
            this%ny_in = size(this%tmp,2)
            this%nz_in = size(this%tmp,3)

            allocate(this%mfact1(size(spect%k1,1),size(spect%k1,2),size(spect%k1,3)))
            allocate(this%mfact2(size(spect%k1,1),size(spect%k1,2),size(spect%k1,3)))
            allocate(this%mfact3(size(spect%k1,1),size(spect%k1,2),size(spect%k1,3)))

            this%mfact1 = spect%k1*spect%one_by_kabs_sq
            this%mfact2 = spect%k2*spect%one_by_kabs_sq
            this%mfact3 = spect%k3*spect%one_by_kabs_sq
        else
            if (.not.present(dz)) call GracefulExit("Need to send in dz as input to poisson init",31)
            if (.not.present(Ops)) call GracefulExit("Need to send in STAGGOPS as input to poisson init",31)
            if (.not.present(SpectE)) call GracefulExit("Need to send in spectE as input to poisson init",31)
            if (present(gpC)) this%gpC => gpC
            this%dz = dz 
            this%dzsq = dz**2
            this%nz_inZ = spect%nz_g
            this%nx_inZ = size(spect%k1,1)
            this%ny_inZ = size(spect%k1,2)
            allocate(this%k1_inZ(spect%nx_g))
            allocate(this%k2_inZ(spect%ny_g))
            this%k1_inZ = GetWaveNums(spect%nx_g,dx)
            this%k2_inZ = GetWaveNums(spect%ny_g,dy)
            this%sp_gp => spect%spectdecomp
            this%sp_gpE => spectE%spectdecomp
            this%spect => spect
            this%xst = this%sp_gp%zst(1)
            this%xen = this%sp_gp%zen(1)
            this%yst = this%sp_gp%zst(2)
            this%yen = this%sp_gp%zen(2)
            this%zst = this%sp_gp%zst(3)
            this%zen = this%sp_gp%zen(3)
            this%Ops => Ops
            allocate(this%tmpbuff(this%sp_gp%ysz(1),this%sp_gp%ysz(2),this%sp_gp%ysz(3)))
            allocate(this%tmpbuffz1C(this%sp_gp%zsz(1),this%sp_gp%zsz(2),this%sp_gp%zsz(3)))
            allocate(this%tmpbuffz2C(this%sp_gp%zsz(1),this%sp_gp%zsz(2),this%sp_gp%zsz(3)))
            allocate(this%tmpbuffz1E(this%sp_gpE%zsz(1),this%sp_gpE%zsz(2),this%sp_gpE%zsz(3)))
            allocate(this%tmpbuffz2E(this%sp_gpE%zsz(1),this%sp_gpE%zsz(2),this%sp_gpE%zsz(3)))
            if (present(gpC)) then
                this%meanNorm = 1._rkind/(real(gpC%xsz(1),rkind) * real(gpC%ysz(2),rkind) * real(gpC%zsz(3),rkind))
            end if 
        end if 

    end subroutine

    subroutine destroy(this)
        class(poisson), intent(inout) :: this
        
        if (allocated(this%tmp)) deallocate(this%tmp) 
        if (allocated(this%mfact1)) deallocate(this%mfact1) 
        if (allocated(this%mfact2)) deallocate(this%mfact2) 
        if (allocated(this%mfact3)) deallocate(this%mfact3) 
        if (allocated(this%k1_inZ)) deallocate(this%k1_inZ)
        if (allocated(this%k2_inZ)) deallocate(this%k2_inZ)
        if (allocated(this%tmpbuff)) deallocate(this%tmpbuff)
        if (allocated(this%tmpbuffz1C)) deallocate(this%tmpbuffz1C)
        if (allocated(this%tmpbuffz2C)) deallocate(this%tmpbuffz2C)
        if (allocated(this%tmpbuffz1E)) deallocate(this%tmpbuffz1E)
        if (allocated(this%tmpbuffz2E)) deallocate(this%tmpbuffz2E)
        nullify(this%sp_gp)
        nullify(this%sp_gpE)
        nullify(this%spect)
        nullify(this%k1, this%k2)
        nullify(this%Ops)
    end subroutine

    subroutine PressureProjNP(this,uhat,vhat,what)
        class(poisson), intent(inout), target :: this
        complex(rkind), dimension(this%sp_gp%ysz(1),this%sp_gp%ysz(2),this%sp_gp%ysz(3)), intent(inout) :: uhat, vhat
        complex(rkind), dimension(this%sp_gpE%ysz(1),this%sp_gpE%ysz(2),this%sp_gpE%ysz(3)), intent(inout) :: what
        complex(rkind), dimension(:,:), pointer :: dpdz0, dpdzN

        ! Compute dudx_hat and add dvdy_hat
        this%tmpbuff = this%spect%k1*uhat 
        this%tmpbuff = this%tmpbuff + this%spect%k2*vhat 
        this%tmpbuff = imi*this%tmpbuff

        ! Transpose y -> z
        call transpose_y_to_z(this%tmpbuff,this%tmpbuffz1C,this%sp_gp)
        call transpose_y_to_z(what,this%tmpbuffz1E,this%sp_gpE)

        ! Compute dwdz_hat and add
        call this%Ops%ddz_E2C(this%tmpbuffz1E,this%tmpbuffz2C)
        this%tmpbuffz1C = this%tmpbuffz1C + this%tmpbuffz2C
        
        ! Poisson Solver in z decomp
        if (this%usingWallModel) then
            dpdz0 => this%tmpbuffz1E(:,:,1)
            dpdzN => this%tmpbuffz1E(:,:,this%nz_inZ+1)
            call this%PoissonSolveZ_inPlace_WallM(this%tmpbuffz1C, dpdz0, dpdzN)
        else
            call this%PoissonSolveZ_inPlace(this%tmpbuffz1C)
        end if

        ! Compute dpdz_hat and project out what
        call this%Ops%ddz_C2E(this%tmpbuffz1C,this%tmpbuffz2E,.true.,.true.)
        if (this%usingWallModel) then
            this%tmpbuffz2E(:,:,1) = dpdz0
            this%tmpbuffz2E(:,:,this%nz_inZ+1) = dpdzN
        end if 
        this%tmpbuffz1E = this%tmpbuffz1E - this%tmpbuffz2E
        this%tmpbuffz1E(:,:,1) = zeroC ! <- This should be zero either way
        this%tmpbuffz1E(:,:,this%sp_gpE%zsz(3)) = zeroC

        ! Transpose z -> y
        call transpose_z_to_y(this%tmpbuffz1E,what,this%sp_gpE)
        call transpose_z_to_y(this%tmpbuffz1C,this%tmpbuff,this%sp_gp)
        
        ! Project out uhat and vhat 
        uhat = uhat - imi*this%spect%k1*this%tmpbuff
        vhat = vhat - imi*this%spect%k2*this%tmpbuff

        ! Check if divergence is exactly zero

    end subroutine 

    subroutine getPressure(this,urhs,vrhs,wrhs,pressure)
        use reductions, only: p_sum

        class(poisson), intent(inout), target :: this
        complex(rkind), dimension(this%sp_gp%ysz(1),this%sp_gp%ysz(2),this%sp_gp%ysz(3)), intent(inout) :: urhs, vrhs
        complex(rkind), dimension(this%sp_gpE%ysz(1),this%sp_gpE%ysz(2),this%sp_gpE%ysz(3)), intent(inout) :: wrhs
        complex(rkind), dimension(:,:), pointer :: dpdz0, dpdzN
        real(rkind), dimension(this%gpC%xsz(1),this%gpC%xsz(2),this%gpC%xsz(3)), intent(out) :: pressure
        real(rkind) :: pmean

        ! Compute dudx_rhs and add dvdy_rhs
        this%tmpbuff = this%spect%k1*urhs 
        this%tmpbuff = this%tmpbuff + this%spect%k2*vrhs 
        this%tmpbuff = imi*this%tmpbuff

        ! Transpose y -> z
        call transpose_y_to_z(this%tmpbuff,this%tmpbuffz1C,this%sp_gp)
        call transpose_y_to_z(wrhs,this%tmpbuffz1E,this%sp_gpE)

        ! Compute dwdz_rhs and add
        call this%Ops%ddz_E2C(this%tmpbuffz1E,this%tmpbuffz2C)
        this%tmpbuffz1C = this%tmpbuffz1C + this%tmpbuffz2C
        
        ! Poisson Solver in z decomp
        if (this%usingWallModel) then
            dpdz0 => this%tmpbuffz1E(:,:,1)
            dpdzN => this%tmpbuffz1E(:,:,this%nz_inZ+1)
            call this%PoissonSolveZ_inPlace_WallM(this%tmpbuffz1C, dpdz0, dpdzN)
        else
            call this%PoissonSolveZ_inPlace(this%tmpbuffz1C)
        end if
        
        call transpose_z_to_y(this%tmpbuffz1C,this%tmpbuff,this%sp_gp)
        call this%spect%ifft(this%tmpbuff,pressure)  

        ! Set the domain mean to be zero
        pmean = p_sum(pressure)*this%meanNorm
        pressure = pressure - pmean

    end subroutine 


    subroutine PressureProj(this,Sfields,spect)
        class(poisson), target, intent(inout) :: this
        class(spectral), target, intent(inout) :: spect
        complex(rkind), target, dimension(this%nx_in,this%ny_in,this%nz_in,3), intent(inout) :: Sfields
        complex(rkind), dimension(:,:,:), pointer :: tmp1, tmp2, uhat, vhat, what
        real(rkind), dimension(:,:,:), pointer :: k1, k2, k3

        tmp1 => this%tmp(:,:,:,1)
        tmp2 => this%tmp(:,:,:,2)
        uhat => Sfields(:,:,:,1)
        vhat => Sfields(:,:,:,2)
        what => Sfields(:,:,:,3)
        k1 => spect%k1
        k2 => spect%k2
        k3 => spect%k3

        if (this%zperiodic) then
            ! STEP 1: COMPUTE DIVERGENCE 
            tmp1 = k1*uhat 
            tmp1 = tmp1 + k2*vhat
            tmp1 = tmp1 + k3*what 

            ! STEP 2: PROJECT U VELOCITY
            tmp2 = this%mfact1*tmp1
            uhat = uhat - tmp2

            ! STEP 3: PROJECT V VELOCITY
            tmp2 = this%mfact2*tmp1
            vhat = vhat - tmp2

            ! STEP 4: PROJECT U VELOCITY
            tmp2 = this%mfact3*tmp1
            what = what - tmp2
        else
            print*, "Incomplete"    
        end if 
        
        nullify(tmp1, tmp2, uhat, vhat, what, k1, k2, k3)
        ! DONE - the new velocity fields is divergence free
    end subroutine

    subroutine PoissonSolveZ(this,fhat,phat)
        ! Assuming that everything is in z-decomp
        class(poisson), intent(in) :: this 
        complex(rkind), dimension(this%sp_gp%zsz(1),this%sp_gp%zsz(2),this%sp_gp%zsz(3)), intent(in) :: fhat
        complex(rkind), dimension(this%sp_gp%zsz(1),this%sp_gp%zsz(2),this%sp_gp%zsz(3)), intent(out):: phat
        real(rkind), dimension(this%sp_gp%zsz(3)) :: a, b, c
        integer :: i, j, ii, jj
        real(rkind) :: k1, k2, aa       
        complex(rkind), dimension(this%sp_gp%zsz(3)) :: y, rhs
       
        jj = 1
        do j = this%sp_gp%zst(2),this%sp_gp%zen(2)
            ii = 1
            do i = this%sp_gp%zst(1),this%sp_gp%zen(1)
                k1 = this%k1_inZ(i)
                k2 = this%k2_inZ(j)
                
                rhs = this%dzsq*fhat(ii,jj,:)
                
                if ((i == 1).and. (j == 1)) then
                    call genTridiag2ndOrder(k1,k2,this%dz,this%nz_inZ,a,b,c)
                    a(1) = one; b(1) = zero; c(1) = zero
                    rhs(1) = zero
                    call solveTridiag_Poiss(a,b,c,rhs,y,this%nz_inZ)
                    phat(ii,jj,:) = y
                else
                    aa = (-(k1*this%dz)**2 - (k2*this%dz)**2 - two)
                    call solveTridiag_Poiss_InPlace_quick(aa,one,one,rhs,this%nz_inZ)
                    phat(ii,jj,:) = rhs
                end if 
                ii = ii + 1
            end do 
            jj = jj + 1
        end do 

    end subroutine    

    subroutine PoissonSolveZ_InPlace(this,fhat)
        ! Assuming that everything is in z-decomp
        class(poisson), intent(in) :: this 
        complex(rkind), dimension(this%sp_gp%zsz(1),this%sp_gp%zsz(2),this%sp_gp%zsz(3)), intent(inout):: fhat
        real(rkind), dimension(this%nz_inZ) :: a, b, c
        integer :: i, j, ii, jj
        real(rkind) :: k1, k2, aa       
        complex(rkind), dimension(this%nz_inZ) :: y, rhs
       

        jj = 1
        do j = this%sp_gp%zst(2),this%sp_gp%zen(2)
            ii = 1
            do i = this%sp_gp%zst(1),this%sp_gp%zen(1)
                k1 = this%k1_inZ(i)
                k2 = this%k2_inZ(j)
                
                rhs = this%dzsq*fhat(ii,jj,:)
                
                if ((i == 1).and. (j == 1)) then
                    call genTridiag2ndOrder(k1,k2,this%dz,this%nz_inZ,a,b,c)
                    a(1) = one; b(1) = zero; c(1) = zero
                    rhs(1) = zero
                    call solveTridiag_Poiss(a,b,c,rhs,y,this%nz_inZ)
                    fhat(ii,jj,:) = y
                else
                    aa = (-(k1*this%dz)**2 - (k2*this%dz)**2 - two)
                    call solveTridiag_Poiss_InPlace_quick(aa,one,one,rhs,this%nz_inZ)
                    fhat(ii,jj,:) = rhs
                end if 
                ii = ii + 1
            end do
            jj = jj + 1 
        end do 

    end subroutine    


    subroutine PoissonSolveZ_InPlace_WallM(this,fhat,dpdz0, dpdzN)
        ! Assuming that everything is in z-decomp
        class(poisson), intent(in) :: this 
        complex(rkind), dimension(this%sp_gp%zsz(1),this%sp_gp%zsz(2),this%sp_gp%zsz(3)), intent(inout):: fhat
        complex(rkind), dimension(this%sp_gp%zsz(1),this%sp_gp%zsz(2)), intent(in):: dpdz0, dpdzN
        real(rkind), dimension(this%nz_inZ) :: a, b, c
        integer :: i, j, ii, jj
        real(rkind) :: k1, k2, aa       
        complex(rkind), dimension(this%nz_inZ) :: y, rhs
       

        jj = 1
        do j = this%sp_gp%zst(2),this%sp_gp%zen(2)
            ii = 1
            do i = this%sp_gp%zst(1),this%sp_gp%zen(1)
                k1 = this%k1_inZ(i)
                k2 = this%k2_inZ(j)
                
                rhs = this%dzsq*fhat(ii,jj,:)
                
                if ((i == 1).and. (j == 1)) then
                    call genTridiag2ndOrder(k1,k2,this%dz,this%nz_inZ,a,b,c)
                    a(1) = one; b(1) = zero; c(1) = zero
                    rhs(1) = zero
                    call solveTridiag_Poiss(a,b,c,rhs,y,this%nz_inZ)
                    fhat(ii,jj,:) = y
                else
                    aa = (-(k1*this%dz)**2 - (k2*this%dz)**2 - two)
                    rhs(1) = rhs(1) + this%dz*dpdz0(ii,jj)
                    rhs(this%nz_inZ) = rhs(this%nz_inZ) + this%dz*dpdzN(ii,jj)
                    call solveTridiag_Poiss_InPlace_quick(aa,one,one,rhs,this%nz_inZ)
                    fhat(ii,jj,:) = rhs
                end if 
                ii = ii + 1
            end do
            jj = jj + 1 
        end do 

    end subroutine    




    pure subroutine genTridiag2ndOrder(k1,k2,dz,n,a,b,c)
        real(rkind), intent(in) :: k1, k2, dz
        integer, intent(in) :: n
        real(rkind), dimension(n), intent(out) :: a, b, c

        a = (-(k1*dz)**2 - (k2*dz)**2 - 2)
        b = 1._rkind
        c = 1._rkind
        a(1) = a(1) + 1
        a(n) = a(n) + 1
        
    end subroutine


    pure subroutine solveTridiag_Poiss(a,b,c,f,y,n) 
        integer,intent(in) :: n
        real(rkind),dimension(n),intent(in) :: a,b,c
        complex(rkind), dimension(n), intent(in) :: f
        complex(rkind), dimension(n), intent(out) :: y
        real(rkind),dimension(n) :: v
        real(rkind) :: w
        integer :: i, j
        
        w = a(1)
        y(1) = f(1)/w
        
        do i = 2,n
            v(i-1) = c(i-1)/w
            w = a(i) - b(i)*v(i-1)
            y(i) = ( f(i) - b(i)*y(i-1))/w
        end do 

        do j = n-1,1,-1
            y(j) = y(j) - v(j)*y(j+1)
        end do 

    end subroutine
    
    subroutine solveTridiag_Poiss_InPlace_quick(a,b,c,f,n) 
        integer,intent(in) :: n
        real(rkind),intent(in) :: a,b,c
        complex(rkind), dimension(n), intent(inout) :: f
        !complex(rkind), dimension(n), intent(out) :: y
        real(rkind),dimension(n) :: v
        real(rkind) :: w
        integer :: i, j
        
        w = a + one
        f(1) = f(1)/w
        
        do i = 2,n-1
            v(i-1) = c/w
            w = a - b*v(i-1)
            f(i) = ( f(i) - b*f(i-1))/w
        end do
        v(n-1) = c/w
        w = (a + one) - b*v(n-1)
        f(n) = (f(n) - b*f(n-1))/w 

        do j = n-1,1,-1
            f(j) = f(j) - v(j)*f(j+1)
        end do 

    end subroutine
    
end module 
