# Copies all rlog files from your comma device, over LAN or comma SSH, 
# to the specified local directory.
# devicehostname must match a defined ssh host setup for passwordless access using ssh keys
# You can prevent redundant transfers in two ways:
# If the to-be-transferred rlog already exists in the destination
# it will not be transferred again, so you can use the same directory
# and leave the files there

$basePath = Get-Location
$basePath = $basePath -replace "\\", "/"

$sftp = "$basePath/openssh/sftp"
$ssh = "$basePath/openssh/ssh"
$sshKeyPath = "$basePath/ssh.priv"
$sshOpt = "-o StrictHostKeyChecking=no".split(" ")

function checkSSHKey($sshKeyPath) {
  if (-not (Test-Path -Path $sshKeyPath)) {
    return $false
  }
  return $true
}

if((checkSSHKey $sshKeyPath) -eq $false) {
  Write-Warning "SSH private key file not found at $sshKeyPath"
  return
}

Set-ItemProperty -Path $sshKeyPath -Name "Attributes" -Value @(Get-ItemProperty -Path $sshKeyPath -Name "Attributes").Attributes -Force

Push-Location

function permissionSetup($sshKeyPath) {
  # Set Key File Variable:
  New-Variable -Name Key -Value $sshKeyPath

# Remove Inheritance:
  Icacls $Key /c /t /Inheritance:d

# Set Ownership to Owner:
# Key's within $env:UserProfile:
  Icacls $Key /c /t /Grant ${env:UserName}:F

  # Key's outside of $env:UserProfile:
  TakeOwn /F $Key
  Icacls $Key /c /t /Grant:r ${env:UserName}:F

# Remove All Users, except for Owner:
  Icacls $Key /c /t /Remove:g Administrator "Authenticated Users" BUILTIN\Administrators BUILTIN Everyone System Users

# Verify:
  Icacls $Key

# Remove Variable:
  Remove-Variable -Name Key
}

permissionSetup $sshKeyPath

function sshCommand($devicehostname, $cmd) {
  return ssh -i $sshKeyPath $sshOpt[0..($sshOpt.length-1)] $devicehostname $cmd
}

function sftpCommand($devicehostname, $cmd) {
  Set-Content -Path "sftpCommands.txt" -Value $cmd
  & $sftp -i $sshKeyPath $sshOpt[0..($sshOpt.length-1)] -b "sftpCommands.txt" $devicehostname
  Remove-Item -Path "sftpCommands.txt"
}

