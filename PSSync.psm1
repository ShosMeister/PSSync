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
# | - Includes hidden and system files and directories in enumeration.         |
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
# | - Hidden and system source and destination items are enumerated.            |
# | - A source file that does not exist in the destination is copied.          |
# | - A source file newer than its destination counterpart is copied.          |
# | - Copied and updated files retain source CreationTimeUtc and LastWriteTimeUtc.|
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
# | - Verified transfers preserve source creation and last-write timestamps.     |
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
#                                                                          |
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

function ConvertTo-PSSyncGlobRegex
{
    param([Parameter(Mandatory = $true)][string]$Pattern)

    $Regex = [System.Text.RegularExpressions.Regex]::Escape($Pattern.Replace('\', '/'))
    $Regex = $Regex.Replace('\*\*/', '(?:.*/)?')
    $Regex = $Regex.Replace('\*\*', '.*')
    $Regex = $Regex.Replace('\*', '[^/]*')
    $Regex = $Regex.Replace('\?', '[^/]')
    return $Regex
}

function Test-PSSyncExcludedPath
{
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.IEnumerable]$Patterns,
        [Parameter(Mandatory = $true)][bool]$IsDirectory
    )

    $NormalizedPath = $RelativePath.Replace('\', '/')
    $PathParts = @($NormalizedPath -split '/')

    foreach ($RawPattern in $Patterns)
    {
        $Pattern = ([string]$RawPattern).Trim().Replace('\', '/')
        if ([string]::IsNullOrWhiteSpace($Pattern) -or $Pattern.StartsWith('#')) { continue }

        $RootAnchored = $Pattern.StartsWith('/')
        if ($RootAnchored) { $Pattern = $Pattern.Substring(1) }
        $DirectoryOnly = $Pattern.EndsWith('/')
        if ($DirectoryOnly) { $Pattern = $Pattern.TrimEnd('/') }
        if ([string]::IsNullOrWhiteSpace($Pattern)) { continue }

        $HasSlash = $Pattern.Contains('/')
        $GlobRegex = ConvertTo-PSSyncGlobRegex -Pattern $Pattern
        $RegexOptions = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::CultureInvariant

        if (-not $HasSlash -and -not $RootAnchored)
        {
            for ($lp = 0; $lp -lt $PathParts.Count; $lp = $lp + 1)
            {
                if ([System.Text.RegularExpressions.Regex]::IsMatch($PathParts[$lp], ('^' + $GlobRegex + '$'), $RegexOptions))
                {
                    $IsMatchedPartDirectory = ($lp -lt ($PathParts.Count - 1)) -or $IsDirectory
                    if ($DirectoryOnly -and -not $IsMatchedPartDirectory) { continue }
                    if ($IsMatchedPartDirectory -or $lp -eq ($PathParts.Count - 1)) { return $true }
                }
            }
            continue
        }

        $CandidatePaths = @($NormalizedPath)
        if ($IsDirectory -or $DirectoryOnly)
        {
            $CandidatePaths = $CandidatePaths + ($NormalizedPath + '/')
        }

        $Suffix = if ($DirectoryOnly) { '(?:/.*)?' } else { '' }
        foreach ($CandidatePath in $CandidatePaths)
        {
            if ([System.Text.RegularExpressions.Regex]::IsMatch($CandidatePath, ('^' + $GlobRegex + $Suffix + '$'), $RegexOptions))
            {
                return $true
            }
        }
    }

    return $false
}

<#
    Get-PSSyncTree

    What it does:
        Walks a directory tree (including hidden and system items) and
        returns its files and directories, skipping anything that matches
        an exclusion pattern. Excluded directories are not walked into.

    Passed in:
        RootPath           Root directory to walk.
        ExclusionPatterns  Exclusion pattern lines (may be empty).
        TreeLabel          'SOURCE' or 'DESTINATION', for progress output.
        CollectExcluded    Also return the excluded items themselves
                           (used by -DeleteExcluded on the destination).

    Passed out:
        Object with Files, Directories, ExcludedCount, and ExcludedItems
        (the excluded files and top-level excluded directories; empty
        unless CollectExcluded is given).
#>
function Get-PSSyncTree
{
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.IEnumerable]$ExclusionPatterns,
        [Parameter(Mandatory = $true)][string]$TreeLabel,
        [switch]$CollectExcluded
    )

    $ExcludedItems = New-Object 'System.Collections.Generic.List[System.IO.FileSystemInfo]'
    $Files = New-Object 'System.Collections.Generic.List[System.IO.FileInfo]'
    $Directories = New-Object 'System.Collections.Generic.List[System.IO.DirectoryInfo]'
    $PendingDirectories = New-Object 'System.Collections.Generic.Stack[string]'
    $PendingDirectories.Push($RootPath)
    $ExcludedCount = 0
    $VisitedCount = 0

    while ($PendingDirectories.Count -gt 0)
    {
        $CurrentDirectory = $PendingDirectories.Pop()
        foreach ($Item in Get-ChildItem -LiteralPath $CurrentDirectory -Force -ErrorAction Stop)
        {
            $VisitedCount = $VisitedCount + 1
            if (($VisitedCount % 100) -eq 0)
            {
                Write-Progress -Activity 'PSSync' -Status ("Enumerating {0}: {1} items" -f $TreeLabel, $VisitedCount)
                Write-Host ("PROGRESS: Enumerated {0} tree items: {1}" -f $TreeLabel, $VisitedCount)
            }

            $RelativePath = Get-PSSyncRelativePath -SourcePath $RootPath -FilePath $Item.FullName
            if (Test-PSSyncExcludedPath -RelativePath $RelativePath -Patterns $ExclusionPatterns -IsDirectory ([bool]$Item.PSIsContainer))
            {
                $ExcludedCount = $ExcludedCount + 1
                Write-Host ("EXCLUDED {0}: {1}" -f $TreeLabel, $RelativePath)
                if ($CollectExcluded)
                {
                    $ExcludedItems.Add([System.IO.FileSystemInfo]$Item)
                }
                continue
            }

            if ($Item.PSIsContainer)
            {
                $Directories.Add([System.IO.DirectoryInfo]$Item)
                $PendingDirectories.Push($Item.FullName)
            }
            else
            {
                $Files.Add([System.IO.FileInfo]$Item)
            }
        }
    }

    return [PSCustomObject]@{
        Files = $Files
        Directories = $Directories
        ExcludedCount = $ExcludedCount
        ExcludedItems = $ExcludedItems
    }
}


