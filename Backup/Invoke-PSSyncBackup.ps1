<#
    Invoke-PSSyncBackup.ps1

    What it does:
        Nightly mirrored backup of the configured source drives (D:\ and E:\)
        to folders on the NAS SMB share, using the PSSync module from this
        repository. Intended to be run by the scheduled task, not as the
        everyday interactive PSSync command.

    Passed in:
        -WhatIf     PowerShell's built-in preview: PSSync runs with -WhatIf
                    and nothing on the NAS is changed. Outlook is not closed.
        -ConfigDirectory  Folder holding Backup.Settings.psd1 and the two
                          encrypted credential files. Defaults to the Config
                          folder beside this script (ignored by Git). The
                          scheduled task passes the folder it was registered
                          with, for example a folder in a synced cloud drive.

    Passed out:
        Exit code 0 when every job succeeded, 1 when anything failed.
        A live log named PSSyncBackup-<yyyyMMdd-HHmmss>.log in the Nextcloud
        archive (NextcloudArchiveRoot\LogDirectory, default ...\Logs), so a
        run can be watched from any device that syncs that folder.

    Live logging:
        Every line is shown on the console immediately and appended to the
        Nextcloud log at least every LogFlushSeconds (default 10). Job
        start/end, errors, failures, and the start of a transfer or
        verification of any file of LARGE_FILE_BYTES or more are written
        immediately. Large transfers also log a PROGRESS line about every
        10 seconds. Writing in short bursts instead of on every single line
        gives the Nextcloud client quiet moments in which to upload the file.

        If the Nextcloud log cannot be created, or cannot be written for
        several flushes in a row, logging continues in
        the Logs folder beside this script and that log is copied to the
        Nextcloud log folder as PSSyncBackup-<timestamp>.local.log at the end.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigDirectory = (Join-Path $PSScriptRoot 'Config')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
    -WhatIf is PowerShell's built-in switch. Remember it for PSSync and the
    Outlook step, then turn it off for this script's own housekeeping, so
    the log file, script archive, and NAS drive mapping still work in a
    preview run.
#>
$Preview = [bool]$WhatIfPreference
$WhatIfPreference = $false

$DEFAULT_LOG_FLUSH_SECONDS = 10
$DEFAULT_LOG_RETENTION_DAYS = 10
$OUTLOOK_CLOSE_SECONDS = 120
$LARGE_FILE_BYTES = 100MB
$LOG_WRITE_ATTEMPTS = 5
$LOG_FAILURES_BEFORE_FALLBACK = 6
$IMPORTANT_LOG_PATTERN = 'START JOB:|END JOB:|FAILURE|ERROR:|All configured PSSync jobs completed'
$TRANSFER_START_PATTERN = '^(?:COPYING|UPDATING|VERIFYING): .* \((\d+) bytes\)$'
$VERBOSE_KEEP_PATTERN = '^(?:COPYING|UPDATING|VERIFYING|PROGRESS):'
$SCAN_PROGRESS_PATTERN = '^PROGRESS: (?:Enumerated|Analyzed) '
$SCAN_PROGRESS_SECONDS = 10

$ConfigRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ConfigDirectory)
$LocalLogDirectory = Join-Path $PSScriptRoot 'Logs'
$SettingsPath = Join-Path $ConfigRoot 'Backup.Settings.psd1'
$DefaultNasCredentialPath = Join-Path $ConfigRoot 'nas-credential.xml'
$PSSyncModulePath = Join-Path $PSScriptRoot '..\PSSync.psm1'
$DefaultExclusionFilePath = Join-Path $PSScriptRoot 'PSSyncBackup.Exclusions.txt'
$Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$LogFileName = "PSSyncBackup-$Timestamp.log"
$Settings = $null
$LogPath = $null
$LogIsLocalFallback = $false
$LogWriteFailures = 0
$LogFlushSeconds = $DEFAULT_LOG_FLUSH_SECONDS
$LastLogFlush = Get-Date
$PendingLogLines = New-Object 'System.Collections.Generic.List[string]'
$LogEncoding = New-Object System.Text.UTF8Encoding($false)
$TaskResults = New-Object 'System.Collections.Generic.List[object]'
$HadFailure = $false
$NasDriveName = 'PSSyncNAS'
$NasDriveCreated = $false
$DeleteExcludedEnabled = $false

<#
    Get-ArchiveLogDirectory

    What it does:
        Works out the Nextcloud folder that holds the backup logs.

    Passed in:
        Nothing. Uses $script:Settings (NextcloudArchiveRoot, LogDirectory).
        LogDirectory may be a full path, or a folder name under
        NextcloudArchiveRoot. It defaults to 'Logs'.

    Passed out:
        The folder path, or an empty string when no Nextcloud archive root
        is configured.
