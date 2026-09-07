# +----------------------------------------------------------------------------+
# | PSSync                                                                     |
# +----------------------------------------------------------------------------+
# | Purpose:                                                                   |
# | Provides file and directory synchronization functionality similar to       |
# | rsync. PSSync synchronizes missing and newer source files to a             |
# | destination and can optionally remove destination-only files and           |
# | directories when -Mirror is specified.                                     |
# |                                                                            |
# | Responsibilities:                                                          |
# | - Provides the PSSync synchronization command.                             |
# | - Validates source and destination locations.                              |
# | - Builds a synchronization plan before modifying the destination.          |
# | - Creates destination directories required by the source.                  |
# | - Copies missing source files to the destination.                          |
# | - Updates destination files when the source is newer.                      |
# | - Leaves current destination files unchanged.                              |
# | - Identifies destination-only files.                                       |
# | - Optionally removes destination-only files with -Mirror.                  |
# | - Identifies destination-only directories.                                 |
# | - Optionally removes destination-only directories with -Mirror.            |
# | - Supports PowerShell's standard -WhatIf functionality.                    |
# | - Reports synchronization results and a final operation summary.           |
# | - Provides optional ChangesOnly output to suppress no-change messages.     |
# | - Displays progress while enumerating, analyzing, and synchronizing.       |
# |                                                                            |
# | Synchronization Rules:                                                     |
# | - A source directory that does not exist in the destination is created.    |
# | - A source file that does not exist in the destination is copied.          |
# | - A source file newer than its destination counterpart is copied.          |
# | - A source file that is the same age or older is left alone.               |
# | - Destination-only files are retained unless -Mirror is specified.         |
# | - Destination-only directories are retained unless -Mirror is              |
# |   specified.                                                               |
# | - Mirror directory cleanup is performed from the deepest directory         |
# |   toward the destination root.                                             |
# |                                                                            |
# | Current Status:                                                            |
# | - Core file synchronization is implemented and tested.                     |
# | - Mirror file deletion is implemented and tested.                          |
# | - Mirror directory deletion is implemented and tested.                     |
# | - -WhatIf behavior is implemented and tested.                              |
# | - -ChangesOnly output filtering is implemented and tested.                 |
# | - Progress reporting is implemented for analysis and synchronization.      |
# | - Synchronization planning is implemented.                                 |
# | - File/directory conflict detection is implemented and tested.             |
# | - Copy/update verification is implemented using SHA-256 hashes.            |
# |                                                                            |
# | Security:                                                                  |
# | PSSync uses SHA-256, a FIPS-approved hashing algorithm, for verification   |
# | of files transferred during synchronization. PSSync does not use MD5 or    |
# | SHA-1 for file verification.                                               |
# |                                                                            |
# | - The current Pester test suite is passing.                                |
# +----------------------------------------------------------------------------+

Set-StrictMode -Version Latest


# +----------------------------------------------------------------------------+
# | Get-PSSyncRelativePath                                                     |
# +----------------------------------------------------------------------------+
# | Purpose:                                                                   |
# | Determines the path of a file or directory relative to a specified         |
# | root directory.                                                            |
# |                                                                            |
# | Responsibilities:                                                          |
# | - Normalize the supplied root directory path.                              |
# | - Verify that the supplied item is located within the root directory.      |
# | - Return the item's path relative to the root directory.                   |
# |                                                                            |
# | Inputs:                                                                    |
# | SourcePath As String                                                       |
# | - The root directory path.                                                 |
# |                                                                            |
# | FilePath As String                                                         |
# | - The full path of the file or directory.                                  |
# |                                                                            |
# | Outputs:                                                                   |
# | Returns the item path relative to SourcePath.                              |
# |                                                                            |
# | State Changes:                                                             |
# | - Does not modify files, directories, or other persistent state.           |
# |                                                                            |
# | Usage:                                                                     |
# | $RelativePath = Get-PSSyncRelativePath $SourcePath $tmpFile.FullName       |
# |                                                                            |
# | Error Handling:                                                            |
# | Generates a terminating error if FilePath is not located beneath           |
# | SourcePath.                                                                |
# |                                                                            |
# | Limitations:                                                               |
# | - SourcePath and FilePath must belong to the same file-system tree.        |
# +----------------------------------------------------------------------------+
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


