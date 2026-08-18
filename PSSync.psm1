# +------------------------------------------------------------------------+
# | PSSync                                                                 |
# +------------------------------------------------------------------------+
# | Purpose:                                                               |
# | Provides file and directory synchronization functionality similar to   |
# | rsync. PSSync synchronizes missing and newer source files to a         |
# | destination and can optionally remove destination-only files and       |
# | directories when -Mirror is specified.                                 |
# |                                                                        |
# | Responsibilities:                                                      |
# | - Provides the PSSync synchronization command.                         |
# | - Validates source and destination locations.                          |
# | - Builds a synchronization plan before modifying the destination.      |
# | - Creates destination directories required by the source.              |
# | - Copies missing source files to the destination.                      |
# | - Updates destination files when the source is newer.                  |
# | - Leaves current destination files unchanged.                          |
# | - Identifies destination-only files.                                   |
# | - Optionally removes destination-only files with -Mirror.              |
# | - Identifies destination-only directories.                             |
# | - Optionally removes destination-only directories with -Mirror.        |
# | - Supports PowerShell's standard -WhatIf functionality.                |
# | - Reports synchronization results and a final operation summary.       |
# |                                                                        |
# | Synchronization Rules:                                                 |
# | - A source directory that does not exist in the destination is created.|
# | - A source file that does not exist in the destination is copied.      |
# | - A source file newer than its destination counterpart is copied.      |
# | - A source file that is the same age or older is left alone.           |
# | - Destination-only files are retained unless -Mirror is specified.     |
# | - Destination-only directories are retained unless -Mirror is          |
# |   specified.                                                           |
# | - Mirror directory cleanup is performed from the deepest directory     |
# |   toward the destination root.                                         |
# |                                                                        |
# | Current Status:                                                        |
# | - Core file synchronization is implemented and tested.                 |
# | - Mirror file deletion is implemented and tested.                      |
# | - Mirror directory deletion is implemented and tested.                 |
# | - -WhatIf behavior is implemented and tested.                          |
# | - Synchronization planning is implemented.                             |
# | - Initial synchronization test suite is passing.                       |
# +------------------------------------------------------------------------+

Set-StrictMode -Version Latest


