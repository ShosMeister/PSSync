# +------------------------------------------------------------------------+
# | PSSync Tests                                                           |
# +------------------------------------------------------------------------+
# | Purpose:                                                               |
# | Provides automated tests for the PSSync PowerShell module.             |
# |                                                                        |
# | Responsibilities:                                                      |
# | - Load the PSSync module for testing.                                  |
# | - Verify that the PSSync command is available.                         |
# | - Provide the foundation for future synchronization tests.             |
# |                                                                        |
# | Current Status:                                                        |
# | - Initial module-loading test only.                                    |
# | - Additional synchronization tests will be added incrementally.        |
# +------------------------------------------------------------------------+

$ModulePath = Join-Path -Path $PSScriptRoot -ChildPath "..\PSSync.psm1"

Import-Module $ModulePath -Force

Describe "PSSync Module" {

    It "Loads the PSSync command" {

        $Command = Get-Command PSSync -ErrorAction SilentlyContinue

        $Command | Should Not BeNullOrEmpty
    }
}
