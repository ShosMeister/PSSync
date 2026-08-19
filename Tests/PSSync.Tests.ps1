# +------------------------------------------------------------------------+
# | PSSync Tests                                                           |
# +------------------------------------------------------------------------+
# | Purpose:                                                               |
# | Provides automated tests for the PSSync PowerShell module.             |
# |                                                                        |
# | Responsibilities:                                                      |
# | - Load the PSSync module for testing.                                  |
# | - Verify that the PSSync command is available.                         |
# | - Verify that missing source files are copied to the destination.      |
# | - Provide the foundation for additional synchronization tests.         |
# |                                                                        |
# | Current Status:                                                        |
# | - Module-loading test implemented.                                     |
# | - Missing-file synchronization test implemented.                       |
# | - Additional synchronization tests will be added incrementally.        |
# +------------------------------------------------------------------------+

$ModulePath = Join-Path -Path $PSScriptRoot -ChildPath "..\PSSync.psm1"

Import-Module $ModulePath -Force


Describe "PSSync Module" {

    It "Loads the PSSync command" {
        $Command = Get-Command PSSync -ErrorAction SilentlyContinue
        $Command | Should Not BeNullOrEmpty
    }


    It "Copies a missing source file to the destination" {
        $TestRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("PSSyncTest_" + [System.Guid]::NewGuid().ToString())

        $SourcePath = Join-Path -Path $TestRoot -ChildPath "Source"
        $DestinationPath = Join-Path -Path $TestRoot -ChildPath "Destination"
        $SourceFilePath = Join-Path -Path $SourcePath -ChildPath "TestFile.txt"
        $DestinationFilePath = Join-Path -Path $DestinationPath -ChildPath "TestFile.txt"

        try
        {
            New-Item -ItemType Directory -Path $SourcePath -Force | Out-Null

            Set-Content -Path $SourceFilePath -Value "PSSync test file"

            PSSync $SourcePath $DestinationPath

            $DestinationFileExists = Test-Path -LiteralPath $DestinationFilePath -PathType Leaf

            $DestinationFileExists | Should Be $true

            $DestinationContents = Get-Content -LiteralPath $DestinationFilePath -Raw

            $DestinationContents.Trim() | Should Be "PSSync test file"
        }
        finally
        {
            if (Test-Path -LiteralPath $TestRoot)
            {
                Remove-Item -LiteralPath $TestRoot -Recurse -Force
            }
        }
    }

    It "Updates an older destination file when the source is newer" {

        $TestRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("PSSyncTest_" + [System.Guid]::NewGuid().ToString())

        $SourcePath = Join-Path -Path $TestRoot -ChildPath "Source"
        $DestinationPath = Join-Path -Path $TestRoot -ChildPath "Destination"
        $SourceFilePath = Join-Path -Path $SourcePath -ChildPath "TestFile.txt"
        $DestinationFilePath = Join-Path -Path $DestinationPath -ChildPath "TestFile.txt"

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

            $DestinationContents = Get-Content -LiteralPath $DestinationFilePath -Raw

            $DestinationContents.Trim() | Should Be "NEW SOURCE CONTENT"
        }
        finally
        {
            if (Test-Path -LiteralPath $TestRoot)
            {
                Remove-Item -LiteralPath $TestRoot -Recurse -Force
            }
        }
    }

    It "Leaves a newer destination file unchanged" {

        $TestRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("PSSyncTest_" + [System.Guid]::NewGuid().ToString())

        $SourcePath = Join-Path -Path $TestRoot -ChildPath "Source"
        $DestinationPath = Join-Path -Path $TestRoot -ChildPath "Destination"
        $SourceFilePath = Join-Path -Path $SourcePath -ChildPath "TestFile.txt"
        $DestinationFilePath = Join-Path -Path $DestinationPath -ChildPath "TestFile.txt"

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

            $DestinationContents = Get-Content -LiteralPath $DestinationFilePath -Raw

            $DestinationContents.Trim() | Should Be "NEW DESTINATION CONTENT"
        }
        finally
        {
            if (Test-Path -LiteralPath $TestRoot)
            {
                Remove-Item -LiteralPath $TestRoot -Recurse -Force
            }
        }
    }

    It "Leaves an extraneous destination file unchanged in normal mode" {

        $TestRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("PSSyncTest_" + [System.Guid]::NewGuid().ToString())

        $SourcePath = Join-Path -Path $TestRoot -ChildPath "Source"
        $DestinationPath = Join-Path -Path $TestRoot -ChildPath "Destination"
        $SourceFilePath = Join-Path -Path $SourcePath -ChildPath "TestFile.txt"
        $DestinationFilePath = Join-Path -Path $DestinationPath -ChildPath "TestFile.txt"
        $ExtraneousFilePath = Join-Path -Path $DestinationPath -ChildPath "ExtraFile.txt"

        try
        {
            New-Item -ItemType Directory -Path $SourcePath -Force | Out-Null
            New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null

            Set-Content -Path $SourceFilePath -Value "SOURCE CONTENT"
            Set-Content -Path $DestinationFilePath -Value "DESTINATION CONTENT"
            Set-Content -Path $ExtraneousFilePath -Value "EXTRANEOUS CONTENT"

            PSSync $SourcePath $DestinationPath

            $ExtraneousFileExists = Test-Path -LiteralPath $ExtraneousFilePath -PathType Leaf

            $ExtraneousFileExists | Should Be $true

            $ExtraneousContents = Get-Content -LiteralPath $ExtraneousFilePath -Raw

            $ExtraneousContents.Trim() | Should Be "EXTRANEOUS CONTENT"
        }
        finally
        {
            if (Test-Path -LiteralPath $TestRoot)
            {
                Remove-Item -LiteralPath $TestRoot -Recurse -Force
            }
        }
    }

    It "Deletes an extraneous destination file in Mirror mode" {

        $TestRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("PSSyncTest_" + [System.Guid]::NewGuid().ToString())

        $SourcePath = Join-Path -Path $TestRoot -ChildPath "Source"
        $DestinationPath = Join-Path -Path $TestRoot -ChildPath "Destination"
        $SourceFilePath = Join-Path -Path $SourcePath -ChildPath "TestFile.txt"
        $DestinationFilePath = Join-Path -Path $DestinationPath -ChildPath "TestFile.txt"
        $ExtraneousFilePath = Join-Path -Path $DestinationPath -ChildPath "ExtraFile.txt"

        try
        {
            New-Item -ItemType Directory -Path $SourcePath -Force | Out-Null
            New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null

            Set-Content -Path $SourceFilePath -Value "SOURCE CONTENT"
            Set-Content -Path $DestinationFilePath -Value "DESTINATION CONTENT"
            Set-Content -Path $ExtraneousFilePath -Value "EXTRANEOUS CONTENT"

            PSSync $SourcePath $DestinationPath -Mirror

            $ExtraneousFileExists = Test-Path -LiteralPath $ExtraneousFilePath -PathType Leaf

            $ExtraneousFileExists | Should Be $false

            $DestinationFileExists = Test-Path -LiteralPath $DestinationFilePath -PathType Leaf

            $DestinationFileExists | Should Be $true
        }
        finally
        {
            if (Test-Path -LiteralPath $TestRoot)
            {
                Remove-Item -LiteralPath $TestRoot -Recurse -Force
            }
        }
    }


    It "Deletes an extraneous file inside a destination subdirectory in Mirror mode" {

        $TestRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("PSSyncTest_" + [System.Guid]::NewGuid().ToString())

        $SourcePath = Join-Path -Path $TestRoot -ChildPath "Source"
        $DestinationPath = Join-Path -Path $TestRoot -ChildPath "Destination"
        $SourceFilePath = Join-Path -Path $SourcePath -ChildPath "TestFile.txt"
        $DestinationFilePath = Join-Path -Path $DestinationPath -ChildPath "TestFile.txt"

        $ReportsPath = Join-Path -Path $DestinationPath -ChildPath "Reports"
        $ExtraneousFilePath = Join-Path -Path $ReportsPath -ChildPath "OldReport.txt"

        try
        {
            New-Item -ItemType Directory -Path $SourcePath -Force | Out-Null
            New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
            New-Item -ItemType Directory -Path $ReportsPath -Force | Out-Null

            Set-Content -Path $SourceFilePath -Value "SOURCE CONTENT"
            Set-Content -Path $DestinationFilePath -Value "DESTINATION CONTENT"
            Set-Content -Path $ExtraneousFilePath -Value "EXTRANEOUS CONTENT"

            PSSync $SourcePath $DestinationPath -Mirror

            $ExtraneousFileExists = Test-Path -LiteralPath $ExtraneousFilePath -PathType Leaf

            $ExtraneousFileExists | Should Be $false

            $DestinationFileExists = Test-Path -LiteralPath $DestinationFilePath -PathType Leaf

            $DestinationFileExists | Should Be $true
        }
        finally
        {
            if (Test-Path -LiteralPath $TestRoot)
            {
                Remove-Item -LiteralPath $TestRoot -Recurse -Force
            }
        }
    }

    It "Deletes all empty extraneous parent directories in Mirror mode" {

        $TestRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("PSSyncTest_" + [System.Guid]::NewGuid().ToString())

        $SourcePath = Join-Path -Path $TestRoot -ChildPath "Source"
        $DestinationPath = Join-Path -Path $TestRoot -ChildPath "Destination"
        $SourceFilePath = Join-Path -Path $SourcePath -ChildPath "TestFile.txt"
        $DestinationFilePath = Join-Path -Path $DestinationPath -ChildPath "TestFile.txt"

        $OldProjectPath = Join-Path -Path $DestinationPath -ChildPath "OldProject"
        $ArchivePath = Join-Path -Path $OldProjectPath -ChildPath "Archive"
        $YearPath = Join-Path -Path $ArchivePath -ChildPath "2025"
        $ExtraneousFilePath = Join-Path -Path $YearPath -ChildPath "OldFile.txt"

        try
        {
            New-Item -ItemType Directory -Path $SourcePath -Force | Out-Null
            New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
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
            if (Test-Path -LiteralPath $TestRoot)
            {
                Remove-Item -LiteralPath $TestRoot -Recurse -Force
            }
        }
    }

    It "Reports changes without modifying files in WhatIf mode" {

        $TestRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("PSSyncTest_" + [System.Guid]::NewGuid().ToString())

        $SourcePath = Join-Path -Path $TestRoot -ChildPath "Source"
        $DestinationPath = Join-Path -Path $TestRoot -ChildPath "Destination"

        $SourceFilePath = Join-Path -Path $SourcePath -ChildPath "TestFile.txt"
        $DestinationFilePath = Join-Path -Path $DestinationPath -ChildPath "TestFile.txt"
        $ExtraneousFilePath = Join-Path -Path $DestinationPath -ChildPath "ExtraFile.txt"

        try
        {
            New-Item -ItemType Directory -Path $SourcePath -Force | Out-Null
            New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null

            Set-Content -Path $SourceFilePath -Value "NEW SOURCE CONTENT"
            Set-Content -Path $DestinationFilePath -Value "OLD DESTINATION CONTENT"
            Set-Content -Path $ExtraneousFilePath -Value "EXTRANEOUS CONTENT"

            $DestinationBefore = Get-Content -LiteralPath $DestinationFilePath -Raw
            $ExtraneousBefore = Get-Content -LiteralPath $ExtraneousFilePath -Raw

            PSSync $SourcePath $DestinationPath -Mirror -WhatIf

            $DestinationAfter = Get-Content -LiteralPath $DestinationFilePath -Raw
            $ExtraneousAfter = Get-Content -LiteralPath $ExtraneousFilePath -Raw

            $DestinationAfter.Trim() | Should Be "OLD DESTINATION CONTENT"
            $ExtraneousAfter.Trim() | Should Be "EXTRANEOUS CONTENT"

            Test-Path -LiteralPath $DestinationFilePath -PathType Leaf |
                Should Be $true

            Test-Path -LiteralPath $ExtraneousFilePath -PathType Leaf |
                Should Be $true
        }
        finally
        {
            if (Test-Path -LiteralPath $TestRoot)
            {
                Remove-Item -LiteralPath $TestRoot -Recurse -Force
            }
        }
    }

    It "Reports creation without creating files in WhatIf mode when the destination is missing" {

        $TestRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("PSSyncTest_" + [System.Guid]::NewGuid().ToString())

        $SourcePath = Join-Path -Path $TestRoot -ChildPath "Source"
        $DestinationPath = Join-Path -Path $TestRoot -ChildPath "Destination"

        $SourceFilePath = Join-Path -Path $SourcePath -ChildPath "TestFile.txt"
        $DestinationFilePath = Join-Path -Path $DestinationPath -ChildPath "TestFile.txt"

        try
        {
            New-Item -ItemType Directory -Path $SourcePath -Force | Out-Null

            Set-Content -Path $SourceFilePath -Value "SOURCE CONTENT"

            PSSync $SourcePath $DestinationPath -WhatIf

            Test-Path -LiteralPath $DestinationPath -PathType Container |
                Should Be $false

            Test-Path -LiteralPath $DestinationFilePath -PathType Leaf |
                Should Be $false
        }
        finally
        {
            if (Test-Path -LiteralPath $TestRoot)
            {
                Remove-Item -LiteralPath $TestRoot -Recurse -Force
            }
        }
    }

    It "Creates nested source directories and copies their files" {

        $TestRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("PSSyncTest_" + [System.Guid]::NewGuid().ToString())

        $SourcePath = Join-Path -Path $TestRoot -ChildPath "Source"
        $DestinationPath = Join-Path -Path $TestRoot -ChildPath "Destination"

        $SourceReportsPath = Join-Path -Path $SourcePath -ChildPath "Reports"
        $SourceFilePath = Join-Path -Path $SourceReportsPath -ChildPath "January.xlsx"

        $DestinationReportsPath = Join-Path -Path $DestinationPath -ChildPath "Reports"
        $DestinationFilePath = Join-Path -Path $DestinationReportsPath -ChildPath "January.xlsx"

        try
        {
            New-Item -ItemType Directory -Path $SourceReportsPath -Force | Out-Null

            Set-Content -Path $SourceFilePath -Value "JANUARY SOURCE"

            PSSync $SourcePath $DestinationPath

            Test-Path -LiteralPath $DestinationReportsPath -PathType Container |
                Should Be $true

            Test-Path -LiteralPath $DestinationFilePath -PathType Leaf |
                Should Be $true

            $DestinationContents = Get-Content -LiteralPath $DestinationFilePath -Raw

            $DestinationContents.Trim() | Should Be "JANUARY SOURCE"
        }
        finally
        {
            if (Test-Path -LiteralPath $TestRoot)
            {
                Remove-Item -LiteralPath $TestRoot -Recurse -Force
            }
        }
    }

    It "Updates a newer file in an existing nested directory" {

        $TestRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("PSSyncTest_" + [System.Guid]::NewGuid().ToString())

        $SourcePath = Join-Path -Path $TestRoot -ChildPath "Source"
        $DestinationPath = Join-Path -Path $TestRoot -ChildPath "Destination"

        $SourceReportsPath = Join-Path -Path $SourcePath -ChildPath "Reports"
        $DestinationReportsPath = Join-Path -Path $DestinationPath -ChildPath "Reports"

        $SourceFilePath = Join-Path -Path $SourceReportsPath -ChildPath "January.xlsx"
        $DestinationFilePath = Join-Path -Path $DestinationReportsPath -ChildPath "January.xlsx"

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

            $DestinationContents = Get-Content -LiteralPath $DestinationFilePath -Raw

            $DestinationContents.Trim() | Should Be "NEW JANUARY SOURCE"

            Test-Path -LiteralPath $DestinationReportsPath -PathType Container |
                Should Be $true
        }
        finally
        {
            if (Test-Path -LiteralPath $TestRoot)
            {
                Remove-Item -LiteralPath $TestRoot -Recurse -Force
            }
        }
    }

    It "Handles multiple synchronization outcomes in one run" {

        $TestRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("PSSyncTest_" + [System.Guid]::NewGuid().ToString())

        $SourcePath = Join-Path -Path $TestRoot -ChildPath "Source"
        $DestinationPath = Join-Path -Path $TestRoot -ChildPath "Destination"

        $SourceReportsPath = Join-Path -Path $SourcePath -ChildPath "Reports"
        $DestinationReportsPath = Join-Path -Path $DestinationPath -ChildPath "Reports"

        try
        {
            New-Item -ItemType Directory -Path $SourceReportsPath -Force | Out-Null
            New-Item -ItemType Directory -Path $DestinationReportsPath -Force | Out-Null

            $SourceFile1Path = Join-Path -Path $SourcePath -ChildPath "File1.txt"
            $DestinationFile1Path = Join-Path -Path $DestinationPath -ChildPath "File1.txt"

            $SourceFile2Path = Join-Path -Path $SourcePath -ChildPath "File2.txt"
            $DestinationFile2Path = Join-Path -Path $DestinationPath -ChildPath "File2.txt"

            $SourceJanuaryPath = Join-Path -Path $SourceReportsPath -ChildPath "January.xlsx"
            $DestinationJanuaryPath = Join-Path -Path $DestinationReportsPath -ChildPath "January.xlsx"

            $SourceFebruaryPath = Join-Path -Path $SourceReportsPath -ChildPath "February.xlsx"
            $DestinationFebruaryPath = Join-Path -Path $DestinationReportsPath -ChildPath "February.xlsx"

            Set-Content -Path $SourceFile1Path -Value "FILE1 NEW SOURCE"
            Set-Content -Path $DestinationFile1Path -Value "FILE1 OLD DESTINATION"

            Set-Content -Path $SourceFile2Path -Value "FILE2 SAME CONTENT"
            Set-Content -Path $DestinationFile2Path -Value "FILE2 SAME CONTENT"

            Set-Content -Path $SourceJanuaryPath -Value "JANUARY NEW SOURCE"
            Set-Content -Path $DestinationJanuaryPath -Value "JANUARY OLD DESTINATION"

            Set-Content -Path $SourceFebruaryPath -Value "FEBRUARY SAME CONTENT"
            Set-Content -Path $DestinationFebruaryPath -Value "FEBRUARY SAME CONTENT"

            $SourceFile1 = Get-Item -LiteralPath $SourceFile1Path
            $DestinationFile1 = Get-Item -LiteralPath $DestinationFile1Path

            $DestinationFile1.LastWriteTime = $SourceFile1.LastWriteTime.AddMinutes(-10)

            $SourceJanuary = Get-Item -LiteralPath $SourceJanuaryPath
            $DestinationJanuary = Get-Item -LiteralPath $DestinationJanuaryPath

            $DestinationJanuary.LastWriteTime = $SourceJanuary.LastWriteTime.AddMinutes(-10)

            $SourceFile2 = Get-Item -LiteralPath $SourceFile2Path
            $DestinationFile2 = Get-Item -LiteralPath $DestinationFile2Path

            $DestinationFile2.LastWriteTime = $SourceFile2.LastWriteTime

            $SourceFebruary = Get-Item -LiteralPath $SourceFebruaryPath
            $DestinationFebruary = Get-Item -LiteralPath $DestinationFebruaryPath

            $DestinationFebruary.LastWriteTime = $SourceFebruary.LastWriteTime

            PSSync $SourcePath $DestinationPath

            $DestinationFile1Contents = Get-Content -LiteralPath $DestinationFile1Path -Raw
            $DestinationFile2Contents = Get-Content -LiteralPath $DestinationFile2Path -Raw
            $DestinationJanuaryContents = Get-Content -LiteralPath $DestinationJanuaryPath -Raw
            $DestinationFebruaryContents = Get-Content -LiteralPath $DestinationFebruaryPath -Raw

            $DestinationFile1Contents.Trim() | Should Be "FILE1 NEW SOURCE"
            $DestinationFile2Contents.Trim() | Should Be "FILE2 SAME CONTENT"
            $DestinationJanuaryContents.Trim() | Should Be "JANUARY NEW SOURCE"
            $DestinationFebruaryContents.Trim() | Should Be "FEBRUARY SAME CONTENT"
        }
        finally
        {
            if (Test-Path -LiteralPath $TestRoot)
            {
                Remove-Item -LiteralPath $TestRoot -Recurse -Force
            }
        }
    }
}
