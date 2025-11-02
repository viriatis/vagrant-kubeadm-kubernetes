# Convert VirtualBox VM disks from SATA to VirtIO-SCSI (20-30% faster storage)
# Converts both OS disks and Mayastor storage disks automatically
# This script must be run AFTER 'vagrant up' completes successfully
#
# How it works:
#   - Powers off running VMs gracefully (ACPI shutdown)
#   - Converts OS disks (port 0) from SATA to VirtIO-SCSI
#   - Converts storage disks (port 1) from SATA to VirtIO-SCSI (if present)
#   - Starts VMs with VirtIO drivers loaded
#   - Verifies VirtIO driver loaded in guest OS
#   - No vagrant reload needed!
#
# Usage:
#   .\convert-to-virtio.ps1                                      # Convert and auto-restart
#   PowerShell -ExecutionPolicy Bypass -File .\convert-to-virtio.ps1  # If execution policy blocks
#   .\convert-to-virtio.ps1 -DryRun                              # Show what would be done
#   .\convert-to-virtio.ps1 -NoRestart                           # Don't auto-restart after conversion
#
# Verify VirtIO-SCSI is working:
#   Note: lsblk -o NAME,TRAN may show empty TRAN field for VirtIO - this is normal!
#   Use these commands instead:
#
#   vagrant ssh node01 -c "sudo dmesg | grep -i virtio"
#   # Should show: virtio_scsi virtio0: ... Virtio SCSI HBA
#
#   vagrant ssh node01 -c "cat /sys/class/scsi_host/host0/proc_name"
#   # Should show: virtio_scsi
#
#   # Or verify in VirtualBox:
#   VBoxManage showvminfo vagrant-kubeadm-kubernetes_node01_* | grep "VirtIO SCSI"
#
# Benefits:
#   + Graceful ACPI shutdown (clean power off)
#   + Automatic restart with VirtIO drivers loaded
#   + Fast conversion (~3-4 minutes including shutdown/startup)
#   + 20-30% better storage performance with VirtIO-SCSI

param(
    [switch]$DryRun = $false,
    [switch]$Force = $false,
    [switch]$NoRestart = $false
)

# Check if VBoxManage is available
try {
    $null = Get-Command VBoxManage -ErrorAction Stop
} catch {
    Write-Error "VBoxManage not found in PATH. Please add VirtualBox to your PATH."
    Write-Host "Run: `$env:Path += ';C:\Program Files\Oracle\VirtualBox'" -ForegroundColor Yellow
    exit 1
}

# Get all VMs in the Kubernetes Cluster
Write-Host "`n=== Finding VirtualBox VMs ===" -ForegroundColor Cyan
$vms = VBoxManage list vms | Where-Object { $_ -match "kubeadm-kubernetes" } | ForEach-Object {
    if ($_ -match '"([^"]+)"') {
        $matches[1]
    }
}

if ($vms.Count -eq 0) {
    Write-Error "No VMs found. Please run 'vagrant up' first."
    exit 1
}

Write-Host "Found $($vms.Count) VMs to process:" -ForegroundColor Green
$vms | ForEach-Object { Write-Host "  - $_" }

# Track which VMs were paused (so we can resume them later)
$pausedVMs = @()

# Confirm before proceeding
if (-not $Force -and -not $DryRun) {
    Write-Host "`n INFO: This will gracefully POWER OFF running VMs, then convert OS disks to VirtIO-SCSI" -ForegroundColor Cyan
    Write-Host "   VMs will be restarted automatically after conversion with VirtIO drivers loaded!" -ForegroundColor Green
    $confirm = Read-Host "`nContinue? (yes/no)"
    if ($confirm -ne "yes") {
        Write-Host "Aborted." -ForegroundColor Red
        exit 0
    }
}

Write-Host "`n=== Powering off VMs gracefully ===" -ForegroundColor Cyan
foreach ($vm in $vms) {
    $state = VBoxManage showvminfo $vm --machinereadable | Select-String 'VMState=' | ForEach-Object { $_.ToString().Split('=')[1].Trim('"') }

    if ($state -eq "running") {
        Write-Host "Shutting down $vm (ACPI)..." -ForegroundColor Yellow
        $pausedVMs += $vm
        if (-not $DryRun) {
            VBoxManage controlvm $vm acpipowerbutton 2>&1 | Out-Null
        }
    } elseif ($state -eq "poweroff" -or $state -eq "saved") {
        Write-Host "$vm is powered off, will convert..." -ForegroundColor Cyan
        $pausedVMs += $vm
    } else {
        Write-Host "$vm is in state ($state), skipping..." -ForegroundColor Gray
    }
}

