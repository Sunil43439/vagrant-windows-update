# see Using the Windows Update Agent API | Searching, Downloading, and Installing Updates
#     at https://msdn.microsoft.com/en-us/library/windows/desktop/aa387102(v=vs.85).aspx
# see ISystemInformation interface
#     at https://msdn.microsoft.com/en-us/library/windows/desktop/aa386095(v=vs.85).aspx
# see IUpdateSession interface
#     at https://msdn.microsoft.com/en-us/library/windows/desktop/aa386854(v=vs.85).aspx
# see IUpdateSearcher interface
#     at https://msdn.microsoft.com/en-us/library/windows/desktop/aa386515(v=vs.85).aspx
# see IUpdateDownloader interface
#     at https://msdn.microsoft.com/en-us/library/windows/desktop/aa386131(v=vs.85).aspx
# see IUpdateCollection interface
#     at https://msdn.microsoft.com/en-us/library/windows/desktop/aa386107(v=vs.85).aspx
# see IUpdate interface
#     at https://msdn.microsoft.com/en-us/library/windows/desktop/aa386099(v=vs.85).aspx

param(
    [string[]]$Filters = @('include:$_.AutoSelectOnWebSites'),
    [int]$UpdateLimit = 100
)

$mock = $false

function ExitWithCode($exitCode) {
    $host.SetShouldExit($exitCode)
    Exit
}

Set-StrictMode -Version Latest

$ErrorActionPreference = 'Stop'

trap {
    Write-Output "ERROR: $_"
    Write-Output (($_.ScriptStackTrace -split '\r?\n') -replace '^(.*)$','ERROR: $1')
    Write-Output (($_.Exception.ToString() -split '\r?\n') -replace '^(.*)$','ERROR EXCEPTION: $1')
    ExitWithCode 1
}

if ($mock) {
    $mockWindowsUpdatePath = 'C:\Windows\Temp\windows-update-count-mock.txt'
    if (!(Test-Path $mockWindowsUpdatePath)) {
        Set-Content $mockWindowsUpdatePath 10
    }
    $count = [int]::Parse((Get-Content $mockWindowsUpdatePath).Trim())
    if ($count) {
        Write-Output "Synthetic reboot countdown counter is at $count"
        Set-Content $mockWindowsUpdatePath (--$count)
        Write-Output 'Rebooting...'
        ExitWithCode 101
    }
    Write-Output 'No Windows updates found'
    ExitWithCode 0
}

Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class Windows
{
    [DllImport("kernel32", SetLastError=true)]
    public static extern UInt64 GetTickCount64();

    public static TimeSpan GetUptime()
    {
        return TimeSpan.FromMilliseconds(GetTickCount64());
    }
}
'@

function Wait-Condition {
    param(
      [scriptblock]$Condition,
      [int]$DebounceSeconds=15
    )
    process {
        $begin = [Windows]::GetUptime()
        do {
            Start-Sleep -Seconds 1
            try {
              $result = &$Condition
            } catch {
              $result = $false
            }
            if (-not $result) {
                $begin = [Windows]::GetUptime()
                continue
            }
        } while ((([Windows]::GetUptime()) - $begin).TotalSeconds -lt $DebounceSeconds)
    }
}

function ExitWhenRebootRequired($rebootRequired = $false) {
    # check for pending Windows Updates.
    if (!$rebootRequired) {
        $systemInformation = New-Object -ComObject 'Microsoft.Update.SystemInfo'
        $rebootRequired = $systemInformation.RebootRequired
    }

    # check for pending Windows Features.
    if (!$rebootRequired) {
        $pendingPackagesKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\PackagesPending'
        $pendingPackagesCount = (Get-ChildItem -ErrorAction SilentlyContinue $pendingPackagesKey | Measure-Object).Count
        $rebootRequired = $pendingPackagesCount -gt 0
    }

    if ($rebootRequired) {
        Write-Output 'Pending Reboot detected. Waiting for the Windows Modules Installer to exit...'
        Wait-Condition {(Get-Process -ErrorAction SilentlyContinue TiWorker | Measure-Object).Count -eq 0}
        Write-Output 'Rebooting...'
        ExitWithCode 101
    }
}

ExitWhenRebootRequired

$updateFilters = $Filters | ForEach-Object {
    $action, $expression = $_ -split ':',2
    New-Object PSObject -Property @{
        Action = $action
        Expression = [ScriptBlock]::Create($expression)
    }
}

function Test-IncludeUpdate($filters, $update) {
    foreach ($filter in $filters) {
        if (Where-Object -InputObject $update $filter.Expression) {
            return $filter.Action -eq 'include'
        }
    }
    return $false
}

$updateSession = New-Object -ComObject 'Microsoft.Update.Session'
$updateSession.ClientApplicationID = 'vagrant-windows-update'

Write-Output 'Searching for Windows updates...'
$updatesToDownload = New-Object -ComObject 'Microsoft.Update.UpdateColl'
$updatesToInstall = New-Object -ComObject 'Microsoft.Update.UpdateColl'
$updateSearcher = $updateSession.CreateUpdateSearcher()
$searchResult = $updateSearcher.Search("IsInstalled=0 and Type='Software' and IsHidden=0")
$rebootRequired = $false
for ($i = 0; $i -lt $searchResult.Updates.Count; ++$i) {
    $update = $searchResult.Updates.Item($i)
    $updateDate = $update.LastDeploymentChangeTime.ToString('yyyy-MM-dd')
    $updateSize = ($update.MaxDownloadSize/1024/1024).ToString('0.##')
    $updateSummary = "Windows update ($updateDate; $updateSize MB): $($update.Title)"

    if ($update.InstallationBehavior.CanRequestUserInput) {
        Write-Output "Skipped (CanRequestUserInput) $updateSummary"
        continue
    }

    if (!(Test-IncludeUpdate $updateFilters $update)) {
        Write-Output "Skipped (filter) $updateSummary"
        continue
    }

    Write-Output "Found $updateSummary"

    $update.AcceptEula() | Out-Null

    if (!$update.IsDownloaded) {
        $updatesToDownload.Add($update) | Out-Null
    }

    $updatesToInstall.Add($update) | Out-Null
    if ($updatesToInstall.Count -ge $UpdateLimit) {
        $rebootRequired = $true
        break
    }
}

if ($updatesToDownload.Count) {
    Write-Output 'Downloading Windows updates...'
    $updateDownloader = $updateSession.CreateUpdateDownloader()
    $updateDownloader.Updates = $updatesToDownload
    $updateDownloader.Download() | Out-Null
}

if ($updatesToInstall.Count) {
    Write-Output 'Installing Windows updates...'
    $updateInstaller = $updateSession.CreateUpdateInstaller()
    $updateInstaller.Updates = $updatesToInstall
    $installResult = $updateInstaller.Install()
    ExitWhenRebootRequired ($installResult.RebootRequired -or $rebootRequired)
} else {
    Write-Output 'No Windows updates found'
}
