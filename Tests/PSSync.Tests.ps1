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
}
