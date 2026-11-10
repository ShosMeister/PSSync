[CmdletBinding()]
param(
    [ValidatePattern('^([01]\d|2[0-3]):[0-5]\d$')]
    [string]$StartTime = '02:00',

    [string]$TaskName = 'PSSync NAS Backup',

    <#
        Folder holding Backup.Settings.psd1 and the encrypted credential
        files. The task is registered to pass this folder to the backup.
    #>
    [string]$ConfigDirectory = (Join-Path $PSScriptRoot 'Config')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ConfigRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ConfigDirectory)
$SettingsPath = Join-Path $ConfigRoot 'Backup.Settings.psd1'
$NasCredentialPath = Join-Path $ConfigRoot 'nas-credential.xml'
$RunnerPath = Join-Path $PSScriptRoot 'Invoke-PSSyncBackup.ps1'
$CurrentTaskUser = '{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME

if (-not (Test-Path -LiteralPath $SettingsPath -PathType Leaf)) {
    throw "Configure the settings file first: $SettingsPath (see Setup in Backup\README.md)"
}
$LocalSettings = Import-PowerShellDataFile -Path $SettingsPath
$NasCredentialName = [string]$LocalSettings.NasCredentialFile
if ([string]::IsNullOrWhiteSpace($NasCredentialName)) {
    $NasCredentialPath = Join-Path $ConfigRoot 'nas-credential.xml'
}
elseif ([System.IO.Path]::IsPathRooted($NasCredentialName)) {
    $NasCredentialPath = $NasCredentialName
}
else {
    $NasCredentialPath = Join-Path $ConfigRoot $NasCredentialName
}
if (-not (Test-Path -LiteralPath $NasCredentialPath -PathType Leaf)) {
    throw "The encrypted NAS credential file is missing: $NasCredentialPath"
}
<#
    The failure email must be set up before the task is registered, so a
    scheduled backup can never fail silently. The checks are the same ones
    the backup itself logs at the start of every run.
#>
$BackupScriptAst = [System.Management.Automation.Language.Parser]::ParseFile($RunnerPath, [ref]$null, [ref]$null)
$EmailCheckFunction = $BackupScriptAst.Find({ param($Node) $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq 'Get-EmailSetupProblems' }, $true)
. ([scriptblock]::Create($EmailCheckFunction.Extent.Text))
$EmailProblems = @(Get-EmailSetupProblems -EmailSettings $LocalSettings['Email'] -ConfigRoot $ConfigRoot)
if ($EmailProblems.Count -gt 0)
{
    throw ('Set up the failure email before registering the task: {0}. See "Email setup" in Backup\README.md.' -f ($EmailProblems -join '; '))
}

$NextcloudArchiveRoot = [string]$LocalSettings.NextcloudArchiveRoot
if (-not [string]::IsNullOrWhiteSpace($NextcloudArchiveRoot)) {
    $RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $ArchiveScriptRoot = Join-Path $NextcloudArchiveRoot 'Scripts'
    $ArchiveBackupDirectory = Join-Path $ArchiveScriptRoot 'Backup'
    New-Item -ItemType Directory -Path $ArchiveBackupDirectory -Force | Out-Null
    Get-ChildItem -LiteralPath $PSScriptRoot -File -ErrorAction Stop | Copy-Item -Destination $ArchiveBackupDirectory -Force -ErrorAction Stop
    Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'PSSync.psm1') -Destination $ArchiveScriptRoot -Force -ErrorAction Stop
    Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'PSSync.psd1') -Destination $ArchiveScriptRoot -Force -ErrorAction Stop
}

<#
    The task runs only while this account is signed in (interactive logon),
    in the signed-in desktop session. That lets the backup ask classic
    Outlook to close normally, and lets the Nextcloud client upload the live
    log while the job runs. No Windows password is stored with the task.
    If the account is not signed in at the scheduled time, the run is
    skipped and starts at the next sign-in (StartWhenAvailable).
#>
$RegisteredUser = $CurrentTaskUser
$Principal = New-ScheduledTaskPrincipal -UserId $CurrentTaskUser -LogonType Interactive -RunLevel Highest
$PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$Action = New-ScheduledTaskAction -Execute $PowerShellExe -Argument ('-NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "{0}" -ConfigDirectory "{1}"' -f $RunnerPath, $ConfigRoot.TrimEnd([char]92))
$Trigger = New-ScheduledTaskTrigger -Daily -At ([datetime]::ParseExact($StartTime, 'HH:mm', [Globalization.CultureInfo]::InvariantCulture))
$TaskSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -WakeToRun -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 36)
$TaskDescription = 'Nightly mirrored PSSync backup of D: and E: to the NAS SMB share, with a live Nextcloud log and failure email.'

Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Settings $TaskSettings -Principal $Principal -Description $TaskDescription -Force | Out-Null

Write-Host ("Registered task '{0}' for {1} at {2} daily." -f $TaskName, $RegisteredUser, $StartTime)
if (-not [string]::IsNullOrWhiteSpace($NextcloudArchiveRoot)) {
    Write-Host ("Script copies archived under: {0}" -f (Join-Path $NextcloudArchiveRoot 'Scripts'))
}
Write-Host ("Run once interactively first: Start-ScheduledTask -TaskName '{0}'" -f $TaskName)
