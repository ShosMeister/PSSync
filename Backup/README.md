# PSSync nightly NAS backup

`Invoke-PSSyncBackup.ps1` mirrors one or more local drives or folders (for example `D:\` and `E:\`) to folders on a NAS SMB share, using the PSSync module in this repository. It is meant to run nightly from Task Scheduler as an emergency-restore copy of the data on one Windows PC. It is a file-level copy, not a disk image or Volume Shadow Copy backup.

Each run:

1. Closes classic Outlook, if it is running, so its PST files can be copied.
2. Maps the NAS share using an encrypted credential.
3. Runs `PSSync -Mirror` for each configured job, using the exclusion file.
4. Writes a live log to a synced cloud folder, so the run can be watched from any device.
5. Sends a failure email, with the log attached, if anything fails.

## What is stored where

Nothing personal is kept in the repository. Your own details live in a **config folder** that you choose:

- By default, `Backup\Config` beside the scripts. Git ignores this folder, so it is never committed.
- Or any folder you pass with `-ConfigDirectory`, for example a folder in a synced cloud drive (Nextcloud, OneDrive), so the settings live with the scripts and logs. The scheduled task is registered with that folder and uses it on every run.

| File in the config folder | Holds | Protected by |
|---|---|---|
| `Backup.Settings.psd1` | NAS share, job folders, log folder, email server, sender and recipient addresses | Not encrypted; keep the folder private |
| `nas-credential.xml` | NAS user name and password | Windows DPAPI encryption |
| `email-credential.xml` | SMTP login and password | Windows DPAPI encryption |

DPAPI-encrypted files can only be decrypted by the Windows account that created them, on the computer where they were created, wherever the files are stored. Create them while signed in as the account that will run the scheduled task. A copy synced to the cloud or another device cannot be decrypted there.

The repository only contains `PSSyncBackup.Settings.example.psd1`, which uses placeholder values.

### Installed from the PowerShell Gallery

`Install-Module PSSync` includes these backup scripts in a `Backup` folder inside the module. Find it with:

```powershell
Join-Path (Get-Module PSSync -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1).ModuleBase 'Backup'
```

Run the commands below from the module folder (the one that contains `Backup`) in place of the repository root. **Always pass `-ConfigDirectory` with a folder of your own**, and keep a copy of the exclusion file there if you edit it (point `ExclusionFile` at it with a full path): the module folder is replaced when PSSync is updated, so nothing you create or change inside it is kept.

## Setup

Run these from the repository root in Windows PowerShell 5.1, signed in as the account that will run the backup. First choose the config folder; the examples below use a cloud-synced folder, or leave out the first line's path to use the default `Backup\Config`:

```powershell
$ConfigRoot = 'C:\Users\YourName\Nextcloud\PSSyncBackup\Config'   # or: Join-Path (Resolve-Path .\Backup) 'Config'
New-Item -ItemType Directory -Path $ConfigRoot -Force | Out-Null
```

### 1. Create your settings file

```powershell
Copy-Item .\Backup\PSSyncBackup.Settings.example.psd1 (Join-Path $ConfigRoot 'Backup.Settings.psd1')
notepad (Join-Path $ConfigRoot 'Backup.Settings.psd1')
```

Set `NasShareRoot`, the `Jobs` (source drive or folder and the NAS destination folder name, which must already exist), and `NextcloudArchiveRoot` (any synced folder, or `''` to log only locally). Each setting is described in the file.

### 2. Save the NAS credential

The account needs read/write access to the share.

```powershell
Get-Credential -Message 'NAS user name and password' |
    Export-Clixml (Join-Path $ConfigRoot 'nas-credential.xml')
```

### 3. Email setup

The backup sends an email only when a live run fails, so it is easy to miss that it was never set up. Until it is, every run logs `WARNING: Failure email is NOT set up` with the reason, and `Register-PSSyncBackupTask.ps1` refuses to create the scheduled task.

In `Backup.Settings.psd1`, fill in the `Email` section:

| Setting | Example | Notes |
|---|---|---|
| `SmtpServer` | `smtp.gmail.com`, `smtp.office365.com`, or your ISP's server | Your email provider's outgoing (SMTP) server |
| `Port` | `587` | 587 with STARTTLS is the usual choice |
| `UseSsl` | `$true` | Leave on for port 587 |
| `From` | `backup-sender@example.com` | Usually must be the account you log in to the SMTP server with |
| `To` | `you@example.com` | One address, or several separated by `;` or `,` |
| `CredentialFile` | `email-credential.xml` | Set to `''` if your server needs no login |
| `SubjectPrefix` | `PSSync backup FAILED` | Start of the email subject |

Then save the SMTP login. Many providers (Gmail, Outlook.com, iCloud, and others with two-step sign-in) require an **app password** here, not your normal password; create one in your email account's security settings.

```powershell
Get-Credential -Message 'SMTP user name and password (or app password)' |
    Export-Clixml (Join-Path $ConfigRoot 'email-credential.xml')
```

To test the email without waiting for a failure, run this once. It sends one test message using the backup script's own email code and your settings:

```powershell
$ScriptPath = '.\Backup\Invoke-PSSyncBackup.ps1'
$Settings = Import-PowerShellDataFile (Join-Path $ConfigRoot 'Backup.Settings.psd1')
$Ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $ScriptPath), [ref]$null, [ref]$null)
. ([scriptblock]::Create($Ast.Find({ $args[0].Name -eq 'Send-FailureEmail' }, $true).Extent.Text))
$TestLog = Join-Path $env:TEMP 'PSSyncBackup-EmailTest.log'
'PSSync email test - ignore.' | Set-Content $TestLog
$TestResult = [PSCustomObject]@{ Name = 'Email test'; Status = 'Test'; Copied = 0; Updated = 0; DeletedFiles = 0; DeletedDirectories = 0; Errors = 0; Source = '-'; Destination = '-' }
Send-FailureEmail -EmailSettings $Settings.Email -TranscriptPath $TestLog -Results @($TestResult)
```

### 4. Review the exclusion file

`Backup\PSSyncBackup.Exclusions.txt` holds one rsync-style pattern per line; `#` starts a comment.