#>
function Get-ArchiveLogDirectory
{
    if ($null -eq $script:Settings)
    {
        return ''
    }

    $ArchiveRoot = [string]$script:Settings.NextcloudArchiveRoot
    if ([string]::IsNullOrWhiteSpace($ArchiveRoot))
    {
        return ''
    }

    $LogDirectoryName = 'Logs'
    if ($script:Settings.ContainsKey('LogDirectory') -and -not [string]::IsNullOrWhiteSpace([string]$script:Settings.LogDirectory))
    {
        $LogDirectoryName = [string]$script:Settings.LogDirectory
    }

    if ([System.IO.Path]::IsPathRooted($LogDirectoryName))
    {
        return $LogDirectoryName
    }

    return (Join-Path $ArchiveRoot $LogDirectoryName)
}

<#
    New-BackupLogFile

    What it does:
        Creates the log folder if needed and an empty log file for this run.

    Passed in:
        -Directory   Folder to hold the log.

    Passed out:
        Full path of the log file. Throws if the folder or file cannot be
        created.
#>
function New-BackupLogFile
{
    param(
        [Parameter(Mandatory = $true)][string]$Directory
    )

    New-Item -ItemType Directory -Path $Directory -Force -ErrorAction Stop | Out-Null
    $NewLogPath = Join-Path $Directory $script:LogFileName
    if (-not (Test-Path -LiteralPath $NewLogPath -PathType Leaf))
    {
        New-Item -ItemType File -Path $NewLogPath -Force -ErrorAction Stop | Out-Null
    }

    return $NewLogPath
}

<#
    Initialize-BackupLog

    What it does:
        Chooses where this run logs. The Nextcloud log folder is used when
        it is configured and can be written; otherwise the local log folder.
        Also reads the optional LogFlushSeconds setting.

    Passed in:
        Nothing. Uses $script:Settings.

    Passed out:
        Nothing. Sets $script:LogPath and $script:LogIsLocalFallback.
#>
function Initialize-BackupLog
{
    if ($null -ne $script:Settings -and $script:Settings.ContainsKey('LogFlushSeconds'))
    {
        $script:LogFlushSeconds = [Math]::Max(1, [int]$script:Settings.LogFlushSeconds)
    }

    $ArchiveLogDirectory = Get-ArchiveLogDirectory
    if (-not [string]::IsNullOrWhiteSpace($ArchiveLogDirectory))
    {
        try
        {
            $script:LogPath = New-BackupLogFile -Directory $ArchiveLogDirectory
            $script:LogIsLocalFallback = $false
            return
        }
        catch
        {
            Write-Host ('WARNING: Could not create the Nextcloud log in {0}; logging locally: {1}' -f $ArchiveLogDirectory, $_.Exception.Message)
        }
    }

    $script:LogPath = New-BackupLogFile -Directory $script:LocalLogDirectory
    $script:LogIsLocalFallback = $true
}

<#
    Write-BackupLog

    What it does:
        Timestamps a message, shows it on the console, and queues it for the
        log file. The queue is written out when the flush interval has passed,
        when -Flush is given, when the message is important (job start/end,
        errors, failures), or when a large file transfer or verification is
        starting.

    Passed in:
        -Message   Text to log.
        -Flush     Write the queue to the log file now.

    Passed out:
        Nothing.
#>
function Write-BackupLog
{
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message,
        [switch]$Flush
    )

    $Line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Message
    Write-Host $Line
    $script:PendingLogLines.Add($Line)

    $FlushNow = $Flush -or ($Message -match $script:IMPORTANT_LOG_PATTERN)
    if (-not $FlushNow -and $Message -match $script:TRANSFER_START_PATTERN)
    {
        $FlushNow = ([int64]$Matches[1] -ge $script:LARGE_FILE_BYTES)
    }

    if ($FlushNow -or ((Get-Date) - $script:LastLogFlush).TotalSeconds -ge $script:LogFlushSeconds)
    {
        Save-BackupLog
    }
}

<#
    Save-BackupLog

    What it does:
        Appends all queued lines to the log file. The file is opened, written
        and closed each time, and shared for read/write/delete, so the
        Nextcloud client (or anyone viewing the log) is never locked out.
        If the file is busy, the write is retried a few times; if it still
        fails the lines stay queued for the next flush. After several failed
        flushes in a row the log switches to the local log folder.

    Passed in:
        Nothing. Uses $script:PendingLogLines and $script:LogPath.

    Passed out:
        Nothing. Clears $script:PendingLogLines on success.