# +----------------------------------------------------------------------------+
# | Get-PSSyncFileHash                                                         |
# +----------------------------------------------------------------------------+
# | Purpose:                                                                   |
# | Calculates the SHA-256 hash of a file using the runtime SHA-256 provider.  |
# |                                                                            |
# | Responsibilities:                                                          |
# | - Open the specified file for read access.                                 |
# | - Calculate its SHA-256 hash.                                              |
# | - Return the hash as a hexadecimal string.                                 |
# |                                                                            |
# | Inputs:                                                                    |
# | FilePath As String                                                         |
# | - The full path of the file to hash.                                      |
# |                                                                            |
# | Outputs:                                                                   |
# | Returns the SHA-256 hash as a hexadecimal string.                          |
# |                                                                            |
# | State Changes:                                                             |
# | - Does not modify the source file.                                        |
# |                                                                            |
# | Usage:                                                                     |
# | $Hash = Get-PSSyncFileHash $FilePath                                       |
# |                                                                            |
# | Error Handling:                                                            |
# | - File and cryptographic errors are allowed to terminate the caller.       |
# |                                                                            |
# | Limitations:                                                               |
# | - Requires a .NET runtime with SHA-256 support.                            |
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

        $HashAlgorithm = [System.Security.Cryptography.SHA256]::Create()
        $HashBytes = $HashAlgorithm.ComputeHash($FileStream)

        return ([System.BitConverter]::ToString($HashBytes)).Replace("-", "").ToUpperInvariant()
    }
    finally
    {
        # PowerShell comparison note:
        # $null is intentionally placed on the left side of these comparisons.
        # This avoids collection comparison behavior and is the recommended
        # PowerShell form, even though traditional coding practice often puts
        # the known value on the left.
        if ($null -ne $HashAlgorithm)
        {
            $HashAlgorithm.Dispose()
        }

        if ($null -ne $FileStream)
        {
            $FileStream.Dispose()
        }
    }
}