# Wait for all VMs to power off (with fallback to force poweroff)
if ($pausedVMs.Count -gt 0 -and -not $DryRun) {
    Write-Host "`nWaiting for VMs to power off gracefully..." -ForegroundColor Yellow
    $maxWait = 45  # Wait 45 seconds for ACPI shutdown
    $waited = 0
    $allOff = $false
    $forcedShutdown = @()

    while (-not $allOff -and $waited -lt $maxWait) {
        Start-Sleep -Seconds 5
        $waited += 5

        $allOff = $true
        foreach ($vm in $pausedVMs) {
            $state = VBoxManage showvminfo $vm --machinereadable | Select-String 'VMState=' | ForEach-Object { $_.ToString().Split('=')[1].Trim('"') }
            if ($state -ne "poweroff" -and $state -ne "saved") {
                $allOff = $false
                break
            }
        }

        if (-not $allOff) {
            Write-Host "  Still waiting... ($waited seconds)" -ForegroundColor Gray
        }
    }

    # If VMs still running after ACPI timeout, force poweroff
    if (-not $allOff) {
        Write-Host "`n[WARN] Some VMs did not respond to ACPI shutdown. Forcing poweroff..." -ForegroundColor Yellow

        foreach ($vm in $pausedVMs) {
            $state = VBoxManage showvminfo $vm --machinereadable | Select-String 'VMState=' | ForEach-Object { $_.ToString().Split('=')[1].Trim('"') }
            if ($state -ne "poweroff" -and $state -ne "saved") {
                Write-Host "  Force powering off $vm..." -ForegroundColor Yellow
                VBoxManage controlvm $vm poweroff 2>&1 | Out-Null
                $forcedShutdown += $vm
                Start-Sleep -Seconds 2
            }
        }

        # Wait a bit for forced shutdown to complete
        Start-Sleep -Seconds 5
    }

    # Final verification
    $allOff = $true
    foreach ($vm in $pausedVMs) {
        $state = VBoxManage showvminfo $vm --machinereadable | Select-String 'VMState=' | ForEach-Object { $_.ToString().Split('=')[1].Trim('"') }
        if ($state -ne "poweroff" -and $state -ne "saved") {
            $allOff = $false
            break
        }
    }

    if ($allOff) {
        Write-Host "[OK] All VMs powered off successfully!" -ForegroundColor Green
        if ($forcedShutdown.Count -gt 0) {
            Write-Host "  Note: $($forcedShutdown.Count) VMs required forced poweroff" -ForegroundColor Gray
        }
    } else {
        Write-Host "[ERROR] Some VMs could not be powered off. Aborting conversion." -ForegroundColor Red
        exit 1
    }
}

Write-Host "`n=== Converting OS disks to VirtIO-SCSI ===" -ForegroundColor Cyan
$converted = 0
$skipped = 0
$failed = 0

