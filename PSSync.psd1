@{

    RootModule = 'PSSync.psm1'

    ModuleVersion = '1.0.0'

    GUID = '81a34f5d-c22c-471b-8ece-326fd74302dd'

    Author = 'ShosMeister'

    Copyright = '(c) 2026 ShosMeister. All rights reserved.'

    Description = 'A simple PowerShell directory synchronization utility inspired by rsync.'

    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'PSSync'
    )

    CmdletsToExport = @()

    VariablesToExport = @()

    AliasesToExport = @()

    PrivateData = @{

        PSData = @{

            Tags = @(
                'PowerShell'
                'FileSynchronization'
                'DirectorySynchronization'
                'Rsync'
                'Windows'
            )

            LicenseUri = 'https://github.com/ShosMeister/PSSync/blob/master/LICENSE'

            ProjectUri = 'https://github.com/ShosMeister/PSSync'

        }

    }

}