#>
function Save-BackupLog
{
    $script:LastLogFlush = Get-Date
    if ($script:PendingLogLines.Count -eq 0 -or $null -eq $script:LogPath)
    {
        return
    }

    $Text = ($script:PendingLogLines -join [Environment]::NewLine) + [Environment]::NewLine
    $Bytes = $script:LogEncoding.GetBytes($Text)
    $LastError = ''

    for ($lp = 1; $lp -le $script:LOG_WRITE_ATTEMPTS; $lp = $lp + 1)
    {
        $Stream = $null
        try
        {
            $Stream = [System.IO.FileStream]::new(
                $script:LogPath,
                [System.IO.FileMode]::Append,
                [System.IO.FileAccess]::Write,
                ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
            )
            $Stream.Write($Bytes, 0, $Bytes.Length)
            $Stream.Flush()
            $script:PendingLogLines.Clear()
            $script:LogWriteFailures = 0
            return
        }
        catch
        {
            $LastError = $_.Exception.Message
            Start-Sleep -Milliseconds 200
        }
        finally
        {
            if ($null -ne $Stream)
            {
                $Stream.Dispose()
            }
        }
    }

    $script:LogWriteFailures = $script:LogWriteFailures + 1
    Write-Host ('WARNING: Could not write the log file {0} ({1} failed flushes); {2} lines held for retry: {3}' -f $script:LogPath, $script:LogWriteFailures, $script:PendingLogLines.Count, $LastError)

    if (-not $script:LogIsLocalFallback -and $script:LogWriteFailures -ge $script:LOG_FAILURES_BEFORE_FALLBACK)
    {
        Switch-BackupLogToLocal
    }
}

<#
    Switch-BackupLogToLocal

    What it does:
        Moves logging from the Nextcloud log to a local log after repeated
        write failures. Lines already written stay in the Nextcloud log;
        queued and later lines go to the local log, which is copied to
        Nextcloud at the end of the run when possible.

    Passed in:
        Nothing.

    Passed out:
        Nothing. Updates $script:LogPath and $script:LogIsLocalFallback.
#>
function Switch-BackupLogToLocal
{
    $FailedLogPath = $script:LogPath
    try
    {
        $script:LogPath = New-BackupLogFile -Directory $script:LocalLogDirectory
        $script:LogIsLocalFallback = $true
        $script:LogWriteFailures = 0
        $Line = '{0} WARNING: Could not write the Nextcloud log {1}; continuing in the local log {2}.' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $FailedLogPath, $script:LogPath
        Write-Host $Line
        $script:PendingLogLines.Insert(0, $Line)
        Save-BackupLog
    }
    catch
    {
        $script:LogPath = $FailedLogPath
        Write-Host ('WARNING: Could not create the local fallback log: {0}' -f $_.Exception.Message)
    }
}

<#
    Copy-LocalLogToNextcloud

    What it does:
        When this run logged locally, copies that log to the Nextcloud log
        folder as PSSyncBackup-<timestamp>.local.log, so it never overwrites
        a partial Nextcloud log of the same run.

    Passed in:
        Nothing.

    Passed out:
        Nothing. Throws if the copy fails.
#>
function Copy-LocalLogToNextcloud
{
    if (-not $script:LogIsLocalFallback -or $null -eq $script:LogPath)
    {
        return
    }

    $ArchiveLogDirectory = Get-ArchiveLogDirectory
    if ([string]::IsNullOrWhiteSpace($ArchiveLogDirectory))
    {
        return
    }

    New-Item -ItemType Directory -Path $ArchiveLogDirectory -Force -ErrorAction Stop | Out-Null
    $ArchiveCopyPath = Join-Path $ArchiveLogDirectory ($script:LogFileName -replace '\.log$', '.local.log')
    Copy-Item -LiteralPath $script:LogPath -Destination $ArchiveCopyPath -Force -ErrorAction Stop
}

<#
    Remove-OldBackupLogs

    What it does:
        Deletes PSSyncBackup-*.log files older than the retention period.

    Passed in:
        -Directory       Log folder to clean. Ignored if blank or missing.
        -RetentionDays   Age in days after which a log is removed.

    Passed out:
        Nothing. Errors are ignored.
#>
function Remove-OldBackupLogs
{
    param(
        [AllowEmptyString()][string]$Directory,
        [Parameter(Mandatory = $true)][int]$RetentionDays
    )

    if ([string]::IsNullOrWhiteSpace($Directory) -or -not (Test-Path -LiteralPath $Directory -PathType Container))
    {
        return
    }

    Get-ChildItem -LiteralPath $Directory -Filter 'PSSyncBackup-*.log' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$RetentionDays) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

<#
    ConvertTo-BackupMessage

    What it does:
        Turns one record from PSSync's merged output streams into log text.
        Verbose records are kept only for the transfer messages the backup
        wants (COPYING, UPDATING, VERIFYING, PROGRESS); other verbose chatter
        from cmdlets such as New-Item and Remove-Item is dropped.

    Passed in:
        -Record   Information, verbose, error, or other output record.

    Passed out:
        The message text, or an empty string for records to skip.
