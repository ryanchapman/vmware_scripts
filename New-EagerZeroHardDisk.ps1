Function New-EagerZeroHardDisk {
<#
.SYNOPSIS
  Creates a new thick hard disk and completely scrub (write zeros) the disk immediately.
.DESCRIPTION
  Virtual disks on some filesystems like VMFS3 are zeroed-out lazily so that 
  creation time doesn't take too long. However, clustering applications and 
  features like Fault Tolerance require that the virtual disk be completely
  scrubbed.  This function allows the creation of a virtual hard disk that is 
  zeroed out at creation time.
.PARAMETER VM 
  Specify the virtual machine to which you want to add the new disk.
.PARAMETER Datastore
  Specify the datastore where you want to place the new hard disk.
  For example: New-EagerZeroHardDisk ... -Datastore (Get-Datastore 'datastore0')
.PARAMETER CapacityKB
  Specify the capacity of the new virtual disk (in KB).  Must be at least 1024.
.PARAMETER Controller
  Specify a SCSI controller to which you want to attach the new hard disk.
  Note that you can only have one SCSI controller per virtual machine.  If
  a SCSI controller is already attached to the virtual machine, then this
  parameter is ignored.
  As of this writing, possible controllers are:
   ParaVirtualSCSIController
   VirtualBusLogicController
   VirtualLsiLogicController (default)
   VirtualLsiLogicSASController
  For example: New-EagerZeroHardDisk ... -Controller (New-Object VMware.Vim.ParaVirtualSCSIController)
.PARAMETER Persistence
  Specify the disk persistence mode. The valid values are:
    append
    independent_nonpersistent
    independent_persistent
    nonpersistent
    persistent
    undoable
.PARAMETER Split
  Specify the type of the virtual disk file -- split or monolithic. If the parameter -Split is given,
  the virtual disk is stored in multiple files, each 2GB.  Otherwise, the virtual disk is stored
  is stored in a single file.
.PARAMETER RunAsync
  Specify if this command should wait for the zeroing operation to complete.  If the parameter
  -RunAsync is given, then the zeroing operation will occur in the background, and this command
  will return immediately.  Otherwise, this command will wait (block) until the zeroing operation
  has completed, which could take quite a bit of time, depending on the size of the new hard disk.
.INPUTS
  None. You cannot pipe objects to New-EagerZeroHardDisk
.OUTPUTS
  System.String. New-EagerZeroHardDisk returns a string containing information about the hard disk
  that was created.
.EXAMPLE
  New-EagerZeroHardDisk -VM VM -Datastore (Get-Datastore 'datastore0') -CapacityKB (1024*1024*20)

  Adds to the VM virtual machine a new hard disk in a persistent mode with a capacity of 20 GB.
  The progress of the creation/zeroing is printed to the screen.
.EXAMPLE
  New-EagerZeroHardDisk -VM VM -Datastore (Get-Datastore 'datastore0') -CapacityKB (1024*1024*20) -Controller (New-Object VMware.Vim.ParaVirtualSCSIController)

  Adds to the VM virtual machine a new hard disk in a persistent mode with a capacity of 20 GB.
  If a SCSI controller does not yet exist for the virtual machine, then a Paravirtual SCSI controller is 
  created.
  The progress of the creation/zeroing is printed to the screen.
.EXAMPLE
  New-EagerZeroHardDisk -VM VM -Datastore (Get-Datastore 'datastore0') -CapacityKB (1024*1024*20) -RunAsync

  Adds to the VM virtual machine a new hard disk in a persistent mode with a capacity of 20 GB.
  Because the -RunAsync parameter is given, the creation of the hard disk occurs in the background.
  The progress of the creation/zeroing is NOT printed to the screen and this function returns immediately
  after the task is submitted to the server.
.NOTES
  The vSphere SDK API documentation refers to zeroing a hard disk at the time of creation as eagerlyScrub.
  Some documents refer to this as eagerzero.

  Written by Ryan Chapman, ryan@heatery.com
  Fri Jan  6 15:14:25 MST 2012
.LINK
EagerlyScrub: http://pubs.vmware.com/vsphere-50/topic/com.vmware.wssdk.apiref.doc_50/vim.vm.device.VirtualDisk.FlatVer2BackingInfo.html
.LINK
ReconfigVM_Task: http://pubs.vmware.com/vsphere-50/topic/com.vmware.wssdk.apiref.doc_50/vim.VirtualMachine.html#reconfigure
#>
    param(
        [Parameter(Mandatory=$true)]
        [System.String]
        ${VM},

        [Parameter(Mandatory=$true)]
        [VMware.VimAutomation.ViCore.Impl.V1.DatastoreManagement.DatastoreImpl]
        ${Datastore},

        [Parameter(Mandatory=$true)]
        [Int64]
        ${CapacityKB},

        [VMware.Vim.VirtualScsiController]
        ${Controller},
    
        [VMware.Vim.VirtualDiskMode]
        ${Persistence} = 'persistent',

        [Switch]
        ${Split},

        [Switch]
        ${RunAsync}
    )

    # Attempting to create a hard disk less than 1024 KB will fail
    if($CapacityKB -lt 1024)
    {
        Throw "CapacityKB must be at least 1024"
        return
    }

    $vmObj = Get-VM -Name $VM | Get-View

    # Does any SCSI controller exist in the VM?
    $vmController = $vmObj.Config.Hardware.Device | ?{$_ -is [VMware.Vim.VirtualScsiController]}

    # Create a SCSI controller in the VM if none exists yet
    if($vmController -eq $null)
    {
        # User specified controller?
        if($Controller -eq $null) 
        {
            $controllerType = New-Object VMware.Vim.VirtualLsiLogicController
        } else {
            $controllerType = New-Object $Controller
        }

        $spec = New-Object VMware.Vim.VirtualMachineConfigSpec
        $spec.deviceChange = @()
        $spec.deviceChange += New-Object VMware.Vim.VirtualDeviceConfigSpec
        $spec.deviceChange[0].device = $controllerType
        $spec.deviceChange[0].operation = "add"
        $controllerKind = $controllerType.GetType().Name
        Write-Progress -activity "Creating a $controllerKind controller for vm $VM" -status "percent created: 0" -PercentComplete 0
        $taskMoRef = $vmObj.ReconfigVM_Task($spec)
        $task = Get-View $taskMoRef
        while($task.Info.State -eq "running" -or $task.Info.State -eq "queued") {
            $task.UpdateViewData("Info")
            if($task.Info.Progress -is [int]) {
                $progress = $task.Info.Progress
            } else {
                $progress = 0
            }
            Write-Progress -activity "Creating controller for vm $VM" -status "percent created: $progress" -PercentComplete $progress
        }
        # Get controller object for later use
        $vmObj = Get-VM -Name $VM | Get-View
        $vmController = $vmObj.Config.Hardware.Device | ?{$_ -is [VMware.Vim.VirtualScsiController]}
    }

    # Find the next Unit Number (SCSI Id)
    #  If the SCSI controller device list is null, then no hard disks are attached
    if($vmController.Device -eq $null)
    {
        $nextUnitNumber=0
    } else {
        # For the SCSI adapter we plan to add a virtual HD to in a moment, get list of hard disks attached to it
        $hardDisksOnScsiController = $vmController.Device
        $scsiUnitNumbersInUse = $vmObj.Config.Hardware.Device | ?{$_ -is [VMware.Vim.VirtualDisk]} | ?{$hardDisksOnScsiController -contains $_.Key} | %{$_.UnitNumber}
        for($i=0; $nextUnitNumber -eq $null; $i++)
        {
            if($scsiUnitNumbersInUse -notcontains $i)
            {
                $nextUnitNumber=$i
            }
        }
    }

    # Create the hard disk
    $spec = New-Object VMware.Vim.VirtualMachineConfigSpec
    $spec.deviceChange = @()
    $spec.deviceChange += New-Object VMware.Vim.VirtualDeviceConfigSpec
    $spec.deviceChange[0].Device = New-Object VMware.Vim.VirtualDisk
    $spec.deviceChange[0].Device.Backing = New-Object VMware.Vim.VirtualDiskFlatVer2BackingInfo
    $spec.deviceChange[0].Device.Backing.DiskMode = $Persistence
    $spec.deviceChange[0].Device.Backing.Split = $Split.ToBool()
    $spec.deviceChange[0].Device.Backing.WriteThrough = $false
    $spec.deviceChange[0].Device.Backing.ThinProvisioned = $false
    $spec.deviceChange[0].Device.Backing.EagerlyScrub = $true
    $spec.deviceChange[0].Device.Backing.Uuid = $null
    $spec.deviceChange[0].Device.Backing.ContentId = $null
    $spec.deviceChange[0].Device.Backing.ChangeId = $null
    $spec.deviceChange[0].Device.Backing.Parent = $null
    $spec.deviceChange[0].Device.Backing.FileName = '[' + $Datastore.Name + ']'
    $spec.deviceChange[0].Device.Backing.Datastore = $Datastore.ExtensionData.MoRef
    $spec.deviceChange[0].Device.Backing.DynamicType = $null
    $spec.deviceChange[0].Device.CapacityInKB = $CapacityKB
    $spec.deviceChange[0].Device.Shares = $null
    $spec.deviceChange[0].Device.StorageIOAllocation = $null
    $spec.deviceChange[0].Device.Key = -100
    $spec.deviceChange[0].Device.DeviceInfo = $null
    $spec.deviceChange[0].Device.Connectable = New-Object VMware.Vim.VirtualDeviceConnectInfo
    $spec.deviceChange[0].Device.Connectable.allowGuestControl = $false
    $spec.deviceChange[0].Device.Connectable.connected = $true
    $spec.deviceChange[0].Device.Connectable.startConnected = $true
    $spec.deviceChange[0].Device.UnitNumber = $nextUnitNumber
    $spec.deviceChange[0].Device.ControllerKey = $vmController.Key
    $spec.deviceChange[0].fileOperation = "create"
    $spec.deviceChange[0].operation = "add"
    Write-Progress -activity "Creating eager zero hard disk for vm $VM" -status "percent created: 0" -PercentComplete 0
    $taskMoRef = $vmObj.ReconfigVM_Task($spec)
    $task = Get-View $taskMoRef
    if($RunAsync -eq $false) 
    {
        while($task.Info.State -eq "running" -or $task.Info.State -eq "queued") 
        {
            $task.UpdateViewData("Info")
            if($task.Info.Progress -is [int]) 
            {
                $progress = $task.Info.Progress
            } else {
                $progress = 0
            }
            Write-Progress -activity "Creating eager zero hard disk for vm $VM" -status "percent created: $progress" -PercentComplete $progress
        }
    }

    # Check for task errors
    if($task.Info.State -eq "error")
    {
        $errorMessage = "There was an error executing the task to create the hard disk: {0}" -f $task.Info.Error.LocalizedMessage
        Throw $errorMessage
    }
    # Print the results
    $newDisk = (Get-VM -Name $VM | Get-View).Config.Hardware.Device | ?{$_.ControllerKey -eq $vmController.Key -and $_.UnitNumber -eq $nextUnitNumber}
    $newDisk | Format-Table @{N="CapacityKB";E={$_.CapacityInKB};A="Left"},
                            @{N="Persistence";E={$_.Backing.DiskMode};A="Left"},
                            @{N="EagerlyScrub";E={$_.Backing.EagerlyScrub};A="Left"},
                            @{N="Filename";E={$_.Backing.FileName};A="Right"} `
                            -AutoSize
    $global:newDisk = $newDisk
}

Function Get-HardDiskDetails
{
    param(
        [Parameter(Mandatory=$true)]
        [System.Array]
        ${VM},

        [Parameter(Mandatory=$true)]
        [System.Array]
        ${HardDisk}
    )

    if($VM -eq $null -and $HardDisk -ne $null)
    {
        Throw "You must specify -VM when specifying -HardDisk"
    } 

    if($VM -eq $null)
    {
        $vms = Get-VM -Name $VM
    } else {
        $vms = Get-VM
    }

    foreach($vm in $vms)
    {
        if($HardDisk -eq $null)
        {
            $hardDisks = $vm | Get-HardDisk
        } else {
            $hardDisks = $vm | Get-HardDisk -Name $HardDisk
        }
        $hardDisks | Format-Table @{N="CapacityKB";E={};A="Left"},
                                  @{N="";E={};A=""}
    }



}
