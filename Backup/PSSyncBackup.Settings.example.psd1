<#
    PSSync backup settings - EXAMPLE

    Copy this file to your config folder as Backup.Settings.psd1 and edit
    the copy. The config folder is Backup\Config beside the scripts (ignored
    by Git), or any folder you pass with -ConfigDirectory, for example one
    in a synced cloud drive. The copy holds your own NAS, folder, and email
    details and is never stored in the repository. Passwords are not stored
    here at all: they are kept in encrypted credential files in the same
    folder (see Backup\README.md).
#>
@{
    # NAS SMB share that holds the backup folders.
    NasShareRoot = '\\NAS-NAME\BackupShare'
    # Encrypted NAS credential file, in the config folder.
    NasCredentialFile = 'nas-credential.xml'
    # Exclusion patterns file, relative to the Backup folder or a full path.
    ExclusionFile = '.\PSSyncBackup.Exclusions.txt'
    # Also delete NAS copies of anything that matches the exclusion file
    # (PSSync -DeleteExcluded). Run a -WhatIf preview after editing the
    # exclusion file to check the WOULD DELETE EXCLUDED lines.
    DeleteExcluded = $true

    # Synced cloud folder (for example Nextcloud or OneDrive) that receives a
    # copy of the scripts and the live log. Leave empty to log locally only.
    NextcloudArchiveRoot = 'C:\Users\YourName\Nextcloud\PSSyncBackup'
    # Live log folder: a name under NextcloudArchiveRoot, or a full path.
    LogDirectory = 'Logs'
    # Seconds between log file writes during a run (job start/end, errors and
    # large file transfers are always written immediately).
    LogFlushSeconds = 10
    LogRetentionDays = 10
    # Close classic Outlook (OUTLOOK.EXE) before the backup so PST files
    # are not in use. Asked to close normally first, then ended after 2 minutes.
    CloseOutlook = $true

    # One entry per drive or folder to back up. Destination is a folder
    # name under NasShareRoot; it must already exist.
    Jobs = @(
        @{
            Name = 'Drive D'
            Source = 'D:\'
            Destination = 'Windows_D'
        }
        @{
            Name = 'Drive E'
            Source = 'E:\'
            Destination = 'Windows_E'
        }
    )

    # Failure email. Sent only when a live run fails, with the log attached.
    # The SMTP password is NOT stored here; see "Email setup" in the README.
    Email = @{
        SmtpServer = 'smtp.example.com'
        Port = 587
        UseSsl = $true
        From = 'backup-sender@example.com'
        # One address, or several separated by ; or ,
        To = 'you@example.com'
        # Encrypted SMTP credential file, in the config folder.
        # Set to '' if your SMTP server does not require a login.
        CredentialFile = 'email-credential.xml'
        SubjectPrefix = 'PSSync backup FAILED'
    }
}
