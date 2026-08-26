#requires -Version 5.1
#requires -Modules Pester

BeforeAll {
    $script:ScriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..\src\bustermyconnection\Buster-MyConnection.ps1')).Path
    . $script:ScriptPath -DotSourceOnly
}

Describe 'Install-CntlmPortable' {

    BeforeEach {
        Mock Invoke-WebRequest {}
        Mock Expand-Archive {}
        Mock Copy-Item {}
        Mock New-Item {}
        Mock Remove-Item {}
    }

    It 'copies the discovered cntlm.exe and returns its destination path' {
        Mock Test-Path { $false }
        Mock Get-ChildItem {
            [pscustomobject]@{ FullName = 'C:\extract\cntlm.exe' }
        } -ParameterFilter { $Filter -eq 'cntlm.exe' }

        $target = Join-Path $TestDrive 'CNTLM'
        $result = Install-CntlmPortable -TargetPath $target

        $result | Should -Be (Join-Path $target 'cntlm.exe')
        Should -Invoke Invoke-WebRequest -Times 1
        Should -Invoke Expand-Archive -Times 1
        Should -Invoke Copy-Item -Times 1
    }

    It 'throws when the archive contains no cntlm.exe' {
        Mock Test-Path { $true }
        Mock Get-ChildItem { $null } -ParameterFilter { $Filter -eq 'cntlm.exe' }

        { Install-CntlmPortable -TargetPath (Join-Path $TestDrive 'CNTLM') } | Should -Throw
    }
}

Describe 'Resolve-CntlmExecutable' {

    It 'returns the path unchanged when the executable already exists' {
        Mock Test-Path { $true }
        Mock Install-CntlmPortable { 'C:\should\not\be\called.exe' }

        $p = 'C:\tools\cntlm\cntlm.exe'
        Resolve-CntlmExecutable -Path $p | Should -Be $p
        Should -Invoke Install-CntlmPortable -Times 0
    }

    It 'delegates to Install-CntlmPortable when the executable is missing' {
        Mock Test-Path { $false }
        Mock Install-CntlmPortable { 'C:\installed\cntlm.exe' }

        Resolve-CntlmExecutable -Path 'C:\tools\cntlm\cntlm.exe' | Should -Be 'C:\installed\cntlm.exe'
        Should -Invoke Install-CntlmPortable -Times 1
    }
}