function Test-PSSyncFileTransient
{
    param([Parameter(Mandatory = $true)][System.Exception]$Exception)

    $CurrentException = $Exception
    while ($null -ne $CurrentException)
    {
        $NativeErrorCode = $CurrentException.HResult -band 0xFFFF
        if ($NativeErrorCode -eq 2 -or $NativeErrorCode -eq 3 -or $NativeErrorCode -eq 32 -or $NativeErrorCode -eq 33)
        {
            return $true
        }

        if ($CurrentException.Message -match 'being used by another process|used by another process|could not find (a part of )?(the )?path|could not find file')
        {
            return $true
        }

        $CurrentException = $CurrentException.InnerException
    }

    return $false
}


# +----------------------------------------------------------------------------+
# | Test-PSSyncHashing                                                        |
# +----------------------------------------------------------------------------+
# | Purpose:                                                                   |
# | Verifies that PSSync's SHA-256 hashing mechanism is available and          |
# | produces the expected result before synchronization modifies the          |
# | destination.                                                              |
# |                                                                            |
# | Responsibilities:                                                          |
# | - Create a temporary test file.                                           |
# | - Hash known test data using the same helper used for synchronization.     |
# | - Compare the result to the known SHA-256 value.                           |
# | - Remove the temporary test file.                                         |
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


<#
    Copy-PSSyncFile

    What it does:
        Copies one file with buffered .NET streams, calculating the source
        SHA-256 hash from the same bytes as they are copied, so the source
        is read only once. Then checks that the source did not change while
        it was being copied (same length and last-write time as when the
        copy started), hashes the destination, and compares the two hashes.
        On success the destination gets the source creation and last-write
        times.

        Verbose output (only shown when PSSync is run with -Verbose):
            COPYING: <file> (<bytes> bytes)     or UPDATING:, before the copy
            PROGRESS: <file> ...                about every 10 seconds
            VERIFYING: <file> (<bytes> bytes)   before the destination hash

    Passed in:
        SourceFile As FileInfo         The source file to copy.
        DestinationFilePath As String  The full destination path.
        Operation As String            'Copying' or 'Updating', for progress.

    Passed out:
        $true when the copy is complete and verified.
        $false when the source changed during the copy (deferred; the
        destination is marked old so it is retried next run, and
        $script:LastCopyWasDeferred is $true) or when the destination hash
        does not match (reported as an error).
        File-access errors are thrown to the caller.
