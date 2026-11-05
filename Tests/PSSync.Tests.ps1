# +----------------------------------------------------------------------------+
# | PSSync Tests                                                               |
# +----------------------------------------------------------------------------+
# | Purpose:                                                                   |
# | Provides automated tests for the PSSync PowerShell module.                 |
# |                                                                            |
# | Responsibilities:                                                          |
# | - Verify core synchronization behavior.                                    |
# | - Verify Mirror and WhatIf behavior.                                       |
# | - Verify validation and conflict handling.                                 |
# | - Verify SHA-256 transfer verification and the hashing self-test.          |
# +----------------------------------------------------------------------------+

$ModulePath = Join-Path -Path $PSScriptRoot -ChildPath "..\PSSync.psm1"

Import-Module $ModulePath -Force

function New-PSSyncTestRoot
{
    $TestRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) `
        -ChildPath ("PSSyncTest_" + [System.Guid]::NewGuid().ToString())

    New-Item -ItemType Directory -Path $TestRoot -Force | Out-Null

    return $TestRoot
}

function Remove-PSSyncTestRoot
{
    param(
        [Parameter(Mandatory = $true)]
        [string]$TestRoot
    )

    if (Test-Path -LiteralPath $TestRoot)
    {
        Remove-Item -LiteralPath $TestRoot -Recurse -Force
    }
}

Describe "PSSync Module" {

    It "Loads the PSSync command" {
        $Command = Get-Command PSSync -ErrorAction SilentlyContinue

        $Command | Should Not BeNullOrEmpty
    }

    It "Copies a missing source file to the destination" {
        $TestRoot = New-PSSyncTestRoot
        $SourcePath = Join-Path $TestRoot "Source"
        $DestinationPath = Join-Path $TestRoot "Destination"
        $SourceFilePath = Join-Path $SourcePath "TestFile.txt"
        $DestinationFilePath = Join-Path $DestinationPath "TestFile.txt"

        try
        {
            New-Item -ItemType Directory -Path $SourcePath -Force | Out-Null
            Set-Content -Path $SourceFilePath -Value "PSSync test file"

            PSSync $SourcePath $DestinationPath

            Test-Path -LiteralPath $DestinationFilePath -PathType Leaf |
                Should Be $true

            (Get-Content -LiteralPath $DestinationFilePath -Raw).Trim() |
                Should Be "PSSync test file"
        }
        finally
        {
            Remove-PSSyncTestRoot $TestRoot
        }
    }


    It "Preserves source creation and last-write timestamps when copying a new file" {
        $TestRoot = New-PSSyncTestRoot
        $SourcePath = Join-Path $TestRoot "Source"
        $DestinationPath = Join-Path $TestRoot "Destination"
        $SourceFilePath = Join-Path $SourcePath "TestFile.txt"
        $DestinationFilePath = Join-Path $DestinationPath "TestFile.txt"
        $SourceCreationTimeUtc = [datetime]::Parse("2025-01-01T08:15:00Z").ToUniversalTime()
        $SourceLastWriteTimeUtc = [datetime]::Parse("2026-03-14T16:45:00Z").ToUniversalTime()

        try
        {
            New-Item -ItemType Directory -Path $SourcePath -Force | Out-Null
            Set-Content -Path $SourceFilePath -Value "TIMESTAMP COPY TEST"

            [System.IO.File]::SetCreationTimeUtc($SourceFilePath, $SourceCreationTimeUtc)
            [System.IO.File]::SetLastWriteTimeUtc($SourceFilePath, $SourceLastWriteTimeUtc)

            PSSync $SourcePath $DestinationPath

            [System.IO.File]::GetCreationTimeUtc($DestinationFilePath) |
                Should Be $SourceCreationTimeUtc
            [System.IO.File]::GetLastWriteTimeUtc($DestinationFilePath) |
                Should Be $SourceLastWriteTimeUtc
        }
        finally
        {
            Remove-PSSyncTestRoot $TestRoot
        }
    }

    It "Preserves source creation and last-write timestamps when updating a file" {
        $TestRoot = New-PSSyncTestRoot
        $SourcePath = Join-Path $TestRoot "Source"
        $DestinationPath = Join-Path $TestRoot "Destination"
        $SourceFilePath = Join-Path $SourcePath "TestFile.txt"
        $DestinationFilePath = Join-Path $DestinationPath "TestFile.txt"
        $SourceCreationTimeUtc = [datetime]::Parse("2025-01-01T08:15:00Z").ToUniversalTime()
        $SourceLastWriteTimeUtc = [datetime]::Parse("2026-03-14T16:45:00Z").ToUniversalTime()
        $OldDestinationCreationTimeUtc = [datetime]::Parse("2024-02-01T09:30:00Z").ToUniversalTime()
        $OldDestinationLastWriteTimeUtc = [datetime]::Parse("2025-02-01T09:30:00Z").ToUniversalTime()

        try
        {
            New-Item -ItemType Directory -Path $SourcePath -Force | Out-Null
            New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null

            Set-Content -Path $SourceFilePath -Value "UPDATED SOURCE CONTENT"
            Set-Content -Path $DestinationFilePath -Value "OLD DESTINATION CONTENT"

            [System.IO.File]::SetCreationTimeUtc($SourceFilePath, $SourceCreationTimeUtc)
            [System.IO.File]::SetLastWriteTimeUtc($SourceFilePath, $SourceLastWriteTimeUtc)
            [System.IO.File]::SetCreationTimeUtc($DestinationFilePath, $OldDestinationCreationTimeUtc)
            [System.IO.File]::SetLastWriteTimeUtc($DestinationFilePath, $OldDestinationLastWriteTimeUtc)

            PSSync $SourcePath $DestinationPath

            (Get-Content -LiteralPath $DestinationFilePath -Raw).Trim() |
                Should Be "UPDATED SOURCE CONTENT"
            [System.IO.File]::GetCreationTimeUtc($DestinationFilePath) |
                Should Be $SourceCreationTimeUtc
            [System.IO.File]::GetLastWriteTimeUtc($DestinationFilePath) |
                Should Be $SourceLastWriteTimeUtc
        }
        finally
        {
            Remove-PSSyncTestRoot $TestRoot
        }
    }

    It "Leaves destination timestamps unchanged when no file transfer is needed" {
        $TestRoot = New-PSSyncTestRoot
        $SourcePath = Join-Path $TestRoot "Source"
        $DestinationPath = Join-Path $TestRoot "Destination"
        $SourceFilePath = Join-Path $SourcePath "TestFile.txt"
        $DestinationFilePath = Join-Path $DestinationPath "TestFile.txt"
        $SourceCreationTimeUtc = [datetime]::Parse("2025-01-01T08:15:00Z").ToUniversalTime()
        $SharedLastWriteTimeUtc = [datetime]::Parse("2026-03-14T16:45:00Z").ToUniversalTime()
        $DestinationCreationTimeUtc = [datetime]::Parse("2024-02-01T09:30:00Z").ToUniversalTime()

        try
        {
            New-Item -ItemType Directory -Path $SourcePath -Force | Out-Null
            New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null

            Set-Content -Path $SourceFilePath -Value "SAME AGE SOURCE"
            Set-Content -Path $DestinationFilePath -Value "UNCHANGED DESTINATION"

            [System.IO.File]::SetCreationTimeUtc($SourceFilePath, $SourceCreationTimeUtc)
            [System.IO.File]::SetLastWriteTimeUtc($SourceFilePath, $SharedLastWriteTimeUtc)
            [System.IO.File]::SetCreationTimeUtc($DestinationFilePath, $DestinationCreationTimeUtc)
            [System.IO.File]::SetLastWriteTimeUtc($DestinationFilePath, $SharedLastWriteTimeUtc)

            PSSync $SourcePath $DestinationPath

            (Get-Content -LiteralPath $DestinationFilePath -Raw).Trim() |
                Should Be "UNCHANGED DESTINATION"
            [System.IO.File]::GetCreationTimeUtc($DestinationFilePath) |
                Should Be $DestinationCreationTimeUtc
            [System.IO.File]::GetLastWriteTimeUtc($DestinationFilePath) |
                Should Be $SharedLastWriteTimeUtc
        }
        finally
        {
            Remove-PSSyncTestRoot $TestRoot
        }
    }

    It "Updates an older destination file when the source is newer" {
        $TestRoot = New-PSSyncTestRoot
        $SourcePath = Join-Path $TestRoot "Source"
        $DestinationPath = Join-Path $TestRoot "Destination"
        $SourceFilePath = Join-Path $SourcePath "TestFile.txt"
        $DestinationFilePath = Join-Path $DestinationPath "TestFile.txt"

        try
        {
            New-Item -ItemType Directory -Path $SourcePath -Force | Out-Null
            New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null

            Set-Content -Path $SourceFilePath -Value "NEW SOURCE CONTENT"
            Set-Content -Path $DestinationFilePath -Value "OLD DESTINATION CONTENT"

            $SourceFile = Get-Item -LiteralPath $SourceFilePath
            $DestinationFile = Get-Item -LiteralPath $DestinationFilePath
            $DestinationFile.LastWriteTime = $SourceFile.LastWriteTime.AddMinutes(-10)

            PSSync $SourcePath $DestinationPath

            (Get-Content -LiteralPath $DestinationFilePath -Raw).Trim() |
                Should Be "NEW SOURCE CONTENT"
        }
        finally
        {
            Remove-PSSyncTestRoot $TestRoot
        }
    }

    It "Leaves a newer destination file unchanged" {
        $TestRoot = New-PSSyncTestRoot
        $SourcePath = Join-Path $TestRoot "Source"
        $DestinationPath = Join-Path $TestRoot "Destination"
        $SourceFilePath = Join-Path $SourcePath "TestFile.txt"
        $DestinationFilePath = Join-Path $DestinationPath "TestFile.txt"

        try
        {
            New-Item -ItemType Directory -Path $SourcePath -Force | Out-Null
            New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null

            Set-Content -Path $SourceFilePath -Value "OLD SOURCE CONTENT"
            Set-Content -Path $DestinationFilePath -Value "NEW DESTINATION CONTENT"

            $SourceFile = Get-Item -LiteralPath $SourceFilePath
            $DestinationFile = Get-Item -LiteralPath $DestinationFilePath
            $SourceFile.LastWriteTime = $DestinationFile.LastWriteTime.AddMinutes(-10)

            PSSync $SourcePath $DestinationPath

            (Get-Content -LiteralPath $DestinationFilePath -Raw).Trim() |
                Should Be "NEW DESTINATION CONTENT"
        }
        finally
        {
            Remove-PSSyncTestRoot $TestRoot
        }
    }

    It "Leaves an extraneous destination file unchanged in normal mode" {
        $TestRoot = New-PSSyncTestRoot
        $SourcePath = Join-Path $TestRoot "Source"
        $DestinationPath = Join-Path $TestRoot "Destination"
        $SourceFilePath = Join-Path $SourcePath "TestFile.txt"
        $DestinationFilePath = Join-Path $DestinationPath "TestFile.txt"
        $ExtraneousFilePath = Join-Path $DestinationPath "ExtraFile.txt"

        try
        {
            New-Item -ItemType Directory -Path $SourcePath -Force | Out-Null
            New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null

            Set-Content -Path $SourceFilePath -Value "SOURCE CONTENT"
            Set-Content -Path $DestinationFilePath -Value "DESTINATION CONTENT"
            Set-Content -Path $ExtraneousFilePath -Value "EXTRANEOUS CONTENT"

            PSSync $SourcePath $DestinationPath

            Test-Path -LiteralPath $ExtraneousFilePath -PathType Leaf |
                Should Be $true

            (Get-Content -LiteralPath $ExtraneousFilePath -Raw).Trim() |
                Should Be "EXTRANEOUS CONTENT"
        }
        finally
        {
            Remove-PSSyncTestRoot $TestRoot
        }
    }

    It "Deletes an extraneous destination file in Mirror mode" {
        $TestRoot = New-PSSyncTestRoot
        $SourcePath = Join-Path $TestRoot "Source"
        $DestinationPath = Join-Path $TestRoot "Destination"
        $SourceFilePath = Join-Path $SourcePath "TestFile.txt"
        $DestinationFilePath = Join-Path $DestinationPath "TestFile.txt"
        $ExtraneousFilePath = Join-Path $DestinationPath "ExtraFile.txt"

        try
        {
            New-Item -ItemType Directory -Path $SourcePath -Force | Out-Null
            New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null

            Set-Content -Path $SourceFilePath -Value "SOURCE CONTENT"
            Set-Content -Path $DestinationFilePath -Value "DESTINATION CONTENT"
            Set-Content -Path $ExtraneousFilePath -Value "EXTRANEOUS CONTENT"

            PSSync $SourcePath $DestinationPath -Mirror

            Test-Path -LiteralPath $ExtraneousFilePath -PathType Leaf |
                Should Be $false

            Test-Path -LiteralPath $DestinationFilePath -PathType Leaf |
                Should Be $true
        }
        finally
        {
            Remove-PSSyncTestRoot $TestRoot
        }
    }

    It "Deletes an extraneous file inside a destination subdirectory in Mirror mode" {
        $TestRoot = New-PSSyncTestRoot
        $SourcePath = Join-Path $TestRoot "Source"
        $DestinationPath = Join-Path $TestRoot "Destination"
        $ReportsPath = Join-Path $DestinationPath "Reports"
        $SourceFilePath = Join-Path $SourcePath "TestFile.txt"
        $DestinationFilePath = Join-Path $DestinationPath "TestFile.txt"
        $ExtraneousFilePath = Join-Path $ReportsPath "OldReport.txt"

        try
        {
            New-Item -ItemType Directory -Path $SourcePath -Force | Out-Null
            New-Item -ItemType Directory -Path $ReportsPath -Force | Out-Null

            Set-Content -Path $SourceFilePath -Value "SOURCE CONTENT"
            Set-Content -Path $DestinationFilePath -Value "DESTINATION CONTENT"
            Set-Content -Path $ExtraneousFilePath -Value "EXTRANEOUS CONTENT"

            PSSync $SourcePath $DestinationPath -Mirror

            Test-Path -LiteralPath $ExtraneousFilePath -PathType Leaf |
                Should Be $false

            Test-Path -LiteralPath $DestinationFilePath -PathType Leaf |
                Should Be $true
        }
        finally
        {
            Remove-PSSyncTestRoot $TestRoot
        }
    }

    It "Deletes all empty extraneous parent directories in Mirror mode" {
        $TestRoot = New-PSSyncTestRoot
        $SourcePath = Join-Path $TestRoot "Source"
        $DestinationPath = Join-Path $TestRoot "Destination"
        $OldProjectPath = Join-Path $DestinationPath "OldProject"
        $ArchivePath = Join-Path $OldProjectPath "Archive"
        $YearPath = Join-Path $ArchivePath "2025"
        $SourceFilePath = Join-Path $SourcePath "TestFile.txt"
        $DestinationFilePath = Join-Path $DestinationPath "TestFile.txt"
        $ExtraneousFilePath = Join-Path $YearPath "OldFile.txt"

        try
        {
            New-Item -ItemType Directory -Path $SourcePath -Force | Out-Null
            New-Item -ItemType Directory -Path $YearPath -Force | Out-Null

            Set-Content -Path $SourceFilePath -Value "SOURCE CONTENT"
            Set-Content -Path $DestinationFilePath -Value "DESTINATION CONTENT"
            Set-Content -Path $ExtraneousFilePath -Value "EXTRANEOUS CONTENT"

            PSSync $SourcePath $DestinationPath -Mirror

            Test-Path -LiteralPath $ExtraneousFilePath -PathType Leaf |
                Should Be $false
            Test-Path -LiteralPath $YearPath -PathType Container |
                Should Be $false
            Test-Path -LiteralPath $ArchivePath -PathType Container |
                Should Be $false
            Test-Path -LiteralPath $OldProjectPath -PathType Container |
                Should Be $false
            Test-Path -LiteralPath $DestinationFilePath -PathType Leaf |
                Should Be $true
        }
        finally
        {
            Remove-PSSyncTestRoot $TestRoot
        }
    }

    It "Reports changes without modifying files in WhatIf mode" {
        $TestRoot = New-PSSyncTestRoot
        $SourcePath = Join-Path $TestRoot "Source"
        $DestinationPath = Join-Path $TestRoot "Destination"
        $SourceFilePath = Join-Path $SourcePath "TestFile.txt"
        $DestinationFilePath = Join-Path $DestinationPath "TestFile.txt"
        $ExtraneousFilePath = Join-Path $DestinationPath "ExtraFile.txt"

        try
        {
            New-Item -ItemType Directory -Path $SourcePath -Force | Out-Null
            New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null

            Set-Content -Path $SourceFilePath -Value "NEW SOURCE CONTENT"
            Set-Content -Path $DestinationFilePath -Value "OLD DESTINATION CONTENT"
            Set-Content -Path $ExtraneousFilePath -Value "EXTRANEOUS CONTENT"

            PSSync $SourcePath $DestinationPath -Mirror -WhatIf

            (Get-Content -LiteralPath $DestinationFilePath -Raw).Trim() |
                Should Be "OLD DESTINATION CONTENT"
            (Get-Content -LiteralPath $ExtraneousFilePath -Raw).Trim() |
                Should Be "EXTRANEOUS CONTENT"
        }
        finally
        {
            Remove-PSSyncTestRoot $TestRoot
        }
    }

    It "Reports creation without creating files in WhatIf mode when the destination is missing" {
        $TestRoot = New-PSSyncTestRoot
        $SourcePath = Join-Path $TestRoot "Source"
        $DestinationPath = Join-Path $TestRoot "Destination"
        $SourceFilePath = Join-Path $SourcePath "TestFile.txt"

        try
        {
            New-Item -ItemType Directory -Path $SourcePath -Force | Out-Null
            Set-Content -Path $SourceFilePath -Value "SOURCE CONTENT"

            PSSync $SourcePath $DestinationPath -WhatIf

            Test-Path -LiteralPath $DestinationPath -PathType Container |
                Should Be $false
            Test-Path -LiteralPath (Join-Path $DestinationPath "TestFile.txt") `
                -PathType Leaf | Should Be $false
        }
        finally
        {
            Remove-PSSyncTestRoot $TestRoot
        }
    }

    It "Creates nested source directories and copies their files" {
        $TestRoot = New-PSSyncTestRoot
        $SourcePath = Join-Path $TestRoot "Source"
        $DestinationPath = Join-Path $TestRoot "Destination"
        $SourceReportsPath = Join-Path $SourcePath "Reports"
        $SourceFilePath = Join-Path $SourceReportsPath "January.xlsx"
        $DestinationReportsPath = Join-Path $DestinationPath "Reports"
        $DestinationFilePath = Join-Path $DestinationReportsPath "January.xlsx"

        try
        {
            New-Item -ItemType Directory -Path $SourceReportsPath -Force | Out-Null
            Set-Content -Path $SourceFilePath -Value "JANUARY SOURCE"

            PSSync $SourcePath $DestinationPath

            Test-Path -LiteralPath $DestinationReportsPath -PathType Container |
                Should Be $true
            Test-Path -LiteralPath $DestinationFilePath -PathType Leaf |
                Should Be $true
            (Get-Content -LiteralPath $DestinationFilePath -Raw).Trim() |
                Should Be "JANUARY SOURCE"
        }
        finally
        {
            Remove-PSSyncTestRoot $TestRoot
        }
    }

    It "Updates a newer file in an existing nested directory" {
        $TestRoot = New-PSSyncTestRoot
        $SourcePath = Join-Path $TestRoot "Source"
        $DestinationPath = Join-Path $TestRoot "Destination"
        $SourceReportsPath = Join-Path $SourcePath "Reports"
        $DestinationReportsPath = Join-Path $DestinationPath "Reports"
        $SourceFilePath = Join-Path $SourceReportsPath "January.xlsx"
        $DestinationFilePath = Join-Path $DestinationReportsPath "January.xlsx"

        try
        {
            New-Item -ItemType Directory -Path $SourceReportsPath -Force | Out-Null
            New-Item -ItemType Directory -Path $DestinationReportsPath -Force | Out-Null

            Set-Content -Path $SourceFilePath -Value "NEW JANUARY SOURCE"
            Set-Content -Path $DestinationFilePath -Value "OLD JANUARY DESTINATION"

            $SourceFile = Get-Item -LiteralPath $SourceFilePath
            $DestinationFile = Get-Item -LiteralPath $DestinationFilePath
            $DestinationFile.LastWriteTime = $SourceFile.LastWriteTime.AddMinutes(-10)

            PSSync $SourcePath $DestinationPath

            (Get-Content -LiteralPath $DestinationFilePath -Raw).Trim() |
                Should Be "NEW JANUARY SOURCE"
            Test-Path -LiteralPath $DestinationReportsPath -PathType Container |
                Should Be $true
        }
        finally
        {
            Remove-PSSyncTestRoot $TestRoot
        }
    }

    It "Handles multiple synchronization outcomes in one run" {
        $TestRoot = New-PSSyncTestRoot
        $SourcePath = Join-Path $TestRoot "Source"
        $DestinationPath = Join-Path $TestRoot "Destination"
        $SourceReportsPath = Join-Path $SourcePath "Reports"
        $DestinationReportsPath = Join-Path $DestinationPath "Reports"

        try
        {
            New-Item -ItemType Directory -Path $SourceReportsPath -Force | Out-Null
            New-Item -ItemType Directory -Path $DestinationReportsPath -Force | Out-Null

            $SourceFile1Path = Join-Path $SourcePath "File1.txt"
            $DestinationFile1Path = Join-Path $DestinationPath "File1.txt"
            $SourceFile2Path = Join-Path $SourcePath "File2.txt"
            $DestinationFile2Path = Join-Path $DestinationPath "File2.txt"
            $SourceJanuaryPath = Join-Path $SourceReportsPath "January.xlsx"
            $DestinationJanuaryPath = Join-Path $DestinationReportsPath "January.xlsx"
            $SourceFebruaryPath = Join-Path $SourceReportsPath "February.xlsx"
            $DestinationFebruaryPath = Join-Path $DestinationReportsPath "February.xlsx"

            Set-Content $SourceFile1Path "FILE1 NEW SOURCE"
            Set-Content $DestinationFile1Path "FILE1 OLD DESTINATION"
            Set-Content $SourceFile2Path "FILE2 SAME CONTENT"
            Set-Content $DestinationFile2Path "FILE2 SAME CONTENT"
            Set-Content $SourceJanuaryPath "JANUARY NEW SOURCE"
            Set-Content $DestinationJanuaryPath "JANUARY OLD DESTINATION"
            Set-Content $SourceFebruaryPath "FEBRUARY SAME CONTENT"
            Set-Content $DestinationFebruaryPath "FEBRUARY SAME CONTENT"

            $SourceFile1 = Get-Item $SourceFile1Path
            $DestinationFile1 = Get-Item $DestinationFile1Path
            $DestinationFile1.LastWriteTime = $SourceFile1.LastWriteTime.AddMinutes(-10)

            $SourceJanuary = Get-Item $SourceJanuaryPath
            $DestinationJanuary = Get-Item $DestinationJanuaryPath
            $DestinationJanuary.LastWriteTime = $SourceJanuary.LastWriteTime.AddMinutes(-10)

            $SourceFile2 = Get-Item $SourceFile2Path
            $DestinationFile2 = Get-Item $DestinationFile2Path
            $DestinationFile2.LastWriteTime = $SourceFile2.LastWriteTime

            $SourceFebruary = Get-Item $SourceFebruaryPath
            $DestinationFebruary = Get-Item $DestinationFebruaryPath
            $DestinationFebruary.LastWriteTime = $SourceFebruary.LastWriteTime

            PSSync $SourcePath $DestinationPath

            (Get-Content $DestinationFile1Path -Raw).Trim() |
                Should Be "FILE1 NEW SOURCE"
            (Get-Content $DestinationFile2Path -Raw).Trim() |
                Should Be "FILE2 SAME CONTENT"
            (Get-Content $DestinationJanuaryPath -Raw).Trim() |
                Should Be "JANUARY NEW SOURCE"
            (Get-Content $DestinationFebruaryPath -Raw).Trim() |
                Should Be "FEBRUARY SAME CONTENT"
        }
        finally
        {
            Remove-PSSyncTestRoot $TestRoot
        }
    }

    It "Rejects a source directory that does not exist" {
        $TestRoot = New-PSSyncTestRoot
        $SourcePath = Join-Path $TestRoot "MissingSource"
        $DestinationPath = Join-Path $TestRoot "Destination"

        try
        {
            {
                PSSync $SourcePath $DestinationPath
            } | Should Throw
        }
        finally
        {
            Remove-PSSyncTestRoot $TestRoot
        }
    }

    It "Rejects source and destination when they are the same directory" {
        $TestRoot = New-PSSyncTestRoot

        try
        {
            {
                PSSync $TestRoot $TestRoot
            } | Should Throw
        }
        finally
        {
            Remove-PSSyncTestRoot $TestRoot
        }
    }

    It "Rejects a destination located inside the source directory" {
        $TestRoot = New-PSSyncTestRoot
        $SourcePath = Join-Path $TestRoot "Source"
        $DestinationPath = Join-Path $SourcePath "Destination"

        try
        {
            New-Item -ItemType Directory -Path $SourcePath -Force | Out-Null

            {
                PSSync $SourcePath $DestinationPath
            } | Should Throw
        }
        finally
        {
            Remove-PSSyncTestRoot $TestRoot
        }
    }

    It "Reports nested Mirror deletions without deleting them in WhatIf mode" {
        $TestRoot = New-PSSyncTestRoot
        $SourcePath = Join-Path $TestRoot "Source"
        $DestinationPath = Join-Path $TestRoot "Destination"
        $OldProjectPath = Join-Path $DestinationPath "OldProject"
        $ArchivePath = Join-Path $OldProjectPath "Archive"
        $YearPath = Join-Path $ArchivePath "2025"
        $SourceFilePath = Join-Path $SourcePath "TestFile.txt"
        $DestinationFilePath = Join-Path $DestinationPath "TestFile.txt"
        $ExtraneousFilePath = Join-Path $YearPath "OldFile.txt"

        try
        {
            New-Item -ItemType Directory -Path $SourcePath -Force | Out-Null
            New-Item -ItemType Directory -Path $YearPath -Force | Out-Null

            Set-Content $SourceFilePath "SOURCE CONTENT"
            Set-Content $DestinationFilePath "DESTINATION CONTENT"
            Set-Content $ExtraneousFilePath "EXTRANEOUS CONTENT"

            PSSync $SourcePath $DestinationPath -Mirror -WhatIf

            Test-Path $ExtraneousFilePath -PathType Leaf | Should Be $true
            Test-Path $YearPath -PathType Container | Should Be $true
            Test-Path $ArchivePath -PathType Container | Should Be $true
            Test-Path $OldProjectPath -PathType Container | Should Be $true
            Test-Path $DestinationFilePath -PathType Leaf | Should Be $true
        }
        finally
        {
            Remove-PSSyncTestRoot $TestRoot
        }
    }

    It "Reports nested directory creation without creating it in WhatIf mode" {
        $TestRoot = New-PSSyncTestRoot
        $SourcePath = Join-Path $TestRoot "Source"
        $DestinationPath = Join-Path $TestRoot "Destination"
        $SourceReportsPath = Join-Path $SourcePath "Reports"
        $SourceFilePath = Join-Path $SourceReportsPath "January.xlsx"
        $DestinationReportsPath = Join-Path $DestinationPath "Reports"

        try
        {
            New-Item -ItemType Directory -Path $SourceReportsPath -Force | Out-Null
            New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
            Set-Content $SourceFilePath "JANUARY SOURCE"

            PSSync $SourcePath $DestinationPath -WhatIf

            Test-Path $DestinationReportsPath -PathType Container | Should Be $false
            Test-Path (Join-Path $DestinationReportsPath "January.xlsx") `
                -PathType Leaf | Should Be $false
            Test-Path $DestinationPath -PathType Container | Should Be $true
        }
        finally
        {
            Remove-PSSyncTestRoot $TestRoot
        }
    }

    It "Reports mixed synchronization outcomes without changing the destination in WhatIf mode" {
        $TestRoot = New-PSSyncTestRoot
        $SourcePath = Join-Path $TestRoot "Source"
        $DestinationPath = Join-Path $TestRoot "Destination"
        $SourceReportsPath = Join-Path $SourcePath "Reports"
        $DestinationReportsPath = Join-Path $DestinationPath "Reports"

        try
        {
            New-Item -ItemType Directory -Path $SourceReportsPath -Force | Out-Null
            New-Item -ItemType Directory -Path $DestinationReportsPath -Force | Out-Null

            $SourceFile1Path = Join-Path $SourcePath "File1.txt"
            $DestinationFile1Path = Join-Path $DestinationPath "File1.txt"
            $SourceFile2Path = Join-Path $SourcePath "File2.txt"
            $DestinationFile2Path = Join-Path $DestinationPath "File2.txt"
            $SourceNewReportPath = Join-Path $SourceReportsPath "NewReport.xlsx"
            $DestinationNewReportPath = Join-Path $DestinationReportsPath "NewReport.xlsx"
            $DestinationOldFilePath = Join-Path $DestinationPath "OldFile.txt"

            Set-Content $SourceFile1Path "NEW FILE1 SOURCE"
            Set-Content $DestinationFile1Path "OLD FILE1 DESTINATION"
            Set-Content $SourceFile2Path "FILE2 SAME CONTENT"
            Set-Content $DestinationFile2Path "FILE2 SAME CONTENT"
            Set-Content $SourceNewReportPath "NEW REPORT SOURCE"
            Set-Content $DestinationOldFilePath "OLD EXTRANEOUS FILE"

            $SourceFile1 = Get-Item $SourceFile1Path
            $DestinationFile1 = Get-Item $DestinationFile1Path
            $DestinationFile1.LastWriteTime = $SourceFile1.LastWriteTime.AddMinutes(-10)

            $SourceFile2 = Get-Item $SourceFile2Path
            $DestinationFile2 = Get-Item $DestinationFile2Path
            $DestinationFile2.LastWriteTime = $SourceFile2.LastWriteTime

            PSSync $SourcePath $DestinationPath -Mirror -WhatIf

            (Get-Content $DestinationFile1Path -Raw).Trim() |
                Should Be "OLD FILE1 DESTINATION"
            (Get-Content $DestinationFile2Path -Raw).Trim() |
                Should Be "FILE2 SAME CONTENT"
            (Get-Content $DestinationOldFilePath -Raw).Trim() |
                Should Be "OLD EXTRANEOUS FILE"

            Test-Path $DestinationNewReportPath -PathType Leaf | Should Be $false
            Test-Path $DestinationOldFilePath -PathType Leaf | Should Be $true
        }
        finally
        {
            Remove-PSSyncTestRoot $TestRoot
        }
    }

    It "Handles an empty source directory" {
        $TestRoot = New-PSSyncTestRoot
        $SourcePath = Join-Path $TestRoot "Source"
        $DestinationPath = Join-Path $TestRoot "Destination"

        try
        {
            New-Item -ItemType Directory -Path $SourcePath -Force | Out-Null

            PSSync $SourcePath $DestinationPath

            Test-Path $DestinationPath -PathType Container | Should Be $true

            $DestinationFiles = Get-ChildItem -LiteralPath $DestinationPath `
                -Recurse -File

            $DestinationFiles.Count | Should Be 0
        }
        finally
        {
            Remove-PSSyncTestRoot $TestRoot
        }
    }

    It "Leaves destination files unchanged when the source is empty in normal mode" {
        $TestRoot = New-PSSyncTestRoot
        $SourcePath = Join-Path $TestRoot "Source"
        $DestinationPath = Join-Path $TestRoot "Destination"
        $DestinationFilePath = Join-Path $DestinationPath "ExistingFile.txt"

        try
        {
            New-Item -ItemType Directory -Path $SourcePath -Force | Out-Null
            New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
            Set-Content $DestinationFilePath "DESTINATION CONTENT"

            PSSync $SourcePath $DestinationPath

            Test-Path $DestinationFilePath -PathType Leaf | Should Be $true
            (Get-Content $DestinationFilePath -Raw).Trim() |
                Should Be "DESTINATION CONTENT"
        }
        finally
        {
            Remove-PSSyncTestRoot $TestRoot
        }
    }

    It "Deletes destination files when the source is empty in Mirror mode" {
        $TestRoot = New-PSSyncTestRoot
        $SourcePath = Join-Path $TestRoot "Source"
        $DestinationPath = Join-Path $TestRoot "Destination"
        $DestinationFilePath = Join-Path $DestinationPath "ExistingFile.txt"

        try
        {
            New-Item -ItemType Directory -Path $SourcePath -Force | Out-Null
            New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
            Set-Content $DestinationFilePath "DESTINATION CONTENT"

            PSSync $SourcePath $DestinationPath -Mirror

            Test-Path $DestinationFilePath -PathType Leaf | Should Be $false
        }
        finally
        {
            Remove-PSSyncTestRoot $TestRoot
        }
    }

    It "Reports an error when a source file conflicts with a destination directory" {
        $TestRoot = New-PSSyncTestRoot
        $SourcePath = Join-Path $TestRoot "Source"
        $DestinationPath = Join-Path $TestRoot "Destination"
        $SourceFilePath = Join-Path $SourcePath "Conflict.txt"
        $DestinationConflictPath = Join-Path $DestinationPath "Conflict.txt"

        try
        {
            New-Item -ItemType Directory -Path $SourcePath -Force | Out-Null
            New-Item -ItemType Directory -Path $DestinationConflictPath -Force | Out-Null
            Set-Content $SourceFilePath "SOURCE CONTENT"

            {
                PSSync $SourcePath $DestinationPath
            } | Should Throw

            Test-Path $DestinationConflictPath -PathType Container |
                Should Be $true
            Test-Path (Join-Path $DestinationConflictPath "Conflict.txt") `
                -PathType Leaf | Should Be $false
        }
        finally
        {
            Remove-PSSyncTestRoot $TestRoot
        }
    }

    It "Reports an error when a source directory conflicts with a destination file" {
        $TestRoot = New-PSSyncTestRoot
        $SourcePath = Join-Path $TestRoot "Source"
        $DestinationPath = Join-Path $TestRoot "Destination"
        $SourceConflictPath = Join-Path $SourcePath "Conflict.txt"
        $DestinationFilePath = Join-Path $DestinationPath "Conflict.txt"

        try
        {
            New-Item -ItemType Directory -Path $SourceConflictPath -Force | Out-Null
            New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
            Set-Content $DestinationFilePath "DESTINATION CONTENT"

            {
                PSSync $SourcePath $DestinationPath
            } | Should Throw

            Test-Path $SourceConflictPath -PathType Container | Should Be $true
            Test-Path $DestinationFilePath -PathType Leaf | Should Be $true
            (Get-Content $DestinationFilePath -Raw).Trim() |
                Should Be "DESTINATION CONTENT"
        }
        finally
        {
            Remove-PSSyncTestRoot $TestRoot
        }
    }

    It "Handles a destination path that is an existing file" {
        $TestRoot = New-PSSyncTestRoot
        $SourcePath = Join-Path $TestRoot "Source"
        $DestinationPath = Join-Path $TestRoot "Destination"
        $SourceFilePath = Join-Path $SourcePath "TestFile.txt"

        try
        {
            New-Item -ItemType Directory -Path $SourcePath -Force | Out-Null
            Set-Content $SourceFilePath "SOURCE CONTENT"
            Set-Content $DestinationPath "DESTINATION FILE"

            PSSync $SourcePath $DestinationPath

            Test-Path $DestinationPath -PathType Leaf | Should Be $true
            (Get-Content $DestinationPath -Raw).Trim() |
                Should Be "DESTINATION FILE"
            Test-Path (Join-Path $DestinationPath "TestFile.txt") `
                -PathType Leaf | Should Be $false
        }
        finally
        {
            Remove-PSSyncTestRoot $TestRoot
        }
    }

    It "Verifies a copied file against a known SHA-256 value" {
        $TestRoot = New-PSSyncTestRoot
        $SourcePath = Join-Path $TestRoot "Source"
        $DestinationPath = Join-Path $TestRoot "Destination"
        $SourceFilePath = Join-Path $SourcePath "TestFile.txt"
        $DestinationFilePath = Join-Path $DestinationPath "TestFile.txt"
        $ExpectedHash = "FFA0C65108DA11750103D21DF0737D222286E99C42AC91D5C7520248EA2B23F8"

        try
        {
            New-Item -ItemType Directory -Path $SourcePath -Force | Out-Null
            Set-Content -Path $SourceFilePath -Value "PSSync verification test"

            PSSync $SourcePath $DestinationPath

            Test-Path $DestinationFilePath -PathType Leaf | Should Be $true

            $HashAlgorithm = New-Object System.Security.Cryptography.SHA256Cng
            try
            {
                $HashBytes = $HashAlgorithm.ComputeHash(
                    [System.IO.File]::ReadAllBytes($DestinationFilePath)
                )
                $ActualHash = ([System.BitConverter]::ToString($HashBytes)).Replace(
                    "-", ""
                ).ToUpperInvariant()
            }
            finally
            {
                $HashAlgorithm.Dispose()
            }

            $ActualHash | Should Be $ExpectedHash
        }
        finally
        {
            Remove-PSSyncTestRoot $TestRoot
        }
    }

    It "Verifies an updated file against the expected contents" {
        $TestRoot = New-PSSyncTestRoot
        $SourcePath = Join-Path $TestRoot "Source"
        $DestinationPath = Join-Path $TestRoot "Destination"
        $SourceFilePath = Join-Path $SourcePath "TestFile.txt"
        $DestinationFilePath = Join-Path $DestinationPath "TestFile.txt"

        try
        {
            New-Item -ItemType Directory -Path $SourcePath -Force | Out-Null
            New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null

            Set-Content $SourceFilePath "UPDATED SOURCE CONTENT"
            Set-Content $DestinationFilePath "OLD DESTINATION CONTENT"

            $SourceFile = Get-Item $SourceFilePath
            $DestinationFile = Get-Item $DestinationFilePath
            $DestinationFile.LastWriteTime = $SourceFile.LastWriteTime.AddMinutes(-10)

            PSSync $SourcePath $DestinationPath

            (Get-Content $DestinationFilePath -Raw).Trim() |
                Should Be "UPDATED SOURCE CONTENT"
        }
        finally
        {
            Remove-PSSyncTestRoot $TestRoot
        }
    }

    It "Runs the SHA-256 self-test before synchronization" {
        $TestRoot = New-PSSyncTestRoot
        $SourcePath = Join-Path $TestRoot "Source"
        $DestinationPath = Join-Path $TestRoot "Destination"
        $SourceFilePath = Join-Path $SourcePath "TestFile.txt"

        try
        {
            New-Item -ItemType Directory -Path $SourcePath -Force | Out-Null
            Set-Content $SourceFilePath "SELF TEST SOURCE"

            PSSync $SourcePath $DestinationPath

            Test-Path $DestinationPath -PathType Container | Should Be $true
            Test-Path (Join-Path $DestinationPath "TestFile.txt") `
                -PathType Leaf | Should Be $true
        }
        finally
        {
            Remove-PSSyncTestRoot $TestRoot
        }
    }

    It "Does not modify the destination in WhatIf mode" {
        $TestRoot = New-PSSyncTestRoot
        $SourcePath = Join-Path $TestRoot "Source"
        $DestinationPath = Join-Path $TestRoot "Destination"
        $SourceFilePath = Join-Path $SourcePath "TestFile.txt"

        try
        {
            New-Item -ItemType Directory -Path $SourcePath -Force | Out-Null
            Set-Content $SourceFilePath "WHATIF SOURCE"

            PSSync $SourcePath $DestinationPath -WhatIf

            Test-Path $DestinationPath -PathType Container | Should Be $false
            Test-Path (Join-Path $DestinationPath "TestFile.txt") `
                -PathType Leaf | Should Be $false
        }
        finally
        {
            Remove-PSSyncTestRoot $TestRoot
        }
    }
}