# +----------------------------------------------------------------------------+
# | Get-PSSyncFileHash                                                         |
# +----------------------------------------------------------------------------+
# | Purpose:                                                                   |
# | Calculates the SHA-256 hash of a file using the Windows CNG-backed         |
# | SHA256Cng implementation provided by the .NET Framework.                   |
# |                                                                            |
# | Responsibilities:                                                          |
# | - Open the specified file for read access.                                 |
# | - Calculate its SHA-256 hash.                                              |
# | - Return the hash as a hexadecimal string.                                 |
# |                                                                            |
# | Inputs:                                                                    |
# | FilePath As String                                                         |
# | - The full path of the file to hash.                                       |
# |                                                                            |
# | Outputs:                                                                   |
# | Returns the SHA-256 hash as a hexadecimal string.                          |
# |                                                                            |
# | State Changes:                                                             |
# | - Does not modify the source file.                                         |
# |                                                                            |
# | Usage:                                                                     |
# | $Hash = Get-PSSyncFileHash $FilePath                                       |
# |                                                                            |
# | Error Handling:                                                            |
# | - File and cryptographic errors are allowed to terminate the caller.       |
# |                                                                            |
# | Limitations:                                                               |
# | - Requires the Windows CNG SHA-256 implementation available to .NET        |
# |   Framework on supported Windows hosts.                                    |
# +----------------------------------------------------------------------------+
function Get-PSSyncFileHash
{
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    $FileStream = $null
    $HashAlgorithm = $null

    try
    {
        $FileStream = [System.IO.File]::Open(
            $FilePath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read
        )

        $HashAlgorithm = New-Object System.Security.Cryptography.SHA256Cng
        $HashBytes = $HashAlgorithm.ComputeHash($FileStream)

        return ([System.BitConverter]::ToString($HashBytes)).Replace("-", "").ToUpperInvariant()
    }
    finally
    {
        if ($HashAlgorithm -ne $null)
        {
            $HashAlgorithm.Dispose()
        }

        if ($FileStream -ne $null)
        {
            $FileStream.Dispose()
        }
    }
}