# +------------------------------------------------------------------------+
# | Get-PSSyncRelativePath                                                 |
# +------------------------------------------------------------------------+
# | Purpose:                                                               |
# | Determines the path of a file or directory relative to a specified     |
# | root directory.                                                        |
# |                                                                        |
# | Responsibilities:                                                      |
# | - Normalize the supplied root directory path.                          |
# | - Verify that the supplied item is located within the root directory.  |
# | - Return the item's path relative to the root directory.               |
# |                                                                        |
# | Inputs:                                                                |
# | SourcePath As String                                                   |
# | - The root directory path.                                             |
# |                                                                        |
# | FilePath As String                                                     |
# | - The full path of the file or directory.                              |
# |                                                                        |
# | Outputs:                                                               |
# | Returns the item path relative to SourcePath.                          |
# |                                                                        |
# | State Changes:                                                         |
# | - Does not modify files, directories, or other persistent state.       |
# |                                                                        |
# | Usage:                                                                 |
# | $RelativePath = Get-PSSyncRelativePath $SourcePath $tmpFile.FullName   |
# |                                                                        |
# | Error Handling:                                                        |
# | Generates a terminating error if FilePath is not located beneath       |
# | SourcePath.                                                            |
#                                                                          |
# | Limitations:                                                           |
# | - SourcePath and FilePath must belong to the same file-system tree.    |
# +------------------------------------------------------------------------+
function Get-PSSyncRelativePath
{
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,

        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    $NormalizedSourcePath = $SourcePath.TrimEnd('\') + '\'
    $NormalizedFilePath = $FilePath

    if ($NormalizedFilePath.StartsWith($NormalizedSourcePath, [System.StringComparison]::OrdinalIgnoreCase))
    {
        return $NormalizedFilePath.Substring($NormalizedSourcePath.Length)
    }

    throw "The file path is not located within the specified root directory: $FilePath"
}


# +------------------------------------------------------------------------+
# | PSSync                                                                 |
# +------------------------------------------------------------------------+
# | Purpose:                                                               |
# | Synchronizes files and directories from a source location to a         |
# | destination location.                                                  |
# |                                                                        |
# | Responsibilities:                                                      |
# | - Validate the source and destination locations.                       |
# | - Build a complete synchronization plan before making changes.         |
# | - Determine required destination directories.                          |
# | - Determine missing, newer, and unchanged files.                       |
# | - Determine destination-only files and directories.                    |
# | - Execute the synchronization plan when not in WhatIf mode.            |
# | - Report the synchronization plan when in WhatIf mode.                 |
# | - Report a final synchronization summary.                              |
# |                                                                        |
# | Inputs:                                                                |
# | Source As String                                                       |
# | - The root source directory.                                           |
# |                                                                        |
# | Destination As String                                                  |
# | - The root destination directory.                                      |
# |                                                                        |
# | Mirror As Switch                                                       |
# | - When specified, destination-only files and directories are removed.  |
# | - When omitted, destination-only items are retained.                   |
# |                                                                        |
# | WhatIf                                                                 |
# | - When specified, displays what would happen without modifying files   |
# |   or directories.                                                      |
# |                                                                        |
# | Outputs:                                                               |
# | Normal execution reports operations actually performed.                |
# | WhatIf execution reports operations that would be performed.           |
# |                                                                        |
# | State Changes:                                                         |
# | - Normal execution may create, copy, update, or delete file-system     |
# |   objects according to the synchronization plan.                       |
# | - WhatIf execution does not modify the file system.                    |
# |                                                                        |
# | Usage:                                                                 |
# | PSSync "C:\Source" "D:\Destination"                                    |
# | PSSync "C:\Source" "D:\Destination" -Mirror                            |
# | PSSync "C:\Source" "D:\Destination" -Mirror -WhatIf                    |
# |                                                                        |
# | Error Handling:                                                        |
# | Source validation errors generate terminating errors. File-system      |
# | operation errors are reported and included in the final error count.   |
# |                                                                        |
# | Limitations:                                                           |
# | - File contents are not compared by hash.                              |
# | - File synchronization is based on LastWriteTimeUtc.                   |
# | - File exclusions and inclusion filters are not currently supported.   |
# | - External logging is not currently supported.                         |
# +------------------------------------------------------------------------+
function PSSync
{
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Source,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$Destination,

        [Parameter()]
        [switch]$Mirror
    )

    $SourcePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Source)
    $DestinationPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Destination)

    $CopiedCount = 0
    $UpdatedCount = 0
    $UnchangedCount = 0
    $DeletedFileCount = 0
    $DeletedDirectoryCount = 0
    $CreatedDirectoryCount = 0
    $ErrorCount = 0

    $WouldCopyCount = 0
    $WouldUpdateCount = 0
    $WouldLeaveAloneCount = 0
    $WouldDeleteFileCount = 0
    $WouldDeleteDirectoryCount = 0
    $WouldCreateDirectoryCount = 0

    $SourceExists = Test-Path -LiteralPath $SourcePath -PathType Container

    if (-not $SourceExists) {    throw "The source directory does not exist: $SourcePath"    }

    $SourcePathWithSeparator = $SourcePath.TrimEnd('\') + '\'

    if ($DestinationPath.Equals($SourcePath, [System.StringComparison]::OrdinalIgnoreCase))
    {
        throw "The source and destination directories cannot be the same: $SourcePath"
    }

    if ($DestinationPath.StartsWith($SourcePathWithSeparator, [System.StringComparison]::OrdinalIgnoreCase))
    {
        throw "The destination directory cannot be located inside the source directory: $DestinationPath"
    }

    $DestinationExists = Test-Path -LiteralPath $DestinationPath -PathType Container

    if ($DestinationExists)
    {
        $SourceFiles = @(Get-ChildItem -LiteralPath $SourcePath -File -Recurse -ErrorAction Stop)
        $SourceDirectories = @(Get-ChildItem -LiteralPath $SourcePath -Directory -Recurse -ErrorAction Stop)
        $DestinationFiles = @(Get-ChildItem -LiteralPath $DestinationPath -File -Recurse -ErrorAction Stop)
        $DestinationDirectories = @(Get-ChildItem -LiteralPath $DestinationPath -Directory -Recurse -ErrorAction Stop)
    }
    else
    {
        $SourceFiles = @(Get-ChildItem -LiteralPath $SourcePath -File -Recurse -ErrorAction Stop)
        $SourceDirectories = @(Get-ChildItem -LiteralPath $SourcePath -Directory -Recurse -ErrorAction Stop)
        $DestinationFiles = @()
        $DestinationDirectories = @()
    }

    # +--------------------------------------------------------------------+
    # | Synchronization Plan                                               |
    # +--------------------------------------------------------------------+

    $DirectoriesToCreate = @()
    $FilesToCopy = @()
    $FilesToUpdate = @()
    $FilesToLeaveAlone = @()
    $FilesToDelete = @()
    $DirectoriesToDelete = @()

    if (-not $DestinationExists)
    {
        $DirectoriesToCreate += $DestinationPath
    }

    foreach ($tmpDirectory in $SourceDirectories)
    {
        $RelativePath = Get-PSSyncRelativePath $SourcePath $tmpDirectory.FullName
        $DestinationDirectoryPath = Join-Path -Path $DestinationPath -ChildPath $RelativePath
        $DestinationDirectoryExists = Test-Path -LiteralPath $DestinationDirectoryPath -PathType Container

        if (-not $DestinationDirectoryExists)
        {
            $DirectoriesToCreate += $DestinationDirectoryPath
        }
    }

    foreach ($tmpFile in $SourceFiles)
    {
        $RelativePath = Get-PSSyncRelativePath $SourcePath $tmpFile.FullName
        $DestinationFilePath = Join-Path -Path $DestinationPath -ChildPath $RelativePath
        $DestinationFileExists = Test-Path -LiteralPath $DestinationFilePath -PathType Leaf

        if (-not $DestinationFileExists)
        {
            $FilesToCopy += $tmpFile
        }
        else
        {
            $DestinationFile = Get-Item -LiteralPath $DestinationFilePath -ErrorAction Stop
            $SourceIsNewer = $tmpFile.LastWriteTimeUtc -gt $DestinationFile.LastWriteTimeUtc

            if ($SourceIsNewer)
            {
                $FilesToUpdate += [PSCustomObject]@{
                    SourceFile = $tmpFile
                    DestinationFilePath = $DestinationFilePath
                    RelativePath = $RelativePath
                }
            }
            else
            {
                $FilesToLeaveAlone += $RelativePath
            }
        }
    }

    foreach ($tmpFile in $DestinationFiles)
    {
        $RelativePath = Get-PSSyncRelativePath $DestinationPath $tmpFile.FullName
        $SourceFilePath = Join-Path -Path $SourcePath -ChildPath $RelativePath
        $SourceFileExists = Test-Path -LiteralPath $SourceFilePath -PathType Leaf

        if (-not $SourceFileExists)
        {
            $FilesToDelete += $tmpFile
        }
    }

    if ($Mirror)
    {
        $SortedDestinationDirectories = @(
            $DestinationDirectories |
                Sort-Object @{ Expression = { $_.FullName.Length }; Descending = $true }
        )

        foreach ($tmpDirectory in $SortedDestinationDirectories)
        {
            $RelativePath = Get-PSSyncRelativePath $DestinationPath $tmpDirectory.FullName
            $SourceDirectoryPath = Join-Path -Path $SourcePath -ChildPath $RelativePath
            $SourceDirectoryExists = Test-Path -LiteralPath $SourceDirectoryPath -PathType Container

            if (-not $SourceDirectoryExists)
            {
                $DirectoriesToDelete += $tmpDirectory
            }
        }
    }

    # +--------------------------------------------------------------------+
    # | WhatIf Reporting                                                   |
    # +--------------------------------------------------------------------+

    if ($WhatIfPreference)
    {
        foreach ($tmpDirectory in $DirectoriesToCreate)
        {
            Write-Host "WOULD CREATE DIRECTORY: $tmpDirectory"
            $WouldCreateDirectoryCount = $WouldCreateDirectoryCount + 1
        }

        foreach ($tmpFile in $FilesToCopy)
        {
            $RelativePath = Get-PSSyncRelativePath $SourcePath $tmpFile.FullName
            Write-Host "WOULD COPY: $RelativePath"
            $WouldCopyCount = $WouldCopyCount + 1
        }

        foreach ($tmpFile in $FilesToUpdate)
        {
            Write-Host "WOULD UPDATE: $($tmpFile.RelativePath)"
            $WouldUpdateCount = $WouldUpdateCount + 1
        }

        foreach ($RelativePath in $FilesToLeaveAlone)
        {
            Write-Host "WOULD LEAVE ALONE: $RelativePath"
            $WouldLeaveAloneCount = $WouldLeaveAloneCount + 1
        }

        if ($Mirror)
        {
            foreach ($tmpFile in $FilesToDelete)
            {
                $RelativePath = Get-PSSyncRelativePath $DestinationPath $tmpFile.FullName
                Write-Host "WOULD DELETE: $RelativePath"
                $WouldDeleteFileCount = $WouldDeleteFileCount + 1
            }

            foreach ($tmpDirectory in $DirectoriesToDelete)
            {
                $RelativePath = Get-PSSyncRelativePath $DestinationPath $tmpDirectory.FullName
                Write-Host "WOULD DELETE DIRECTORY: $RelativePath"
                $WouldDeleteDirectoryCount = $WouldDeleteDirectoryCount + 1
            }
        }

        Write-Host ""
        Write-Host "PSSync WhatIf Complete"
        Write-Host "------------------------------"
        Write-Host "Would Copy:             $WouldCopyCount"
        Write-Host "Would Update:           $WouldUpdateCount"
        Write-Host "Would Leave Alone:      $WouldLeaveAloneCount"
        Write-Host "Would Delete Files:     $WouldDeleteFileCount"
        Write-Host "Would Delete Dirs:      $WouldDeleteDirectoryCount"
        Write-Host "Would Create Dirs:      $WouldCreateDirectoryCount"
        Write-Host "------------------------------"
        Write-Host "Source:                 $SourcePath"
        Write-Host "Destination:            $DestinationPath"

        return
    }

    # +--------------------------------------------------------------------+
    # | Directory Creation                                                 |
    # +--------------------------------------------------------------------+

    foreach ($DirectoryPath in $DirectoriesToCreate)
    {
        try
        {
            New-Item -ItemType Directory -Path $DirectoryPath -Force -ErrorAction Stop | Out-Null
            $CreatedDirectoryCount = $CreatedDirectoryCount + 1
            Write-Host "CREATED DIRECTORY: $DirectoryPath"
        }
        catch
        {
            $ErrorCount = $ErrorCount + 1
            Write-Host "ERROR: Unable to create directory: $DirectoryPath"
        }
    }

    # +--------------------------------------------------------------------+
    # | File Copying                                                       |
    # +--------------------------------------------------------------------+

    foreach ($tmpFile in $FilesToCopy)
    {
        $RelativePath = Get-PSSyncRelativePath $SourcePath $tmpFile.FullName
        $DestinationFilePath = Join-Path -Path $DestinationPath -ChildPath $RelativePath

        try
        {
            Copy-Item -LiteralPath $tmpFile.FullName -Destination $DestinationFilePath -Force -ErrorAction Stop
            $CopiedCount = $CopiedCount + 1
            Write-Host "COPIED: $RelativePath"
        }
        catch
        {
            $ErrorCount = $ErrorCount + 1
            Write-Host "ERROR: Unable to copy file: $RelativePath"
        }
    }

    # +--------------------------------------------------------------------+
    # | File Updates                                                       |
    # +--------------------------------------------------------------------+

    foreach ($tmpFile in $FilesToUpdate)
    {
        try
        {
            Copy-Item -LiteralPath $tmpFile.SourceFile.FullName -Destination $tmpFile.DestinationFilePath -Force -ErrorAction Stop
            $UpdatedCount = $UpdatedCount + 1
            Write-Host "UPDATED: $($tmpFile.RelativePath)"
        }
        catch
        {
            $ErrorCount = $ErrorCount + 1
            Write-Host "ERROR: Unable to update file: $($tmpFile.RelativePath)"
        }
    }

    # +--------------------------------------------------------------------+
    # | Unchanged Files                                                    |
    # +--------------------------------------------------------------------+

    foreach ($RelativePath in $FilesToLeaveAlone)
    {
        $UnchangedCount = $UnchangedCount + 1
        Write-Host "UNCHANGED: $RelativePath"
    }

    # +--------------------------------------------------------------------+
    # | Mirror File Deletion                                               |
    # +--------------------------------------------------------------------+

    if ($Mirror)
    {
        foreach ($tmpFile in $FilesToDelete)
        {
            $RelativePath = Get-PSSyncRelativePath $DestinationPath $tmpFile.FullName

            try
            {
                Remove-Item -LiteralPath $tmpFile.FullName -Force -ErrorAction Stop
                $DeletedFileCount = $DeletedFileCount + 1
                Write-Host "DELETED: $RelativePath"
            }
            catch
            {
                $ErrorCount = $ErrorCount + 1
                Write-Host "ERROR: Unable to delete file: $RelativePath"
            }
        }

        foreach ($tmpDirectory in $DirectoriesToDelete)
        {
            $RelativePath = Get-PSSyncRelativePath $DestinationPath $tmpDirectory.FullName

            try
            {
                Remove-Item -LiteralPath $tmpDirectory.FullName -Force -ErrorAction Stop
                $DeletedDirectoryCount = $DeletedDirectoryCount + 1
                Write-Host "DELETED DIRECTORY: $RelativePath"
            }
            catch
            {
                $ErrorCount = $ErrorCount + 1
                Write-Host "ERROR: Unable to delete directory: $RelativePath"
            }
        }
    }
    else
    {
        foreach ($tmpFile in $FilesToDelete)
        {
            $RelativePath = Get-PSSyncRelativePath $DestinationPath $tmpFile.FullName
            Write-Host "EXTRANEOUS: $RelativePath"
        }
    }

    # +--------------------------------------------------------------------+
    # | Final Summary                                                      |
    # +--------------------------------------------------------------------+

    Write-Host ""
    Write-Host "PSSync Complete"
    Write-Host "------------------------------"
    Write-Host "Copied:              $CopiedCount"
    Write-Host "Updated:             $UpdatedCount"
    Write-Host "Unchanged:           $UnchangedCount"
    Write-Host "Deleted Files:       $DeletedFileCount"
    Write-Host "Deleted Directories: $DeletedDirectoryCount"
    Write-Host "Errors:              $ErrorCount"
    Write-Host "------------------------------"
    Write-Host "Source:              $SourcePath"
    Write-Host "Destination:         $DestinationPath"
}

Export-ModuleMember -Function PSSync