#>
function Copy-PSSyncFile
{
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$SourceFile,

        [Parameter(Mandatory = $true)]
        [string]$DestinationFilePath,

        [Parameter(Mandatory = $true)]
        [string]$Operation
    )

    $BUFFER_SIZE = 1048576
    $VERBOSE_PROGRESS_SECONDS = 10
    $BytesCopied = [int64]0
    $SourceStream = $null
    $DestinationStream = $null
    $HashAlgorithm = $null
    $SourceHash = ''
    $script:LastCopyWasDeferred = $false

    $SourceFile.Refresh()
    $SourceLength = $SourceFile.Length
    $SourceLastWriteTimeUtc = $SourceFile.LastWriteTimeUtc
    $SourceCreationTimeUtc = $SourceFile.CreationTimeUtc

    $ProgressTimer = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Verbose ("{0}: {1} ({2} bytes)" -f $Operation.ToUpperInvariant(), $SourceFile.FullName, $SourceLength)

    try
    {
        $SourceStream = [System.IO.File]::Open(
            $SourceFile.FullName,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read
        )

        <#
            OpenOrCreate and then truncate, rather than FileMode Create:
            Windows refuses to replace an existing file that is hidden or
            system with Create ("Access denied"). Many NAS shares mark files
            whose names start with a dot as hidden, so Create fails on the
            second copy of files such as .gitignore. Truncating the opened
            file replaces its contents without that check.
        #>
        $DestinationStream = [System.IO.File]::Open(
            $DestinationFilePath,
            [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
        $DestinationStream.SetLength(0)

        $HashAlgorithm = [System.Security.Cryptography.SHA256]::Create()
        $Buffer = New-Object byte[] $BUFFER_SIZE
        $BytesRead = 0

        do
        {
            $BytesRead = $SourceStream.Read($Buffer, 0, $Buffer.Length)

            if ($BytesRead -gt 0)
            {
                $DestinationStream.Write($Buffer, 0, $BytesRead)
                [void]$HashAlgorithm.TransformBlock($Buffer, 0, $BytesRead, $null, 0)
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

                if ($ProgressTimer.Elapsed.TotalSeconds -ge $VERBOSE_PROGRESS_SECONDS)
                {
                    Write-Verbose ("PROGRESS: {0} {1}: {2:N1} MB / {3:N1} MB ({4}%)" -f $Operation, $SourceFile.FullName, ($BytesCopied / 1MB), ($SourceLength / 1MB), $PercentComplete)
                    $ProgressTimer.Restart()
                }
            }
        }
        while ($BytesRead -gt 0)

        [void]$HashAlgorithm.TransformFinalBlock((New-Object byte[] 0), 0, 0)
        $SourceHash = ([System.BitConverter]::ToString($HashAlgorithm.Hash)).Replace("-", "").ToUpperInvariant()
        $DestinationStream.Flush()
    }
    finally
    {
        if ($null -ne $HashAlgorithm)
        {
            $HashAlgorithm.Dispose()
        }

        if ($null -ne $DestinationStream)
        {
            $DestinationStream.Dispose()
        }

        if ($null -ne $SourceStream)
        {
            $SourceStream.Dispose()
        }
    }

    <#
        The source must be exactly as it was when the copy started.
    #>
    $SourceFile.Refresh()
    if ($SourceFile.Length -ne $SourceLength -or $BytesCopied -ne $SourceLength -or $SourceFile.LastWriteTimeUtc -ne $SourceLastWriteTimeUtc)
    {
        $script:LastCopyWasDeferred = $true
        try
        {
            [System.IO.File]::SetLastWriteTimeUtc($DestinationFilePath, (New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc)))
        }
        catch
        {
            Write-Host "WARNING: Could not mark the incomplete destination for retry: $DestinationFilePath"
        }
        Write-Host "DEFERRED TRANSIENT FILE: $($SourceFile.FullName); source changed during synchronization. It will be retried on the next run."
        return $false
    }

    Write-Progress -Activity "PSSync" -Status "Verifying destination: $($SourceFile.Name)" -PercentComplete 100
    Write-Verbose ("VERIFYING: {0} ({1} bytes)" -f $SourceFile.FullName, $SourceLength)

    $DestinationHash = Get-PSSyncFileHash $DestinationFilePath

    if ($DestinationHash -ne $SourceHash)
    {
        Write-Host "ERROR: Destination verification failed: $DestinationFilePath"
        return $false
    }

    [System.IO.File]::SetCreationTimeUtc(
        $DestinationFilePath,
        $SourceCreationTimeUtc
    )

    [System.IO.File]::SetLastWriteTimeUtc(
        $DestinationFilePath,
        $SourceLastWriteTimeUtc
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
# | - Calculate source hashes while copying (each source file is read once).  |
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
# | DeleteExcluded As Switch                                                   |
# | - Requires -Mirror. Destination items that match an exclusion pattern are  |
# |   deleted (excluded directories with everything in them), like rsync's     |
# |   --delete-excluded. Without it, excluded destination items are kept.      |
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
# | PSSync "C:\Source" "D:\Destination" -Mirror -ExcludeFrom X -DeleteExcluded |
# | PSSync "C:\Source" "D:\Destination" -ChangesOnly                           |
# |                                                                            |
# | Error Handling:                                                            |
# | Source validation errors generate terminating errors. File-system          |
# | operation errors are reported and included in the final error count.       |
# |                                                                            |
# | Limitations:                                                               |
# | - File synchronization decisions are based on LastWriteTimeUtc.            |
# | - Verified transfers preserve CreationTimeUtc and LastWriteTimeUtc.          |
# | - File contents are verified with SHA-256 after copy/update.               |
# | - Exclusions are supported from a text file with -ExcludeFrom.             |
# | - External logging is not currently supported.                             |
# +----------------------------------------------------------------------------+
function PSSync
{
    <#
    .SYNOPSIS
    Synchronizes files and directories from a source directory to a destination directory.

    .DESCRIPTION
    PSSync synchronizes missing and newer source files to a destination directory.
    It can optionally remove destination-only files and directories with -Mirror.

    PSSync uses LastWriteTimeUtc to determine whether an existing destination file
    needs to be transferred. Files that are copied or updated are verified using
    SHA-256 after transfer. Successful transfers also preserve the source
    CreationTimeUtc and LastWriteTimeUtc values at the destination.

    .PARAMETER Source
    The source directory to synchronize.

    .PARAMETER Destination
    The destination directory to synchronize.

    .PARAMETER Mirror
    Removes destination-only files and directories.

    .PARAMETER ChangesOnly
    Suppresses per-item messages for files that require no action.

    .PARAMETER ExcludeFrom
    Text file containing glob patterns for paths excluded from source and
    destination enumeration. Excluded destination content is preserved in Mirror mode
    unless -DeleteExcluded is also given.

    .PARAMETER DeleteExcluded
    Requires -Mirror. Deletes destination files and directories that match an
    exclusion pattern (excluded directories are deleted with their contents),
    like rsync's --delete-excluded. Use -WhatIf first to see what would be deleted.

    .EXAMPLE
    PSSync "C:\Source" "D:\Destination"

    .EXAMPLE
    PSSync "C:\Source" "D:\Destination" -Mirror

    .EXAMPLE
    PSSync "C:\Source" "D:\Destination" -Mirror -WhatIf

    .EXAMPLE
    PSSync "C:\Source" "D:\Destination" -ChangesOnly

    .EXAMPLE
    PSSync "C:\Source" "D:\Destination" -Mirror -ExcludeFrom ".\Exclusions.txt" -DeleteExcluded -WhatIf

    .NOTES
    PSSync performs a SHA-256 self-test before synchronization modifies the
    destination. PSSync does not claim FIPS 140 certification or compliance.
    #>

   [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Source,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$Destination,

        [Parameter()]
        [switch]$Mirror,
        [switch]$ChangesOnly,

        [Parameter()]
        [string]$ExcludeFrom,

        [Parameter()]
        [switch]$DeleteExcluded

    )

    $SourcePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Source)
    $DestinationPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Destination)

    $CopiedCount = 0
    $UpdatedCount = 0
    $UnchangedCount = 0
    $DeletedFileCount = 0
    $DeletedDirectoryCount = 0
    $DeletedExcludedCount = 0
    $CreatedDirectoryCount = 0
    $ErrorCount = 0
    $DeferredFileCount = 0
    $DeferredRelativePaths = @{}

    $WouldCopyCount = 0
    $WouldUpdateCount = 0
    $WouldLeaveAloneCount = 0
    $WouldDeleteFileCount = 0
    $WouldDeleteDirectoryCount = 0
    $WouldCreateDirectoryCount = 0
    $WouldDeleteExcludedCount = 0

    if ($DeleteExcluded -and -not $Mirror)
    {
        throw "-DeleteExcluded can only be used together with -Mirror."
    }

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

    $ExclusionPatterns = @()
    if (-not [string]::IsNullOrWhiteSpace($ExcludeFrom))
    {
        $ExcludeFilePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ExcludeFrom)
        if (-not (Test-Path -LiteralPath $ExcludeFilePath -PathType Leaf))
        {
            throw "The exclusion file does not exist: $ExcludeFilePath"
        }
        $ExclusionPatterns = @(Get-Content -LiteralPath $ExcludeFilePath -ErrorAction Stop)
        Write-Host ("Exclusion file: {0} ({1} rule lines)" -f $ExcludeFilePath, $ExclusionPatterns.Count)
    }

    Write-Progress -Activity "PSSync" -Status "Enumerating source tree..."
    $SourceTree = Get-PSSyncTree -RootPath $SourcePath -ExclusionPatterns $ExclusionPatterns -TreeLabel 'SOURCE'
    $SourceFiles = $SourceTree.Files
    $SourceDirectories = $SourceTree.Directories
    $ExcludedCount = [int]$SourceTree.ExcludedCount
    Write-Progress -Activity "PSSync" -Status ("Enumerating source tree... {0} files, {1} directories" -f $SourceFiles.Count, $SourceDirectories.Count)