# +----------------------------------------------------------------------------+
# | Test-PSSyncHashing                                                         |
# +----------------------------------------------------------------------------+
# | Purpose:                                                                   |
# | Verifies that PSSync's SHA-256 hashing mechanism is available and          |
# | produces the expected result before synchronization modifies the           |
# | destination.                                                               |
# |                                                                            |
# | Responsibilities:                                                          |
# | - Create a temporary test file.                                            |
# | - Hash known test data using the same helper used for synchronization.     |
# | - Compare the result to the known SHA-256 value.                           |
# | - Remove the temporary test file.                                          |
# |                                                                            |
# | Inputs:                                                                    |
# | - None.                                                                    |
# |                                                                            |
# | Outputs:                                                                   |
# | Returns $true when the hashing self-test succeeds.                         |
# |                                                                            |
# | State Changes:                                                             |
# | - Creates and removes one temporary test file.                             |
# | - Does not modify the source or destination directories.                   |
# |                                                                            |
# | Usage:                                                                     |
# | $HashingReady = Test-PSSyncHashing                                         |
# |                                                                            |
# | Error Handling:                                                            |
# | - Throws when the SHA-256 implementation is unavailable or produces an     |
# |   unexpected result.                                                       |
# |                                                                            |
# | Limitations:                                                               |
# | - The self-test verifies the hashing mechanism but cannot predict future   |
# |   file-access failures.                                                    |
# +----------------------------------------------------------------------------+
function Test-PSSyncHashing
{
    $TestFilePath = Join-Path -Path ([System.IO.Path]::GetTempPath()) `
        -ChildPath ("PSSync_SHA256_{0}.tmp" -f [System.Guid]::NewGuid().ToString("N"))
    $ExpectedHash = "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD"
    $TestBytes = [System.Text.Encoding]::ASCII.GetBytes("abc")

    try
    {
        [System.IO.File]::WriteAllBytes($TestFilePath, $TestBytes)

        $ActualHash = Get-PSSyncFileHash $TestFilePath

        if ($ActualHash -ne $ExpectedHash)
        {
            throw "PSSync SHA-256 self-test failed. Expected $ExpectedHash but received $ActualHash."
        }

        return $true
    }
    catch
    {
        throw "PSSync SHA-256 verification is unavailable or failed its self-test. " +
            "No synchronization changes have been made. $($_.Exception.Message)"
    }
    finally
    {
        if (Test-Path -LiteralPath $TestFilePath)
        {
            Remove-Item -LiteralPath $TestFilePath -Force -WhatIf:$false -ErrorAction SilentlyContinue
        }
    }
}


# +----------------------------------------------------------------------------+
# | Copy-PSSyncFile                                                            |
# +----------------------------------------------------------------------------+
# | Purpose:                                                                   |
# | Copies a file with byte-level progress and verifies the result against     |
# | the known-good source hash captured during synchronization planning.       |
# |                                                                            |
# | Responsibilities:                                                          |
# | - Copy the source file using buffered .NET file streams.                   |
# | - Report byte-level progress for the current file.                         |
# | - Recalculate the source SHA-256 hash after the copy.                      |
# | - Compare the post-copy source hash to the planning hash.                  |
# | - Calculate the destination SHA-256 hash.                                  |
# | - Compare the destination hash to the planning hash.                       |
# |                                                                            |
# | Inputs:                                                                    |
# | SourceFile As FileInfo                                                     |
# | - The source file to copy.                                                 |
# |                                                                            |
# | DestinationFilePath As String                                              |
# | - The full destination path.                                               |
# |                                                                            |
# | ExpectedSourceHash As String                                               |
# | - The SHA-256 hash captured during synchronization planning.               |
# |                                                                            |
# | Operation As String                                                        |
# | - The operation name shown in progress output.                             |
# |                                                                            |
# | Outputs:                                                                   |
# | Returns $true only when the source remained unchanged and the              |
# | destination matches the known-good source hash.                            |
# |                                                                            |
# | State Changes:                                                             |
# | - Creates or replaces the destination file.                                |
# | - Does not modify the source file.                                         |
# |                                                                            |
# | Usage:                                                                     |
# | $Verified = Copy-PSSyncFile $SourceFile $DestinationPath $Hash "Copying"   |
# |                                                                            |
# | Error Handling:                                                            |
# | - File and hash errors are allowed to terminate the caller's try block.    |
# | - Verification mismatches return $false after reporting the reason.        |
# |                                                                            |
# | Limitations:                                                               |
# | - Verification requires reading the source after the copy and the          |
# |   destination after the copy.                                              |
# +----------------------------------------------------------------------------+
function Copy-PSSyncFile
{
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$SourceFile,

        [Parameter(Mandatory = $true)]
        [string]$DestinationFilePath,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedSourceHash,

        [Parameter(Mandatory = $true)]
        [string]$Operation
    )

    $BufferSize = 1048576
    $BytesCopied = [int64]0
    $SourceLength = $SourceFile.Length
    $SourceStream = $null
    $DestinationStream = $null

    try
    {
        $SourceStream = [System.IO.File]::Open(
            $SourceFile.FullName,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read
        )

        $DestinationStream = [System.IO.File]::Open(
            $DestinationFilePath,
            [System.IO.FileMode]::Create,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )

        $Buffer = New-Object byte[] $BufferSize
        $BytesRead = 0

        do
        {
            $BytesRead = $SourceStream.Read($Buffer, 0, $Buffer.Length)

            if ($BytesRead -gt 0)
            {
                $DestinationStream.Write($Buffer, 0, $BytesRead)
                $BytesCopied = $BytesCopied + $BytesRead

                if ($SourceLength -gt 0)
                {
                    $PercentComplete = [int](($BytesCopied / $SourceLength) * 100)
                }
                else
                {
                    $PercentComplete = 100
                }

                Write-Progress -Activity "PSSync" `
                    -Status "$Operation`: $($SourceFile.Name) - $([math]::Round($BytesCopied / 1MB, 1)) MB / $([math]::Round($SourceLength / 1MB, 1)) MB" `
                    -PercentComplete $PercentComplete
            }
        }
        while ($BytesRead -gt 0)

        $DestinationStream.Flush()
    }
    finally
    {
        if ($DestinationStream -ne $null)
        {
            $DestinationStream.Dispose()
        }

        if ($SourceStream -ne $null)
        {
            $SourceStream.Dispose()
        }
    }

    Write-Progress -Activity "PSSync" -Status "Verifying source: $($SourceFile.Name)" -PercentComplete 100

    $CurrentSourceHash = Get-PSSyncFileHash $SourceFile.FullName

    if ($CurrentSourceHash -ne $ExpectedSourceHash)
    {
        Write-Host "ERROR: Source changed during synchronization: $($SourceFile.FullName)"
        return $false
    }

    Write-Progress -Activity "PSSync" -Status "Verifying destination: $($SourceFile.Name)" -PercentComplete 100

    $DestinationHash = Get-PSSyncFileHash $DestinationFilePath

    if ($DestinationHash -ne $ExpectedSourceHash)
    {
        Write-Host "ERROR: Destination verification failed: $DestinationFilePath"
        return $false
    }

    [System.IO.File]::SetLastWriteTimeUtc(
        $DestinationFilePath,
        $SourceFile.LastWriteTimeUtc
    )

    return $true
}


# +----------------------------------------------------------------------------+
# | PSSync                                                                     |
# +----------------------------------------------------------------------------+
# | Purpose:                                                                   |
# | Synchronizes files and directories from a source location to a             |
# | destination location.                                                      |
# |                                                                            |
# | Responsibilities:                                                          |
# | - Validate the source and destination locations.                           |
# | - Build a complete synchronization plan before making changes.             |
# | - Determine required destination directories.                              |
# | - Determine missing, newer, and unchanged files.                           |
# | - Determine destination-only files and directories.                        |
# | - Calculate and store source hashes during synchronization planning.       |
# | - Verify SHA-256 hashing before modifying the destination.                 |
# | - Execute the synchronization plan when not in WhatIf mode.                |
# | - Report the synchronization plan when in WhatIf mode.                     |
# | - Report a final synchronization summary.                                  |
# |                                                                            |
# | Inputs:                                                                    |
# | Source As String                                                           |
# | - The root source directory.                                               |
# |                                                                            |
# | Destination As String                                                      |
# | - The root destination directory.                                          |
# |                                                                            |
# | Mirror As Switch                                                           |
# | - When specified, destination-only files and directories are removed.      |
# | - When omitted, destination-only items are retained.                       |
# |                                                                            |
# | WhatIf                                                                     |
# | - When specified, displays what would happen without modifying files       |
# |   or directories.                                                          |
# |                                                                            |
# | ChangesOnly As Switch                                                      |
# | - When specified, suppresses per-item messages for files that require      |
# |   no action.                                                               |
# | - Normal execution suppresses UNCHANGED messages.                          |
# | - WhatIf execution suppresses WOULD LEAVE ALONE messages.                  |
# | - Does not change synchronization behavior or summary counts.              |
# |                                                                            |
# | Outputs:                                                                   |
# | Normal execution reports operations actually performed.                    |
# | WhatIf execution reports operations that would be performed.               |
# | ChangesOnly affects output detail only; it does not affect the plan.       |
# |                                                                            |
# | State Changes:                                                             |
# | - Normal execution may create, copy, update, or delete file-system         |
# |   objects according to the synchronization plan.                           |
# | - WhatIf execution does not modify the file system.                        |
# |                                                                            |
# | Usage:                                                                     |
# | PSSync "C:\Source" "D:\Destination"                                        |
# | PSSync "C:\Source" "D:\Destination" -Mirror                                |
# | PSSync "C:\Source" "D:\Destination" -Mirror -WhatIf                        |
# | PSSync "C:\Source" "D:\Destination" -ChangesOnly                           |
# |                                                                            |
# | Error Handling:                                                            |
# | Source validation errors generate terminating errors. File-system          |
# | operation errors are reported and included in the final error count.       |
# |                                                                            |
# | Limitations:                                                               |
# | - File synchronization decisions are based on LastWriteTimeUtc.            |
# | - File contents are verified with SHA-256 after copy/update.               |
# | - File exclusions and inclusion filters are not currently supported.       |
# | - External logging is not currently supported.                             |
# +----------------------------------------------------------------------------+
function PSSync
{
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Source,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$Destination,

        [Parameter()]
        [switch]$Mirror,
        [switch]$ChangesOnly

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

    if (-not (Test-PSSyncHashing))
    {
        throw "PSSync SHA-256 verification self-test failed."
    }

# +----------------------------------------------------------------------------+
# | Enumerate Source                                                           |
# +----------------------------------------------------------------------------+

    $SourceFiles = New-Object 'System.Collections.Generic.List[System.IO.FileInfo]'
    $SourceDirectories = New-Object 'System.Collections.Generic.List[System.IO.DirectoryInfo]'

    Write-Progress -Activity "PSSync" -Status "Enumerating source files..."

    foreach ($tmpItem in Get-ChildItem -LiteralPath $SourcePath -File -Recurse -ErrorAction Stop)
    {
        $SourceFiles.Add($tmpItem)

        if (($SourceFiles.Count % 100) -eq 0)
        {
            Write-Progress -Activity "PSSync" -Status "Enumerating source files... $($SourceFiles.Count) found"
        }
    }

    Write-Progress -Activity "PSSync" -Status "Enumerating source files... $($SourceFiles.Count) found"
    Write-Progress -Activity "PSSync" -Status "Enumerating source directories..."

    foreach ($tmpItem in Get-ChildItem -LiteralPath $SourcePath -Directory -Recurse -ErrorAction Stop)
    {
        $SourceDirectories.Add($tmpItem)

        if (($SourceDirectories.Count % 100) -eq 0)
        {
            Write-Progress -Activity "PSSync" -Status "Enumerating source directories... $($SourceDirectories.Count) found"
        }
    }

    Write-Progress -Activity "PSSync" -Status "Enumerating source directories... $($SourceDirectories.Count) found"

# +----------------------------------------------------------------------------+
# | Enumerate Destination                                                      |
# +----------------------------------------------------------------------------+
    $DestinationFiles = New-Object 'System.Collections.Generic.List[System.IO.FileInfo]'
    $DestinationDirectories = New-Object 'System.Collections.Generic.List[System.IO.DirectoryInfo]'

    if ($DestinationExists)
    {
        Write-Progress -Activity "PSSync" -Status "Enumerating destination files..."

        foreach ($tmpItem in Get-ChildItem -LiteralPath $DestinationPath -File -Recurse -ErrorAction Stop)
        {
            $DestinationFiles.Add($tmpItem)

            if (($DestinationFiles.Count % 100) -eq 0)
            {
                Write-Progress -Activity "PSSync" -Status "Enumerating destination files... $($DestinationFiles.Count) found"
            }
        }

        Write-Progress -Activity "PSSync" -Status "Enumerating destination files... $($DestinationFiles.Count) found"
        Write-Progress -Activity "PSSync" -Status "Enumerating destination directories..."

        foreach ($tmpItem in Get-ChildItem -LiteralPath $DestinationPath -Directory -Recurse -ErrorAction Stop)
        {
            $DestinationDirectories.Add($tmpItem)

            if (($DestinationDirectories.Count % 100) -eq 0)
            {
                Write-Progress -Activity "PSSync" -Status "Enumerating destination directories... $($DestinationDirectories.Count) found"
            }
        }

        Write-Progress -Activity "PSSync" -Status "Enumerating destination directories... $($DestinationDirectories.Count) found"
    }

# +----------------------------------------------------------------------------+
# | Determine Workload                                                         |
# +----------------------------------------------------------------------------+
    $TotalFileCount = $SourceFiles.Count + $DestinationFiles.Count
    $TotalDirectoryCount = $SourceDirectories.Count + $DestinationDirectories.Count

    Write-Progress -Activity "PSSync" -Status "Determining workload..."
    Start-Sleep -Milliseconds 100

# +----------------------------------------------------------------------------+
# | Synchronization Plan                                                       |
# +----------------------------------------------------------------------------+
    $DirectoriesToCreate = @()
    $FilesToCopy = @()
    $FilesToUpdate = @()
    $FilesToLeaveAlone = @()
    $FilesToDelete = @()
    $DirectoriesToDelete = @()

    $AnalyzedFileCount = 0
    $AnalyzedDirectoryCount = 0
    $TotalAnalysisItemCount = $SourceFiles.Count + $SourceDirectories.Count + $DestinationFiles.Count

    if ($Mirror)
    {
        $TotalAnalysisItemCount = $TotalAnalysisItemCount + $DestinationDirectories.Count
    }

    $AnalysisUpdateInterval = 100

# +----------------------------------------------------------------------------+
# | File / Directory Conflict Detection                                        |
# +----------------------------------------------------------------------------+
    Write-Progress -Activity "PSSync" -Status "Checking for file/directory conflicts..."

    foreach ($tmpFile in $SourceFiles)
    {
        $RelativePath = Get-PSSyncRelativePath $SourcePath $tmpFile.FullName
        $DestinationDirectoryPath = Join-Path -Path $DestinationPath -ChildPath $RelativePath

        if (Test-Path -LiteralPath $DestinationDirectoryPath -PathType Container)
        {
            Write-Progress -Activity "PSSync" -Completed
            throw "File/directory conflict at relative path: $RelativePath"
        }
    }

    foreach ($tmpDirectory in $SourceDirectories)
    {
        $RelativePath = Get-PSSyncRelativePath $SourcePath $tmpDirectory.FullName
        $DestinationFilePath = Join-Path -Path $DestinationPath -ChildPath $RelativePath

        if (Test-Path -LiteralPath $DestinationFilePath -PathType Leaf)
        {
            Write-Progress -Activity "PSSync" -Completed
            throw "File/directory conflict at relative path: $RelativePath"
        }
    }

# +----------------------------------------------------------------------------+
# | Build Synchronization Plan                                                 |
# +----------------------------------------------------------------------------+
    Write-Progress -Activity "PSSync" -Status "Analyzing source and destination..." -PercentComplete 0

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

        $AnalyzedDirectoryCount = $AnalyzedDirectoryCount + 1

        if (($AnalyzedDirectoryCount % $AnalysisUpdateInterval) -eq 0)
        {
            $AnalyzedItemCount = $AnalyzedFileCount + $AnalyzedDirectoryCount

            if ($TotalAnalysisItemCount -gt 0)
            {
                $PercentComplete = [int](($AnalyzedItemCount / $TotalAnalysisItemCount) * 100)
            }
            else
            {
                $PercentComplete = 100
            }

            Write-Progress -Activity "PSSync" -Status "Analyzing source and destination... Directories: $AnalyzedDirectoryCount / $TotalDirectoryCount" -PercentComplete $PercentComplete
        }
    }

    foreach ($tmpFile in $SourceFiles)
    {
        $RelativePath = Get-PSSyncRelativePath $SourcePath $tmpFile.FullName
        $DestinationFilePath = Join-Path -Path $DestinationPath -ChildPath $RelativePath
        $DestinationFileExists = Test-Path -LiteralPath $DestinationFilePath -PathType Leaf

        if (-not $DestinationFileExists)
        {
            $SourceHash = Get-PSSyncFileHash $tmpFile.FullName

            $FilesToCopy += [PSCustomObject]@{
                SourceFile = $tmpFile
                SourceHash = $SourceHash
                RelativePath = $RelativePath
            }
        }
        else
        {
            $DestinationFile = Get-Item -LiteralPath $DestinationFilePath -ErrorAction Stop
            $SourceIsNewer = $tmpFile.LastWriteTimeUtc -gt $DestinationFile.LastWriteTimeUtc

            if ($SourceIsNewer)
            {
                $SourceHash = Get-PSSyncFileHash $tmpFile.FullName

                $FilesToUpdate += [PSCustomObject]@{
                    SourceFile = $tmpFile
                    DestinationFilePath = $DestinationFilePath
                    RelativePath = $RelativePath
                    SourceHash = $SourceHash
                }
            }
            else
            {
                $FilesToLeaveAlone += $RelativePath
            }
        }

        $AnalyzedFileCount = $AnalyzedFileCount + 1

        if (($AnalyzedFileCount % $AnalysisUpdateInterval) -eq 0)
        {
            $AnalyzedItemCount = $AnalyzedFileCount + $AnalyzedDirectoryCount

            if ($TotalAnalysisItemCount -gt 0)
            {
                $PercentComplete = [int](($AnalyzedItemCount / $TotalAnalysisItemCount) * 100)
            }
            else
            {
                $PercentComplete = 100
            }

            Write-Progress -Activity "PSSync" -Status "Analyzing source and destination... Files: $AnalyzedFileCount / $TotalFileCount" -PercentComplete $PercentComplete
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

        $AnalyzedFileCount = $AnalyzedFileCount + 1

        if (($AnalyzedFileCount % $AnalysisUpdateInterval) -eq 0)
        {
            $AnalyzedItemCount = $AnalyzedFileCount + $AnalyzedDirectoryCount

            if ($TotalAnalysisItemCount -gt 0)
            {
                $PercentComplete = [int](($AnalyzedItemCount / $TotalAnalysisItemCount) * 100)
            }
            else
            {
                $PercentComplete = 100
            }

            Write-Progress -Activity "PSSync" -Status "Analyzing source and destination... Files: $AnalyzedFileCount / $TotalFileCount" -PercentComplete $PercentComplete
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

            $AnalyzedDirectoryCount = $AnalyzedDirectoryCount + 1

            if (($AnalyzedDirectoryCount % $AnalysisUpdateInterval) -eq 0)
            {
                $AnalyzedItemCount = $AnalyzedFileCount + $AnalyzedDirectoryCount

                if ($TotalAnalysisItemCount -gt 0)
                {
                    $PercentComplete = [int](($AnalyzedItemCount / $TotalAnalysisItemCount) * 100)
                }
                else
                {
                    $PercentComplete = 100
                }

                Write-Progress -Activity "PSSync" -Status "Analyzing source and destination... Directories: $AnalyzedDirectoryCount / $TotalDirectoryCount" -PercentComplete $PercentComplete
            }
        }
    }

    Write-Progress -Activity "PSSync" -Status "Analysis complete." -PercentComplete 100
    Start-Sleep -Milliseconds 100
    Write-Progress -Activity "PSSync" -Completed

# +----------------------------------------------------------------------------+
# | WhatIf Reporting                                                           |
# +----------------------------------------------------------------------------+
    if ($WhatIfPreference)
    {
        foreach ($tmpDirectory in $DirectoriesToCreate)
        {
            Write-Host "WOULD CREATE DIRECTORY: $tmpDirectory"
            $WouldCreateDirectoryCount = $WouldCreateDirectoryCount + 1
        }

        foreach ($tmpFile in $FilesToCopy)
        {
            $RelativePath = $tmpFile.RelativePath
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
            if (-not $ChangesOnly)
            {
                Write-Host "WOULD LEAVE ALONE: $RelativePath"
            }

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

# +----------------------------------------------------------------------------+
# | Directory Creation                                                         |
# +----------------------------------------------------------------------------+
    $TotalExecutionOperationCount = $DirectoriesToCreate.Count + $FilesToCopy.Count + $FilesToUpdate.Count + $FilesToLeaveAlone.Count + $FilesToDelete.Count + $DirectoriesToDelete.Count
    $CompletedExecutionOperationCount = 0

    if ($TotalExecutionOperationCount -gt 0)
    {
        Write-Progress -Activity "PSSync" -Status "Synchronizing..." -PercentComplete 0
    }

    foreach ($DirectoryPath in $DirectoriesToCreate)
    {
        try
        {
            New-Item -ItemType Directory -Path $DirectoryPath -Force -ErrorAction Stop | Out-Null
            $CreatedDirectoryCount = $CreatedDirectoryCount + 1
            $CompletedExecutionOperationCount = $CompletedExecutionOperationCount + 1
            Write-Progress -Activity "PSSync" -Status "Created directory: $DirectoryPath" -PercentComplete ([int](($CompletedExecutionOperationCount / $TotalExecutionOperationCount) * 100))
            Write-Host "CREATED DIRECTORY: $DirectoryPath"
        }
        catch
        {
            $ErrorCount = $ErrorCount + 1
            Write-Host "ERROR: Unable to create directory: $DirectoryPath"
        }
    }

# +----------------------------------------------------------------------------+
# | File Copying                                                               |
# +----------------------------------------------------------------------------+
    foreach ($tmpFile in $FilesToCopy)
    {
        $RelativePath = $tmpFile.RelativePath
        $DestinationFilePath = Join-Path -Path $DestinationPath -ChildPath $RelativePath

        try
        {
            $Verified = Copy-PSSyncFile $tmpFile.SourceFile $DestinationFilePath $tmpFile.SourceHash "Copying"

            if ($Verified)
            {
                $CopiedCount = $CopiedCount + 1
                Write-Host "COPIED: $RelativePath"
            }
            else
            {
                $ErrorCount = $ErrorCount + 1
            }

            $CompletedExecutionOperationCount = $CompletedExecutionOperationCount + 1
            Write-Progress -Activity "PSSync" -Status "Completed: $RelativePath" -PercentComplete ([int](($CompletedExecutionOperationCount / $TotalExecutionOperationCount) * 100))
        }
        catch
        {
            $ErrorCount = $ErrorCount + 1
            $CompletedExecutionOperationCount = $CompletedExecutionOperationCount + 1
            Write-Progress -Activity "PSSync" -Status "Failed: $RelativePath" -PercentComplete ([int](($CompletedExecutionOperationCount / $TotalExecutionOperationCount) * 100))
            Write-Host "ERROR: Unable to copy file: $RelativePath"
        }
    }

# +----------------------------------------------------------------------------+
# | File Updates                                                               |
# +----------------------------------------------------------------------------+
    foreach ($tmpFile in $FilesToUpdate)
    {
        try
        {
            $Verified = Copy-PSSyncFile $tmpFile.SourceFile $tmpFile.DestinationFilePath $tmpFile.SourceHash "Updating"

            if ($Verified)
            {
                $UpdatedCount = $UpdatedCount + 1
                Write-Host "UPDATED: $($tmpFile.RelativePath)"
            }
            else
            {
                $ErrorCount = $ErrorCount + 1
            }

            $CompletedExecutionOperationCount = $CompletedExecutionOperationCount + 1
            Write-Progress -Activity "PSSync" -Status "Completed: $($tmpFile.RelativePath)" -PercentComplete ([int](($CompletedExecutionOperationCount / $TotalExecutionOperationCount) * 100))
        }
        catch
        {
            $ErrorCount = $ErrorCount + 1
            $CompletedExecutionOperationCount = $CompletedExecutionOperationCount + 1
            Write-Progress -Activity "PSSync" -Status "Failed: $($tmpFile.RelativePath)" -PercentComplete ([int](($CompletedExecutionOperationCount / $TotalExecutionOperationCount) * 100))
            Write-Host "ERROR: Unable to update file: $($tmpFile.RelativePath)"
        }
    }

# +----------------------------------------------------------------------------+
# | Unchanged Files                                                            |
# +----------------------------------------------------------------------------+
    foreach ($RelativePath in $FilesToLeaveAlone)
    {
        $UnchangedCount = $UnchangedCount + 1

        if (-not $ChangesOnly)
        {
            Write-Host "UNCHANGED: $RelativePath"
        }

        $CompletedExecutionOperationCount = $CompletedExecutionOperationCount + 1
        Write-Progress -Activity "PSSync" -Status "Unchanged: $RelativePath" -PercentComplete ([int](($CompletedExecutionOperationCount / $TotalExecutionOperationCount) * 100))
    }

# +----------------------------------------------------------------------------+
# | Mirror File Deletion                                                       |
# +----------------------------------------------------------------------------+
    if ($Mirror)
    {
        foreach ($tmpFile in $FilesToDelete)
        {
            $RelativePath = Get-PSSyncRelativePath $DestinationPath $tmpFile.FullName

            try
            {
                Remove-Item -LiteralPath $tmpFile.FullName -Force -ErrorAction Stop
                $DeletedFileCount = $DeletedFileCount + 1
                $CompletedExecutionOperationCount = $CompletedExecutionOperationCount + 1
                Write-Progress -Activity "PSSync" -Status "Deleted: $RelativePath" -PercentComplete ([int](($CompletedExecutionOperationCount / $TotalExecutionOperationCount) * 100))
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
                $CompletedExecutionOperationCount = $CompletedExecutionOperationCount + 1
                Write-Progress -Activity "PSSync" -Status "Deleted directory: $RelativePath" -PercentComplete ([int](($CompletedExecutionOperationCount / $TotalExecutionOperationCount) * 100))
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

            $CompletedExecutionOperationCount = $CompletedExecutionOperationCount + 1
            Write-Progress -Activity "PSSync" -Status "Retained extraneous file: $RelativePath" -PercentComplete ([int](($CompletedExecutionOperationCount / $TotalExecutionOperationCount) * 100))
        }
    }

    if ($TotalExecutionOperationCount -gt 0)
    {
        Write-Progress -Activity "PSSync" -Status "Synchronization complete." -PercentComplete 100
        Start-Sleep -Milliseconds 100
        Write-Progress -Activity "PSSync" -Completed
    }

# +----------------------------------------------------------------------------+
# | Final Summary                                                              |
# +----------------------------------------------------------------------------+
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