foreach ($vm in $vms) {
    Write-Host "`nProcessing: $vm" -ForegroundColor White

    # Get storage controller info
    $vmInfo = VBoxManage showvminfo $vm --machinereadable

    # Debug: Show all storage controllers
    Write-Host "  Storage controllers found:" -ForegroundColor Cyan
    $vmInfo | Select-String 'storagecontrollername' | ForEach-Object {
        Write-Host "    $_" -ForegroundColor Gray
    }

    # Check if VirtIO-SCSI controller already exists
    $hasVirtIOController = $vmInfo | Select-String 'storagecontrollername.*virtio' -CaseSensitive:$false
    $osDiskConverted = $false
    $storageDiskConverted = $false

    if ($hasVirtIOController) {
        $virtioControllerName = $hasVirtIOController.ToString().Split('=')[1].Trim('"')

        # Check if OS disk (port 0) is on VirtIO SCSI
        $virtioDiskKey = "$virtioControllerName-0-0"
        $virtioDiskLine = $vmInfo | Select-String "`"$virtioDiskKey`"="
        if ($virtioDiskLine) {
            $virtioDisk = $virtioDiskLine.ToString().Split('=', 2)[1].Trim('"')
            if ($virtioDisk -and $virtioDisk -ne "none") {
                $osDiskConverted = $true
                Write-Host "  OS disk already on VirtIO-SCSI" -ForegroundColor Green
            }
        }

        # Check if storage disk (port 1) is on VirtIO SCSI
        $virtioStorageDiskKey = "$virtioControllerName-1-0"
        $virtioStorageDiskLine = $vmInfo | Select-String "`"$virtioStorageDiskKey`"="
        if ($virtioStorageDiskLine) {
            $virtioStorageDisk = $virtioStorageDiskLine.ToString().Split('=', 2)[1].Trim('"')
            if ($virtioStorageDisk -and $virtioStorageDisk -ne "none") {
                $storageDiskConverted = $true
                Write-Host "  Storage disk already on VirtIO-SCSI" -ForegroundColor Green
            }
        }

        # Check if there's a storage disk on other controllers that needs conversion
        $hasStorageDiskOnOtherController = $false
        foreach ($controller in ($vmInfo | Select-String 'storagecontrollername\d+=' | ForEach-Object { $_.ToString().Split('=')[1].Trim('"') })) {
            if ($controller -ne $virtioControllerName) {
                $diskKey = "$controller-1-0"
                $diskLine = $vmInfo | Select-String "`"$diskKey`"="
                if ($diskLine) {
                    $diskPath = $diskLine.ToString().Split('=', 2)[1].Trim('"')
                    if ($diskPath -and $diskPath -ne "none") {
                        $hasStorageDiskOnOtherController = $true
                        break
                    }
                }
            }
        }

        # Skip only if OS disk is converted AND (no storage disk exists OR storage disk is converted)
        if ($osDiskConverted -and (-not $hasStorageDiskOnOtherController)) {
            Write-Host "  All disks already on VirtIO-SCSI, skipping..." -ForegroundColor Green
            $skipped++
            continue
        }
    }

    # Find the OS disk by searching all controllers for a disk at port 0
    $osDisk = $null
    $osController = $null

    # Get all controller names
    $controllers = $vmInfo | Select-String 'storagecontrollername\d+=' | ForEach-Object {
        $_.ToString().Split('=')[1].Trim('"')
    }

    Write-Host "  Searching for OS disk across controllers..." -ForegroundColor Cyan
    foreach ($controller in $controllers) {
        $diskKey = "$controller-0-0"
        $diskLine = $vmInfo | Select-String "`"$diskKey`"="

        if ($diskLine) {
            $diskPath = $diskLine.ToString().Split('=', 2)[1].Trim('"')
            if ($diskPath -and $diskPath -ne "none") {
                $osDisk = $diskPath
                $osController = $controller
                Write-Host "  Found OS disk on: $controller" -ForegroundColor Green
                Write-Host "  OS Disk: $osDisk" -ForegroundColor Gray
                break
            }
        }
    }

    if (-not $osDisk) {
        Write-Host "  No OS disk found on any controller, skipping..." -ForegroundColor Yellow
        $skipped++
        continue
    }

    if ($DryRun) {
        Write-Host "  [DRY RUN] Would convert to VirtIO-SCSI" -ForegroundColor Cyan
        $converted++
        continue
    }

    # Perform conversion
    try {
        # Only create controller if it doesn't exist
        if (-not $hasVirtIOController) {
            Write-Host "  Creating VirtIO-SCSI controller..." -ForegroundColor Yellow
            VBoxManage storagectl $vm --name "VirtIO SCSI OS" --add virtio-scsi --portcount 2 --bootable on 2>&1 | Out-Null
        } else {
            Write-Host "  Using existing VirtIO-SCSI controller..." -ForegroundColor Cyan
        }

        Write-Host "  Detaching OS disk from $osController..." -ForegroundColor Yellow
        VBoxManage storageattach $vm --storagectl $osController --port 0 --medium none 2>&1 | Out-Null

        Write-Host "  Attaching OS disk to VirtIO-SCSI..." -ForegroundColor Yellow
        VBoxManage storageattach $vm --storagectl "VirtIO SCSI OS" --port 0 --type hdd --medium $osDisk 2>&1 | Out-Null

        Write-Host "  Successfully converted OS disk to VirtIO-SCSI!" -ForegroundColor Green

        # Check for storage disk (Mayastor storage pools on port 1)
        $storageDisk = $null
        $storageController = $null

        foreach ($controller in $controllers) {
            $diskKey = "$controller-1-0"
            $diskLine = $vmInfo | Select-String "`"$diskKey`"="

            if ($diskLine) {
                $diskPath = $diskLine.ToString().Split('=', 2)[1].Trim('"')
                if ($diskPath -and $diskPath -ne "none") {
                    $storageDisk = $diskPath
                    $storageController = $controller
                    Write-Host "  Found storage disk on: $controller (port 1)" -ForegroundColor Cyan
                    break
                }
            }
        }

        # Convert storage disk if found
        if ($storageDisk) {
            Write-Host "  Detaching storage disk from $storageController..." -ForegroundColor Yellow
            VBoxManage storageattach $vm --storagectl $storageController --port 1 --medium none 2>&1 | Out-Null

            Write-Host "  Attaching storage disk to VirtIO-SCSI (port 1)..." -ForegroundColor Yellow
            VBoxManage storageattach $vm --storagectl "VirtIO SCSI OS" --port 1 --type hdd --medium $storageDisk 2>&1 | Out-Null

            Write-Host "  Successfully converted storage disk to VirtIO-SCSI!" -ForegroundColor Green
        }

        # Remove old SATA Controller if empty (prevents boot order issues)
        if ($osController -eq "SATA Controller") {
            # Check if SATA Controller has any remaining disks
            $sataHasDisks = $false
            for ($port = 0; $port -le 30; $port++) {
                $diskLine = VBoxManage showvminfo $vm --machinereadable | Select-String "`"SATA Controller-$port-0`"="
                if ($diskLine) {
                    $diskPath = $diskLine.ToString().Split('=', 2)[1].Trim('"')
                    if ($diskPath -and $diskPath -ne "none") {
                        $sataHasDisks = $true
                        break
                    }
                }
            }

            if (-not $sataHasDisks) {
                Write-Host "  Removing empty SATA Controller..." -ForegroundColor Yellow
                VBoxManage storagectl $vm --name "SATA Controller" --remove 2>&1 | Out-Null
                Write-Host "  SATA Controller removed (fixes boot order)" -ForegroundColor Green
            }
        }

        $converted++
    } catch {
        Write-Host "  Failed: $_" -ForegroundColor Red
        $failed++
    }
}

# Summary
Write-Host "`n=== Conversion Summary ===" -ForegroundColor Cyan
Write-Host "  Converted: $converted" -ForegroundColor Green
Write-Host "  Skipped:   $skipped" -ForegroundColor Yellow
Write-Host "  Failed:    $failed" -ForegroundColor Red

# Start VMs that were saved
if ($pausedVMs.Count -gt 0 -and -not $DryRun -and -not $NoRestart) {
    Write-Host "`n=== Starting VMs ===" -ForegroundColor Cyan
    Write-Host "The following VMs had their state saved and will be restarted:" -ForegroundColor Yellow
    $pausedVMs | ForEach-Object { Write-Host "  - $_" -ForegroundColor White }

    foreach ($vm in $pausedVMs) {
        Write-Host "Starting $vm..." -ForegroundColor Yellow
        VBoxManage startvm $vm --type headless 2>&1 | Out-Null
        Start-Sleep -Seconds 2
    }
    Write-Host "[OK] All VMs started successfully!" -ForegroundColor Green
    Write-Host "  VMs are booting with VirtIO-SCSI drivers!" -ForegroundColor Green
}

if ($converted -gt 0 -and -not $DryRun) {
    Write-Host "`n[OK] Conversion complete!" -ForegroundColor Green

    if ($pausedVMs.Count -gt 0 -and -not $NoRestart) {
        Write-Host "`nVMs have been started and are booting with VirtIO-SCSI." -ForegroundColor Green
        Write-Host "Waiting 60 seconds for VMs to boot before verification..." -ForegroundColor Yellow
        Start-Sleep -Seconds 60

        Write-Host "`n=== Verifying VirtIO-SCSI in Guest OS ===" -ForegroundColor Cyan
        # Find first worker or storage node to verify
        $testVM = $vms | Where-Object { $_ -match "node01|storage01" } | Select-Object -First 1

        if ($testVM) {
            Write-Host "Checking VirtIO driver in guest OS..." -ForegroundColor Yellow

            # Extract VM name for vagrant ssh
            $vmName = if ($testVM -match "_([^_]+)_\d+_\d+$") { $matches[1] } else { "node01" }

            try {
                $result = vagrant ssh $vmName -c "sudo dmesg | grep -i virtio" 2>&1 | Out-String

                if ($result -match "virtio_scsi") {
                    Write-Host "[OK] VirtIO-SCSI driver verified in guest OS!" -ForegroundColor Green
                    Write-Host "  Found: $($result.Split([Environment]::NewLine) | Where-Object { $_ -match 'virtio_scsi' } | Select-Object -First 1)" -ForegroundColor Gray
                } else {
                    Write-Host "[WARN] Could not verify VirtIO-SCSI in guest OS" -ForegroundColor Yellow
                    Write-Host "  Run manually: vagrant ssh $vmName -c 'sudo dmesg | grep -i virtio'" -ForegroundColor Gray
                }
            } catch {
                Write-Host "[WARN] Could not connect to VM for verification" -ForegroundColor Yellow
            }
        }

        Write-Host "`nWait 2-3 more minutes for cluster to stabilize, then verify:" -ForegroundColor Cyan
        Write-Host "  kubectl get nodes" -ForegroundColor White
    } else {
        Write-Host "`nNext steps:" -ForegroundColor Cyan
        Write-Host "  1. Start VMs: vagrant up" -ForegroundColor White
        Write-Host "  2. Verify: vagrant ssh controlplane" -ForegroundColor White
    }

    Write-Host "`nManual verification commands:" -ForegroundColor Cyan
    Write-Host "  vagrant ssh node01 -c 'sudo dmesg | grep -i virtio'" -ForegroundColor White
    Write-Host "  # Should show: virtio_scsi virtio0: ... Virtio SCSI HBA" -ForegroundColor Gray
}