function fetch-rlogs ($check_list, $devicehostname, $diroutbase) {
  Write-Host "$devicehostname ($diroutbase): Fetching dongle ID"
  $DONGLEID = sshCommand($devicehostname, 'cat /data/params/d/DongleId') # & $ssh $sshOpt $devicehostname 'cat /data/params/d/DongleId'
  if ($LASTEXITCODE -ne 0) {
    Write-Host "$devicehostname ($diroutbase): device not online..."
    return 1
  }
  $DONGLEID = $DONGLEID.PadLeft(16, '0')

  $isoffroad = sshCommand($devicehostname, 'cat /data/params/d/IsOffroad') # & $ssh $sshOpt $devicehostname 'cat /data/params/d/IsOffroad'
  if ($isoffroad -ne 1) {
    Write-Host "$devicehostname ($diroutbase): skipping: *** DEVICE IS ONROAD ***"
    return
  }
  $dirout = "$diroutbase/$DONGLEID"

  $devicedirin = "/data/media/0/realdata"
  $i = 1
  $r = 1
  $iter = 0
  $tot = 0
  $r_old = 0
  while (($i -gt 0) -or ($r -ne $r_old)) {
    $r_old = $r
    $i = 0
    $r = 0
    $iter++

    Write-Host "$devicehostname ($diroutbase): Starting copy of rlogs from device (dongleid $DONGLEID; iteration $iter) to $dirout"

    Write-Host "$devicehostname ($diroutbase): Fetching list of candidate files to be transferred"
    $remotefilelist = sshCommand($devicehostname, "`"nice -19 find '$devicedirin' -name '*rlog*' -printf '%T@ %Tc ;;%p\n' | sort -n | sed 's/.*;;//'`"")
    #$remotefilelist = sshCommand($devicehostname, "`"nice -19 find '$devicedirin' -name '*rlog*' | sort -n | sed 's/.*;;//'`"")
    if ($LASTEXITCODE -eq 0) {
      New-Item -ItemType Directory -Force -Path "$dirout" | Out-Null
    }

    Write-Host "$devicehostname ($diroutbase): Check for duplicate files"

    $fileliststr = @"
"@
    foreach ($f in $remotefilelist) {
      $fstr = $f.Replace($devicedirin + '/', '')
      if ($fstr.EndsWith('.lock')) {
        Write-Host "Lock file ignore. -> $f"
        continue
      } elseif ($fstr.EndsWith('.bz2')) {
        $route = $fstr.Replace('/rlog.bz2', '')
      } else {
        $route = $fstr.Replace('/rlog', '')
      }
      $ext = $fstr.Replace($route + '/', '')
      $lfn = "$dirout/$DONGLEID`_$route`--$ext"
      $lfnbase = "$dirout/$DONGLEID`_$route`--rlog"

      if (($null -ne $check_list -and $check_list.Contains($route)) -or (Test-Path $lfnbase) -or (Test-Path ($lfnbase + '.bz2'))) {
        $fileliststr += "get -a `"$f`" `"$lfn`"`n"
        $r++
      } else {
        $fileliststr += "get `"$f`" `"$lfn`"`n"
        $i++
      }
    }

    if ($r -eq $r_old) {
      return 0
    }

    Write-Host "$devicehostname ($diroutbase): Total transfers: $($i + $r) = $i new + $r resumed"
    $tot += $i

    if ($i -gt 0 -or ($r -gt 0 -and $r -ne $r_old)) {
      Write-Host "$devicehostname ($diroutbase): Beginning transfer"
      $sftpCommandStr = @"
        $fileliststr
"@
      sftpCommand $devicehostname $sftpCommandStr
      Write-Host "$devicehostname ($diroutbase): Transfer complete (returned $($LASTEXITCODE))"
    }
  }
  return 0
}

function collect($basePath) {
  $diroutbase = "scratch-video/"
  $check_dir = "$diroutbase/rlogs"
  $configName = "$basePath/config.xml"
  
  New-Item -ItemType Directory -Path $diroutbase -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Path $check_dir -ErrorAction SilentlyContinue
  
  Set-Location $check_dir
  $check_list = Get-ChildItem -Recurse -Include "*rlog*" -File | ForEach-Object { $_.FullName }
  
  # Write-Host $check_list
  $xml = [xml](Get-Content $configName)
  $serverName = $xml.settings.ServerName
  $userName = $xml.settings.UserName
  $storeName = $xml.settings.storeName
  
  $device_car_list = @( 
    "$userName@$serverName $storeName"
  )
  
  foreach ($d in $device_car_list) {
    Write-Host "Beginning device rlog fetch for $d"
    $device, $car = $d.Split(' ')
    fetch-rlogs $check_list $device $car
    Start-Sleep -Seconds 1
  }
  
  Write-Host "zipping any unzipped rlogs"
  
  $storagePath = "$basePath/$check_dir/*"
  $resultPath = "$basePath/output"
  make_archive $storagePath $resultPath
  Write-Host "Done"  
}

function make_archive($storagePath, $resultPath) {
  New-Item -ItemType Directory -Path $resultPath -ErrorAction SilentlyContinue
  Compress-Archive -Force -Path $storagePath -DestinationPath "$resultPath/rlogs.zip"
}

function welcome() {
  Write-Host "Welcome to the openpilot rlog fetcher" -BackgroundColor Blue -ForegroundColor Yellow
  Write-Host "modified by turboce (originally from twilsonco)" -BackgroundColor Blue -ForegroundColor Yellow
  Write-Host $result
}

welcome
collect $basePath

Pop-Location