#>
function ConvertTo-BackupMessage
{
    param(
        [Parameter(Mandatory = $true)][object]$Record
    )

    if ($Record -is [System.Management.Automation.InformationRecord])
    {
        if ($Record.MessageData -is [System.Management.Automation.HostInformationMessage])
        {
            return [string]$Record.MessageData.Message
        }
        return [string]$Record.MessageData
    }

    if ($Record -is [System.Management.Automation.VerboseRecord])
    {
        if ($Record.Message -match $script:VERBOSE_KEEP_PATTERN)
        {
            return [string]$Record.Message
        }
        return ''
    }

    return [string]$Record
}

<#
    Invoke-BackupJob

    What it does:
        Runs PSSync for one source/destination pair, logging every message as
        it arrives, and collects the final summary counts.

    Passed in:
        -Job           Hashtable with Name, Source, Destination (folder name
                       under the NAS share).
        -PreviewMode   Run PSSync with -WhatIf.

    Passed out:
        Nothing returned. Adds a result object to $script:TaskResults and
        sets $script:HadFailure when the job fails.
#>
function Invoke-BackupJob
{
    param(
        [Parameter(Mandatory = $true)][hashtable]$Job,
        [Parameter(Mandatory = $true)][switch]$PreviewMode
    )

    $DestinationPath = '{0}:\{1}' -f $script:NasDriveName, $Job.Destination
    $Status = 'Succeeded'
    $RunSummary = [PSCustomObject]@{
        FoundSummary = $false
        Errors = 0
        DeferredFiles = 0
        Copied = 0
        Updated = 0
        DeletedFiles = 0
        DeletedDirectories = 0
        DeletedExcluded = 0
    }

    <#
        PSSync reports scan and analysis progress every 100 items. Only one
        of those lines is logged every SCAN_PROGRESS_SECONDS, which keeps the
        log readable and small; every change line is still logged.
    #>
    $LastScanProgress = [datetime]::MinValue

    Write-BackupLog ('START JOB: {0}; Source={1}; Destination={2}' -f $Job.Name, $Job.Source, $DestinationPath)
    Write-BackupLog 'Mirror mode is ON: destination-only files and directories will be deleted during a live run.'

    try
    {
        if (-not (Test-Path -LiteralPath $Job.Source -PathType Container))
        {
            throw "Source directory is unavailable: $($Job.Source)"
        }

        if (-not (Test-Path -LiteralPath $DestinationPath -PathType Container))
        {
            throw "NAS destination folder is unavailable: $DestinationPath"
        }

        <#
            -Verbose turns on PSSync's COPYING / PROGRESS / VERIFYING lines.
            They are only produced when asked for, so ordinary interactive
            PSSync runs are unchanged.
        #>
        <#
            -DeleteExcluded (setting DeleteExcluded = $true) also removes NAS
            copies of anything that matches the exclusion file.
        #>
        $PSSyncParameters = @{
            Source = $Job.Source
            Destination = $DestinationPath
            Mirror = $true
            ChangesOnly = $true
            ExcludeFrom = $script:ExclusionFilePath
            DeleteExcluded = $script:DeleteExcludedEnabled
            Verbose = $true
            WhatIf = [bool]$PreviewMode
        }

        PSSync @PSSyncParameters *>&1 | ForEach-Object `
        {
            $Message = ConvertTo-BackupMessage -Record $_
            if (-not [string]::IsNullOrWhiteSpace($Message))
            {
                if ($Message -match '^Errors:\s*(\d+)\s*$')
                {
                    $RunSummary.FoundSummary = $true
                    $RunSummary.Errors = [int]$Matches[1]
                }
                elseif ($Message -match '^(?:Deferred Files|Would Defer Transient):\s*(\d+)\s*$')
                {
                    $RunSummary.DeferredFiles = [int]$Matches[1]
                }
                elseif ($Message -match '^Copied:\s*(\d+)\s*$')
                {
                    $RunSummary.Copied = [int]$Matches[1]
                }
                elseif ($Message -match '^Updated:\s*(\d+)\s*$')
                {
                    $RunSummary.Updated = [int]$Matches[1]
                }
                elseif ($Message -match '^Deleted Files:\s*(\d+)\s*$')
                {
                    $RunSummary.DeletedFiles = [int]$Matches[1]
                }
                elseif ($Message -match '^(?:Deleted Excluded|Would Delete Excluded):\s*(\d+)\s*$')
                {
                    $RunSummary.DeletedExcluded = [int]$Matches[1]
                }
                elseif ($Message -match '^Deleted Directories:\s*(\d+)\s*$')
                {
                    $RunSummary.DeletedDirectories = [int]$Matches[1]
                }

                <#
                    COPYING / UPDATING / VERIFYING lines are only logged for
                    large files, where the transfer takes long enough to be
                    worth watching; small files just get their COPIED line.
                #>
                if ($Message -match $script:TRANSFER_START_PATTERN -and [int64]$Matches[1] -lt $script:LARGE_FILE_BYTES)
                {
                    return
                }

                if ($Message -match $script:SCAN_PROGRESS_PATTERN)
                {
                    if (((Get-Date) - $LastScanProgress).TotalSeconds -lt $script:SCAN_PROGRESS_SECONDS)
                    {
                        return
                    }
                    $LastScanProgress = Get-Date
                }

                Write-BackupLog $Message
            }
        }

        if (-not $PreviewMode -and -not $RunSummary.FoundSummary)
        {
            throw 'PSSync returned without its final error summary; marking this job failed.'
        }

        if ($RunSummary.Errors -gt 0)
        {
            throw "PSSync reported $($RunSummary.Errors) file-system or verification error(s)."
        }
    }
    catch
    {
        $Status = 'Failed'
        $script:HadFailure = $true
        Write-BackupLog ('JOB FAILURE: {0}: {1}' -f $Job.Name, $_.Exception.Message)
    }

    $Result = [PSCustomObject]@{
        Name = $Job.Name
        Source = $Job.Source
        Destination = $DestinationPath
        Status = $Status
        Errors = $RunSummary.Errors
        DeferredFiles = $RunSummary.DeferredFiles
        Copied = $RunSummary.Copied
        Updated = $RunSummary.Updated
        DeletedFiles = $RunSummary.DeletedFiles
        DeletedDirectories = $RunSummary.DeletedDirectories
        DeletedExcluded = $RunSummary.DeletedExcluded
    }

    $script:TaskResults.Add($Result)
    Write-BackupLog ('END JOB: {0}; Status={1}; Copied={2}; Updated={3}; DeletedFiles={4}; DeletedExcluded={5}; PSSyncErrors={6}; DeferredTransientFiles={7}' -f $Result.Name, $Result.Status, $Result.Copied, $Result.Updated, $Result.DeletedFiles, $Result.DeletedExcluded, $Result.Errors, $Result.DeferredFiles)
}

<#
    Get-EmailSetupProblems

    What it does:
        Checks that the failure email has been set up, so a new user who
        copied the example settings finds out at once, not on the night a
        backup fails. Checks that SmtpServer, From and To are filled in and
        are not the example placeholders (example.com), and that the SMTP
        credential file exists when one is configured.

    Passed in:
        -EmailSettings   The Email hashtable from the settings file (or $null).
        -ConfigRoot      Folder holding the credential file.

    Passed out:
        A list of problem descriptions; empty when email is set up.
#>
function Get-EmailSetupProblems
{
    param(
        [AllowNull()][object]$EmailSettings,
        [Parameter(Mandatory = $true)][string]$ConfigRoot
    )

    $Problems = New-Object 'System.Collections.Generic.List[string]'
    if ($null -eq $EmailSettings)
    {
        $Problems.Add('the Email section is missing from the settings file')
        return $Problems
    }

    foreach ($SettingName in @('SmtpServer', 'From', 'To'))
    {
        $Value = [string]$EmailSettings[$SettingName]
        if ([string]::IsNullOrWhiteSpace($Value))
        {
            $Problems.Add(('Email.{0} is empty' -f $SettingName))
        }
        elseif ($Value -match 'example\.com')
        {
            $Problems.Add(('Email.{0} is still the example value ({1})' -f $SettingName, $Value))
        }
    }

    $CredentialName = [string]$EmailSettings['CredentialFile']
    if (-not [string]::IsNullOrWhiteSpace($CredentialName))
    {
        $CredentialPath = Join-Path $ConfigRoot $CredentialName
        if (-not (Test-Path -LiteralPath $CredentialPath -PathType Leaf))
        {
            $Problems.Add(('the SMTP credential file is missing: {0}' -f $CredentialPath))
        }
    }

    return $Problems
}

function Send-FailureEmail {
    param(
        [Parameter(Mandatory = $true)][hashtable]$EmailSettings,
        [Parameter(Mandatory = $true)][string]$TranscriptPath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Results
    )

    $Smtp = $null
    $Message = $null
    $Attachment = $null
    $ArchivePath = Join-Path $env:TEMP ((Split-Path -Leaf $TranscriptPath) + '.zip')

    try {
        if ([string]::IsNullOrWhiteSpace([string]$EmailSettings.SmtpServer) -or
            [string]::IsNullOrWhiteSpace([string]$EmailSettings.From) -or
            [string]::IsNullOrWhiteSpace([string]$EmailSettings.To)) {
            throw 'Email settings are incomplete. Configure SmtpServer, From, and To in Backup.Settings.psd1.'
        }

        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $Smtp = [System.Net.Mail.SmtpClient]::new([string]$EmailSettings.SmtpServer, [int]$EmailSettings.Port)
        $Smtp.EnableSsl = [bool]$EmailSettings.UseSsl
        $Smtp.DeliveryMethod = [System.Net.Mail.SmtpDeliveryMethod]::Network
        $Smtp.UseDefaultCredentials = $false
        $Smtp.Timeout = 30000

        $EmailCredentialName = [string]$EmailSettings.CredentialFile
        if (-not [string]::IsNullOrWhiteSpace($EmailCredentialName)) {
            $EmailCredentialPath = Join-Path $script:ConfigRoot $EmailCredentialName
            if (-not (Test-Path -LiteralPath $EmailCredentialPath -PathType Leaf)) {
                throw "SMTP credential file is configured but missing: $EmailCredentialPath"
            }
            $EmailCredential = Import-Clixml -LiteralPath $EmailCredentialPath
            $Smtp.Credentials = $EmailCredential.GetNetworkCredential()
        }

        $Message = New-Object System.Net.Mail.MailMessage
        $Message.From = [System.Net.Mail.MailAddress]::new([string]$EmailSettings.From)
        foreach ($Recipient in ([string]$EmailSettings.To -split '[;,]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
            [void]$Message.To.Add($Recipient)
        }

        $SubjectPrefix = [string]$EmailSettings.SubjectPrefix
        if ([string]::IsNullOrWhiteSpace($SubjectPrefix)) {
            $SubjectPrefix = 'PSSync backup FAILED'
        }
        $Message.Subject = '{0} - {1}' -f $SubjectPrefix, (Get-Date -Format 'yyyy-MM-dd HH:mm')
        $ResultLines = foreach ($Result in $Results) {
            'Job: {0}; Status: {1}; Copied: {2}; Updated: {3}; Deleted files: {4}; Deleted directories: {5}; Errors: {6}; Source: {7}; Destination: {8}' -f `
                $Result.Name, $Result.Status, $Result.Copied, $Result.Updated, $Result.DeletedFiles, `
                $Result.DeletedDirectories, $Result.Errors, $Result.Source, $Result.Destination
        }
        $Message.Body = @(
            'The scheduled PSSync backup reported a failure.'
            ''
            $ResultLines
            ''
            "Full log attached: $TranscriptPath"
        ) -join [Environment]::NewLine

        $AttachmentPath = $TranscriptPath
        try {
            Compress-Archive -LiteralPath $TranscriptPath -DestinationPath $ArchivePath -CompressionLevel Optimal -Force -ErrorAction Stop
            $AttachmentPath = $ArchivePath
        }
        catch {
            $AttachmentPath = $TranscriptPath
        }

        $Attachment = [System.Net.Mail.Attachment]::new($AttachmentPath)
        [void]$Message.Attachments.Add($Attachment)
        $Smtp.Send($Message)
    }
    finally {
        if ($null -ne $Message) { $Message.Dispose() }
        if ($null -ne $Smtp) { $Smtp.Dispose() }
        if (Test-Path -LiteralPath $ArchivePath) {
            Remove-Item -LiteralPath $ArchivePath -Force -ErrorAction SilentlyContinue
        }
    }
}

<#
    Close-OutlookClassic

    What it does:
        Closes classic Outlook (OUTLOOK.EXE) before the backup so its PST
        files are not changing while they are copied. The new Outlook app
        (olk.exe) does not use PST files and is left alone.

        Each Outlook process is first asked to close normally (the same as
        clicking the X). If it is still running after OUTLOOK_CLOSE_SECONDS,
        for example because a dialog is open or the task is running in a
        different Windows session from Outlook, it is ended forcefully and
        that is logged as a warning.

        In Preview mode nothing is closed; the log only says what would
        happen.

    Passed in:
        -PreviewMode   Log only; do not close Outlook.

    Passed out:
        Nothing. Every step is written to the backup log. A failure to
        close Outlook is logged but does not stop the backup; any PST
        that then changes during the copy is reported by PSSync as usual.
#>
function Close-OutlookClassic
{
    param(
        [Parameter(Mandatory = $true)][switch]$PreviewMode
    )

    $OutlookProcesses = @(Get-Process -Name 'OUTLOOK' -ErrorAction SilentlyContinue)
    if ($OutlookProcesses.Count -eq 0)
    {
        Write-BackupLog 'Classic Outlook is not running.'
        return
    }

    if ($PreviewMode)
    {
        Write-BackupLog ('Classic Outlook is running ({0} process(es)); a live run would close it before the backup.' -f $OutlookProcesses.Count)
        return
    }

    Write-BackupLog ('Classic Outlook is running ({0} process(es)); asking it to close so PST files are not in use.' -f $OutlookProcesses.Count)
    foreach ($OutlookProcess in $OutlookProcesses)
    {
        try
        {
            if (-not $OutlookProcess.CloseMainWindow())
            {
                Write-BackupLog ('Outlook process {0} has no window in this session; it cannot be asked to close normally.' -f $OutlookProcess.Id)
            }
        }
        catch
        {
            Write-BackupLog ('Outlook process {0} could not be asked to close: {1}' -f $OutlookProcess.Id, $_.Exception.Message)
        }
    }

    foreach ($OutlookProcess in $OutlookProcesses)
    {
        try
        {
            if ($OutlookProcess.WaitForExit($script:OUTLOOK_CLOSE_SECONDS * 1000))
            {
                Write-BackupLog ('Outlook process {0} closed normally.' -f $OutlookProcess.Id)
                continue
            }

            Write-BackupLog ('WARNING: Outlook process {0} did not close within {1} seconds; ending it forcefully.' -f $OutlookProcess.Id, $script:OUTLOOK_CLOSE_SECONDS) -Flush
            Stop-Process -Id $OutlookProcess.Id -Force -ErrorAction Stop
            [void]$OutlookProcess.WaitForExit(30000)
            Write-BackupLog ('Outlook process {0} was ended forcefully.' -f $OutlookProcess.Id)
        }
        catch
        {
            Write-BackupLog ('WARNING: Could not close Outlook process {0}: {1}' -f $OutlookProcess.Id, $_.Exception.Message) -Flush
        }
    }

    <#
        Give Outlook's PST handles a moment to be released after exit.
    #>
    Start-Sleep -Seconds 5
}

function Copy-ScriptsToNextcloud {
    param([Parameter(Mandatory = $true)][string]$ArchiveRoot)

    $ArchiveScriptRoot = Join-Path $ArchiveRoot 'Scripts'
    $ArchiveBackupDirectory = Join-Path $ArchiveScriptRoot 'Backup'
    New-Item -ItemType Directory -Path $ArchiveBackupDirectory -Force | Out-Null

    $RepositoryRoot = Split-Path -Parent $PSScriptRoot
    Get-ChildItem -LiteralPath $PSScriptRoot -File -ErrorAction Stop | Copy-Item -Destination $ArchiveBackupDirectory -Force -ErrorAction Stop
    Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'PSSync.psm1') -Destination $ArchiveScriptRoot -Force -ErrorAction Stop
    Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'PSSync.psd1') -Destination $ArchiveScriptRoot -Force -ErrorAction Stop
}

<#
    Main body

    Loads the settings, opens the live log, archives the scripts, maps the
    NAS, and runs each configured job. Failures are logged and reported by
    email in the finally block.
#>
try
{
    if (-not (Test-Path -LiteralPath $SettingsPath -PathType Leaf))
    {
        throw "Settings file is missing: $SettingsPath. Copy Backup\PSSyncBackup.Settings.example.psd1 there as Backup.Settings.psd1 and edit it (see Setup in Backup\README.md)."
    }

    $Settings = Import-PowerShellDataFile -Path $SettingsPath
    Initialize-BackupLog
    $NextcloudArchiveRoot = [string]$Settings.NextcloudArchiveRoot

    Write-BackupLog 'PSSync Windows backup started.'
    Write-BackupLog ('Run mode: {0}' -f $(if ($Preview) { 'Preview (WhatIf)' } else { 'Live' }))
    Write-BackupLog ('Windows task account: {0}\{1}' -f $env:USERDOMAIN, $env:USERNAME)
    Write-BackupLog ('NAS share root: {0}' -f $Settings.NasShareRoot)
    Write-BackupLog ('Local PSSync module: {0}' -f (Resolve-Path -LiteralPath $PSSyncModulePath).Path)

    $ExclusionFileName = if ($Settings.ContainsKey('ExclusionFile')) { [string]$Settings.ExclusionFile } else { '' }
    if ([string]::IsNullOrWhiteSpace($ExclusionFileName)) {
        $script:ExclusionFilePath = $DefaultExclusionFilePath
    }
    elseif ([System.IO.Path]::IsPathRooted($ExclusionFileName)) {
        $script:ExclusionFilePath = $ExclusionFileName
    }
    else {
        $script:ExclusionFilePath = Join-Path $PSScriptRoot $ExclusionFileName
    }
    if (-not (Test-Path -LiteralPath $script:ExclusionFilePath -PathType Leaf)) {
        throw "PSSync exclusion file is missing: $script:ExclusionFilePath"
    }
    Write-BackupLog ('Exclusion file: {0}' -f $script:ExclusionFilePath)

    $script:DeleteExcludedEnabled = $Settings.ContainsKey('DeleteExcluded') -and [bool]$Settings.DeleteExcluded
    Write-BackupLog ('Delete excluded items from the NAS: {0}' -f $script:DeleteExcludedEnabled)

    $EmailProblems = @(Get-EmailSetupProblems -EmailSettings $Settings['Email'] -ConfigRoot $ConfigRoot)
    if ($EmailProblems.Count -eq 0)
    {
        Write-BackupLog ('Failure email: set up, to {0}' -f $Settings.Email.To)
    }
    else
    {
        Write-BackupLog ('WARNING: Failure email is NOT set up, so a failed backup will not be reported: {0}. See "Email setup" in Backup\README.md.' -f ($EmailProblems -join '; ')) -Flush
    }

    if (-not [string]::IsNullOrWhiteSpace($NextcloudArchiveRoot)) {
        try {
            Copy-ScriptsToNextcloud -ArchiveRoot $NextcloudArchiveRoot
            Write-BackupLog ('Script archive updated: {0}' -f (Join-Path $NextcloudArchiveRoot 'Scripts'))
        }
        catch {
            $HadFailure = $true
            Write-BackupLog ('SCRIPT ARCHIVE FAILURE: {0}' -f $_.Exception.Message)
        }
    }

    Import-Module -Name $PSSyncModulePath -Force -ErrorAction Stop

    $NasCredentialName = [string]$Settings.NasCredentialFile
    if ([string]::IsNullOrWhiteSpace($NasCredentialName)) {
        $NasCredentialPath = $DefaultNasCredentialPath
    }
    elseif ([System.IO.Path]::IsPathRooted($NasCredentialName)) {
        $NasCredentialPath = $NasCredentialName
    }
    else {
        $NasCredentialPath = Join-Path $ConfigRoot $NasCredentialName
    }

    if (-not (Test-Path -LiteralPath $NasCredentialPath -PathType Leaf)) {
        throw "Encrypted NAS credential file is missing: $NasCredentialPath"
    }

    $NasCredential = Import-Clixml -LiteralPath $NasCredentialPath
    Write-BackupLog ('Using encrypted NAS credential for account: {0}' -f $NasCredential.UserName)

    if (Get-PSDrive -Name $NasDriveName -ErrorAction SilentlyContinue) {
        Remove-PSDrive -Name $NasDriveName -Force -ErrorAction Stop
    }

    New-PSDrive -Name $NasDriveName -PSProvider FileSystem -Root ([string]$Settings.NasShareRoot) -Credential $NasCredential -Scope Global -ErrorAction Stop | Out-Null
    $NasDriveCreated = $true
    Get-ChildItem -LiteralPath ('{0}:\' -f $NasDriveName) -Force -ErrorAction Stop | Out-Null

    if (-not $Settings.ContainsKey('CloseOutlook') -or [bool]$Settings.CloseOutlook)
    {
        Close-OutlookClassic -PreviewMode:$Preview
    }

    foreach ($Job in $Settings.Jobs) {
        Invoke-BackupJob -Job $Job -PreviewMode:$Preview
    }

    if ($TaskResults.Count -ne $Settings.Jobs.Count) {
        $HadFailure = $true
        Write-BackupLog 'RUN FAILURE: One or more configured backup jobs did not produce a result.'
    }
}
catch
{
    $HadFailure = $true
    if ($null -eq $LogPath)
    {
        try
        {
            $LogPath = New-BackupLogFile -Directory $LocalLogDirectory
            $LogIsLocalFallback = $true
        }
        catch
        {
            Write-Host ('WARNING: Could not create any log file: {0}' -f $_.Exception.Message)
        }
    }
    Write-BackupLog ('RUN FAILURE: {0}' -f $_.Exception.Message)
}
finally
{
    if ($NasDriveCreated)
    {
        Remove-PSDrive -Name $NasDriveName -Force -ErrorAction SilentlyContinue
    }

    $RetentionDays = $DEFAULT_LOG_RETENTION_DAYS
    if ($null -ne $Settings -and $Settings.ContainsKey('LogRetentionDays'))
    {
        $RetentionDays = [Math]::Max(1, [int]$Settings.LogRetentionDays)
    }
    Remove-OldBackupLogs -Directory (Get-ArchiveLogDirectory) -RetentionDays $RetentionDays
    Remove-OldBackupLogs -Directory $LocalLogDirectory -RetentionDays $RetentionDays

    if ($HadFailure -and -not $Preview -and $null -ne $LogPath)
    {
        Save-BackupLog
        try
        {
            Send-FailureEmail -EmailSettings $Settings.Email -TranscriptPath $LogPath -Results $TaskResults.ToArray()
            Write-BackupLog 'Failure email sent with the full log attached.'
        }
        catch
        {
            Write-BackupLog ('EMAIL FAILURE: {0}; Detail={1}' -f $_.Exception.Message, $_.ScriptStackTrace)
        }
    }
    elseif (-not $HadFailure)
    {
        Write-BackupLog 'All configured PSSync jobs completed successfully.'
    }

    Write-BackupLog ('Log file: {0}' -f $LogPath) -Flush

    try
    {
        Copy-LocalLogToNextcloud
    }
    catch
    {
        Write-Host ('WARNING: Could not copy the local log to Nextcloud: {0}' -f $_.Exception.Message)
    }
}

if ($HadFailure)
{
    exit 1
}

exit 0