# +----------------------------------------------------------------------------+
# | Enumerate Destination                                                      |
# +----------------------------------------------------------------------------+
    $DestinationFiles = New-Object 'System.Collections.Generic.List[System.IO.FileInfo]'
    $DestinationDirectories = New-Object 'System.Collections.Generic.List[System.IO.DirectoryInfo]'
    $ExcludedToDelete = New-Object 'System.Collections.Generic.List[System.IO.FileSystemInfo]'

    if ($DestinationExists)
    {
        Write-Progress -Activity "PSSync" -Status "Enumerating destination tree..."
        $DestinationTree = Get-PSSyncTree -RootPath $DestinationPath -ExclusionPatterns $ExclusionPatterns -TreeLabel 'DESTINATION' -CollectExcluded:$DeleteExcluded
        $DestinationFiles = $DestinationTree.Files
        $DestinationDirectories = $DestinationTree.Directories
        $ExcludedToDelete = $DestinationTree.ExcludedItems
        $ExcludedCount = $ExcludedCount + [int]$DestinationTree.ExcludedCount
        Write-Progress -Activity "PSSync" -Status ("Enumerating destination tree... {0} files, {1} directories" -f $DestinationFiles.Count, $DestinationDirectories.Count)
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
    <#
        Plan lists. Generic lists grow in place; a PowerShell array is
        copied in full every time an item is added, which gets slower and
        slower on large trees.
    #>
    $DirectoriesToCreate = New-Object 'System.Collections.Generic.List[string]'
    $FilesToCopy = New-Object 'System.Collections.Generic.List[object]'
    $FilesToUpdate = New-Object 'System.Collections.Generic.List[object]'
    $FilesToLeaveAlone = New-Object 'System.Collections.Generic.List[string]'
    $FilesToDelete = New-Object 'System.Collections.Generic.List[object]'
    $DirectoriesToDelete = New-Object 'System.Collections.Generic.List[object]'

    <#
        Lookup tables, keyed by relative path (case-insensitive, as on
        Windows and SMB shares). Built once from the trees already
        enumerated, so the plan never has to ask the source or destination
        (often a NAS over the network) about each item again.
    #>
    $SourceFileSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $SourceDirectorySet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $DestinationFileMap = [System.Collections.Generic.Dictionary[string, System.IO.FileInfo]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $DestinationDirectorySet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($tmpFile in $SourceFiles)
    {
        [void]$SourceFileSet.Add((Get-PSSyncRelativePath $SourcePath $tmpFile.FullName))
    }

    foreach ($tmpDirectory in $SourceDirectories)
    {
        [void]$SourceDirectorySet.Add((Get-PSSyncRelativePath $SourcePath $tmpDirectory.FullName))
    }

    foreach ($tmpFile in $DestinationFiles)
    {
        $DestinationFileMap[(Get-PSSyncRelativePath $DestinationPath $tmpFile.FullName)] = $tmpFile
    }

    foreach ($tmpDirectory in $DestinationDirectories)
    {
        [void]$DestinationDirectorySet.Add((Get-PSSyncRelativePath $DestinationPath $tmpDirectory.FullName))
    }

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

        if ($DestinationDirectorySet.Contains($RelativePath))
        {
            Write-Progress -Activity "PSSync" -Completed
            throw "File/directory conflict at relative path: $RelativePath"
        }
    }

    foreach ($tmpDirectory in $SourceDirectories)
    {
        $RelativePath = Get-PSSyncRelativePath $SourcePath $tmpDirectory.FullName

        if ($DestinationFileMap.ContainsKey($RelativePath))
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
        $DirectoriesToCreate.Add($DestinationPath)
    }

    foreach ($tmpDirectory in $SourceDirectories)
    {
        $RelativePath = Get-PSSyncRelativePath $SourcePath $tmpDirectory.FullName
        $DestinationDirectoryPath = Join-Path -Path $DestinationPath -ChildPath $RelativePath
        $DestinationDirectoryExists = $DestinationDirectorySet.Contains($RelativePath)

        if (-not $DestinationDirectoryExists)
        {
            $DirectoriesToCreate.Add($DestinationDirectoryPath)
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
            Write-Host ("PROGRESS: Analyzed source directories: {0} / {1}" -f $AnalyzedDirectoryCount, $TotalDirectoryCount)
        }
    }

    foreach ($tmpFile in $SourceFiles)
    {
        $RelativePath = Get-PSSyncRelativePath $SourcePath $tmpFile.FullName
        $DestinationFilePath = Join-Path -Path $DestinationPath -ChildPath $RelativePath

        <#
            The source hash is no longer calculated here. It is calculated
            while the file is copied, so unchanged files are never read and
            new or newer files are read only once.
        #>
        if (-not $DestinationFileMap.ContainsKey($RelativePath))
        {
            $FilesToCopy.Add([PSCustomObject]@{
                SourceFile = $tmpFile
                RelativePath = $RelativePath
            })
        }
        else
        {
            $DestinationFile = $DestinationFileMap[$RelativePath]
            $SourceIsNewer = $tmpFile.LastWriteTimeUtc -gt $DestinationFile.LastWriteTimeUtc

            if ($SourceIsNewer)
            {
                $FilesToUpdate.Add([PSCustomObject]@{
                    SourceFile = $tmpFile
                    DestinationFilePath = $DestinationFilePath
                    RelativePath = $RelativePath
                })
            }
            else
            {
                $FilesToLeaveAlone.Add($RelativePath)
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
            Write-Host ("PROGRESS: Analyzed files: {0} / {1}" -f $AnalyzedFileCount, $TotalFileCount)
        }
    }

    foreach ($tmpFile in $DestinationFiles)
    {
        $RelativePath = Get-PSSyncRelativePath $DestinationPath $tmpFile.FullName
        $SourceFileExists = $SourceFileSet.Contains($RelativePath)

        if ($DeferredRelativePaths.ContainsKey($RelativePath))
        {
            Write-Host ("PRESERVED DEFERRED DESTINATION: {0}" -f $RelativePath)
        }
        elseif (-not $SourceFileExists)
        {
            $FilesToDelete.Add($tmpFile)
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
            Write-Host ("PROGRESS: Analyzed files: {0} / {1}" -f $AnalyzedFileCount, $TotalFileCount)
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
            $SourceDirectoryExists = $SourceDirectorySet.Contains($RelativePath)

            if (-not $SourceDirectoryExists)
            {
                $DirectoriesToDelete.Add($tmpDirectory)
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
                Write-Host ("PROGRESS: Analyzed destination directories: {0} / {1}" -f $AnalyzedDirectoryCount, $TotalDirectoryCount)
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
            foreach ($tmpItem in $ExcludedToDelete)
            {
                $RelativePath = Get-PSSyncRelativePath $DestinationPath $tmpItem.FullName
                if ($tmpItem -is [System.IO.DirectoryInfo])
                {
                    Write-Host "WOULD DELETE EXCLUDED DIRECTORY: $RelativePath"
                }
                else
                {
                    Write-Host "WOULD DELETE EXCLUDED: $RelativePath"
                }
                $WouldDeleteExcludedCount = $WouldDeleteExcludedCount + 1
            }

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
        Write-Host "Would Delete Excluded:  $WouldDeleteExcludedCount"
        Write-Host "Would Create Dirs:      $WouldCreateDirectoryCount"
        Write-Host "Would Defer Transient:  $DeferredFileCount"
        Write-Host "Excluded Items:         $ExcludedCount"
        Write-Host "------------------------------"
        Write-Host "Source:                 $SourcePath"
        Write-Host "Destination:            $DestinationPath"

        return
    }

# +----------------------------------------------------------------------------+
# | Directory Creation                                                         |
# +----------------------------------------------------------------------------+
    $TotalExecutionOperationCount = $DirectoriesToCreate.Count + $FilesToCopy.Count + $FilesToUpdate.Count + $FilesToLeaveAlone.Count + $FilesToDelete.Count + $DirectoriesToDelete.Count + $ExcludedToDelete.Count
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
            $Verified = Copy-PSSyncFile -SourceFile $tmpFile.SourceFile -DestinationFilePath $DestinationFilePath -Operation "Copying"

            if ($Verified)
            {
                $CopiedCount = $CopiedCount + 1
                Write-Host "COPIED: $RelativePath"
            }
            elseif ($script:LastCopyWasDeferred)
            {
                $DeferredFileCount = $DeferredFileCount + 1
                $DeferredRelativePaths[$RelativePath] = $true
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
            $CompletedExecutionOperationCount = $CompletedExecutionOperationCount + 1
            Write-Progress -Activity "PSSync" -Status "Failed: $RelativePath" -PercentComplete ([int](($CompletedExecutionOperationCount / $TotalExecutionOperationCount) * 100))

            <#
                A file that is locked or disappeared (for example in use by
                another program) is deferred to the next run, not an error.
            #>
            <#
                Windows PowerShell 5.1 cannot open a path of MAX_PATH (260)
                characters or more. That is permanent, so it is an error,
                not a deferred file that would be skipped every run.
            #>
            if ($DestinationFilePath.Length -ge 260 -or $tmpFile.SourceFile.FullName.Length -ge 260)
            {
                $ErrorCount = $ErrorCount + 1
                Write-Host ("ERROR: Path too long (260 or more characters) to copy file: {0}; destination path is {1} characters" -f $RelativePath, $DestinationFilePath.Length)
            }
            elseif (Test-PSSyncFileTransient -Exception $_.Exception)
            {
                $DeferredFileCount = $DeferredFileCount + 1
                $DeferredRelativePaths[$RelativePath] = $true
                Write-Host ("DEFERRED TRANSIENT FILE: {0}; {1}" -f $RelativePath, $_.Exception.Message)
            }
            else
            {
                $ErrorCount = $ErrorCount + 1
                Write-Host ("ERROR: Unable to copy file: {0}; {1}" -f $RelativePath, $_.Exception.Message)
            }
        }
    }

# +----------------------------------------------------------------------------+
# | File Updates                                                               |
# +----------------------------------------------------------------------------+
    foreach ($tmpFile in $FilesToUpdate)
    {
        try
        {
            $Verified = Copy-PSSyncFile -SourceFile $tmpFile.SourceFile -DestinationFilePath $tmpFile.DestinationFilePath -Operation "Updating"

            if ($Verified)
            {
                $UpdatedCount = $UpdatedCount + 1
                Write-Host "UPDATED: $($tmpFile.RelativePath)"
            }
            elseif ($script:LastCopyWasDeferred)
            {
                $DeferredFileCount = $DeferredFileCount + 1
                $DeferredRelativePaths[$tmpFile.RelativePath] = $true
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
            $CompletedExecutionOperationCount = $CompletedExecutionOperationCount + 1
            Write-Progress -Activity "PSSync" -Status "Failed: $($tmpFile.RelativePath)" -PercentComplete ([int](($CompletedExecutionOperationCount / $TotalExecutionOperationCount) * 100))

            <#
                Windows PowerShell 5.1 cannot open a path of MAX_PATH (260)
                characters or more. That is permanent, so it is an error,
                not a deferred file that would be skipped every run.
            #>
            if ($tmpFile.DestinationFilePath.Length -ge 260 -or $tmpFile.SourceFile.FullName.Length -ge 260)
            {
                $ErrorCount = $ErrorCount + 1
                Write-Host ("ERROR: Path too long (260 or more characters) to update file: {0}; destination path is {1} characters" -f $tmpFile.RelativePath, $tmpFile.DestinationFilePath.Length)
            }
            elseif (Test-PSSyncFileTransient -Exception $_.Exception)
            {
                $DeferredFileCount = $DeferredFileCount + 1
                $DeferredRelativePaths[$tmpFile.RelativePath] = $true
                Write-Host ("DEFERRED TRANSIENT FILE: {0}; {1}" -f $tmpFile.RelativePath, $_.Exception.Message)
            }
            else
            {
                $ErrorCount = $ErrorCount + 1
                Write-Host ("ERROR: Unable to update file: {0}; {1}" -f $tmpFile.RelativePath, $_.Exception.Message)
            }
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
        <#
            -DeleteExcluded: remove excluded destination items first, so a
            destination-only directory that held only excluded items is
            empty when the directory deletions below run.
        #>
        foreach ($tmpItem in $ExcludedToDelete)
        {
            $RelativePath = Get-PSSyncRelativePath $DestinationPath $tmpItem.FullName
            $IsExcludedDirectory = $tmpItem -is [System.IO.DirectoryInfo]

            try
            {
                if ($IsExcludedDirectory)
                {
                    Remove-Item -LiteralPath $tmpItem.FullName -Recurse -Force -ErrorAction Stop
                    Write-Host "DELETED EXCLUDED DIRECTORY: $RelativePath"
                }
                else
                {
                    Remove-Item -LiteralPath $tmpItem.FullName -Force -ErrorAction Stop
                    Write-Host "DELETED EXCLUDED: $RelativePath"
                }
                $DeletedExcludedCount = $DeletedExcludedCount + 1
            }
            catch
            {
                $ErrorCount = $ErrorCount + 1
                Write-Host ("ERROR: Unable to delete excluded item: {0}; {1}" -f $RelativePath, $_.Exception.Message)
            }

            $CompletedExecutionOperationCount = $CompletedExecutionOperationCount + 1
            Write-Progress -Activity "PSSync" -Status "Deleted excluded: $RelativePath" -PercentComplete ([int](($CompletedExecutionOperationCount / $TotalExecutionOperationCount) * 100))
        }

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
    Write-Host "Deleted Excluded:    $DeletedExcludedCount"
    Write-Host "Errors:              $ErrorCount"
    Write-Host "Deferred Files:      $DeferredFileCount"
    Write-Host "Excluded Items:      $ExcludedCount"
    Write-Host "------------------------------"
    Write-Host "Source:              $SourcePath"
    Write-Host "Destination:         $DestinationPath"
}

Export-ModuleMember -Function PSSync