- A leading `/` anchors a pattern to the root of the drive being backed up; without it, the pattern matches at any depth.
- A trailing `/` matches directories only.
- `*` and `?` match within one path component; `**` can span components.

The supplied file skips Windows-managed folders (`System Volume Information`, `$RECYCLE.BIN`, `Config.Msi`), Microsoft Store app folders (`WindowsApps`, `WpSystem`), update and download caches, Dropbox and Nextcloud client files, Mac Finder leftovers (`.DS_Store` and similar), and Visual Studio `.vs` caches. Adjust it for your own drives.

With `DeleteExcluded = $true` in the settings, PSSync runs with `-DeleteExcluded`: NAS copies of anything that matches the exclusion file are deleted. With it off, excluded items already on the NAS are left alone. Because a wrong pattern would delete that data from the backup, run a preview after every change to the exclusion file and check the `WOULD DELETE EXCLUDED` lines.

### 5. Preview, then run

Preview with PowerShell's built-in `-WhatIf`. PSSync reads both sides and logs everything it would copy, update, or delete, but changes nothing on the NAS, and Outlook is not closed:

```powershell
.\Backup\Invoke-PSSyncBackup.ps1 -ConfigDirectory $ConfigRoot -WhatIf
```

(`-ConfigDirectory` can be left out when you use the default `Backup\Config` folder.)

When the preview looks right, run it for real:

```powershell
.\Backup\Invoke-PSSyncBackup.ps1 -ConfigDirectory $ConfigRoot
```

The first run copies everything and can take many hours; later runs only copy what changed.

### 6. Schedule it

From an elevated Windows PowerShell 5.1 window:

```powershell
.\Backup\Register-PSSyncBackupTask.ps1 -StartTime '02:00' -ConfigDirectory $ConfigRoot
```

The task passes the config folder to every run. To move the config folder later, register the task again with the new path.

The task runs only while the account that registered it is signed in (a locked screen is fine). It runs in your desktop session, so Outlook can be asked to close normally and the cloud sync client can upload the live log. No Windows password is stored with the task. If you are not signed in at the scheduled time, the run starts at your next sign-in. The task wakes the computer when supported and does not start a second copy while one is running. A PowerShell window is shown while it runs; closing it stops the backup.

## How a run behaves

**Mirroring.** Each job uses `-Mirror`: files and folders on the NAS that no longer exist in the source are deleted. Only the configured destination folders are touched.

**Verification.** Every copied or updated file is hashed with SHA-256 while it is copied, and the NAS copy is hashed and compared. A file that changes while it is being copied, or is locked by another program, is logged as deferred and retried on the next run. Unchanged files are not read.

**Outlook.** Classic Outlook (`OUTLOOK.EXE`) keeps its PST files open. Before the jobs start it is asked to close normally; if it is still running after 2 minutes (for example a dialog is open) it is ended and a warning is logged. It is not restarted afterwards. The new Outlook app (`olk.exe`) is not touched. Set `CloseOutlook = $false` to turn this off.

**Logging.** The log is written directly to `<NextcloudArchiveRoot>\Logs` as `PSSyncBackup-<yyyyMMdd-HHmmss>.log`, so it can be watched from any device that syncs that folder. Every change is logged as it happens, rsync style, and the file is updated every `LogFlushSeconds` (default 10); job start/end, errors and failures are written immediately. Scan and analysis progress is logged about every 10 seconds. For files of 100 MB or more, `COPYING`, periodic `PROGRESS`, and `VERIFYING` lines show a long transfer while it runs. If the synced folder cannot be written, logging continues in the `Backup\Logs` folder beside the scripts (ignored by Git) and that log is copied to the synced folder as `PSSyncBackup-<timestamp>.local.log` at the end. Logs are kept for `LogRetentionDays` (default 10). A copy of the scripts and module is kept under `<NextcloudArchiveRoot>\Scripts`. The cloud sync client uploads the log only while it is running, which normally means while you are signed in.

**Failures.** A job fails if PSSync reports any error, the source or NAS folder is unavailable, or a folder cannot be read. The other jobs still run. On a failed live run the failure email is sent with the zipped log attached.

## Limitations

- Windows PowerShell 5.1 cannot open paths of 260 characters or more. PSSync reports such files as errors (`Path too long`), so a too-long path makes the job fail and triggers the email instead of being skipped silently. Shorten the NAS share or destination folder names, exclude the folder, or run the backup under PowerShell 7, which supports long paths.
- Files in use with no sharing allowed are deferred to the next run; programs that keep files open all the time (other than Outlook) need to be closed or excluded.
- Installed programs cannot be restored by copying their folders back; reinstall them instead.
