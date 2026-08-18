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
}
