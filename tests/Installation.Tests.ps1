#requires -Version 5.1
#requires -Modules Pester

BeforeAll {
    $script:ScriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..\src\bustermyconnection\Buster-MyConnection.ps1')).Path
    . $script:ScriptPath -DotSourceOnly
}

Describe 'Install-CntlmViaScoop' {

    It 'throws with an actionable message when scoop is not on PATH' {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'scoop' }

        { Install-CntlmViaScoop } | Should -Throw '*Scoop is not installed*'
    }

    It 'installs via scoop and returns the resolved cntlm.exe path' {
        Mock Get-Command { [pscustomobject]@{ Name = 'scoop' } } -ParameterFilter { $Name -eq 'scoop' }
        Mock Test-Path { $true }

        function scoop { }
        Mock scoop { 'C:\Users\me\scoop\shims\cntlm.exe' } -ParameterFilter { $args -contains 'which' }
        Mock scoop { } -ParameterFilter { $args -contains 'install' }

        $result = Install-CntlmViaScoop

        $result | Should -Be 'C:\Users\me\scoop\shims\cntlm.exe'
    }

    It 'throws when scoop install succeeds but cntlm.exe cannot be located' {
        Mock Get-Command { [pscustomobject]@{ Name = 'scoop' } } -ParameterFilter { $Name -eq 'scoop' }
        Mock Test-Path { $false }

        function scoop { }
        Mock scoop { $null } -ParameterFilter { $args -contains 'which' }
        Mock scoop { } -ParameterFilter { $args -contains 'install' }
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'cntlm.exe' }

        { Install-CntlmViaScoop } | Should -Throw '*could not be located*'
    }
}

Describe 'Resolve-CntlmExecutable' {

    It 'returns the path unchanged when the executable already exists' {
        Mock Test-Path { $true }
        Mock Install-CntlmViaScoop { 'C:\should\not\be\called.exe' }

        $p = 'C:\tools\cntlm\cntlm.exe'
        Resolve-CntlmExecutable -Path $p | Should -Be $p
        Should -Invoke Install-CntlmViaScoop -Times 0
    }

    It 'delegates to Install-CntlmViaScoop when the executable is missing' {
        Mock Test-Path { $false }
        Mock Install-CntlmViaScoop { 'C:\scoop\shims\cntlm.exe' }

        Resolve-CntlmExecutable -Path 'C:\tools\cntlm\cntlm.exe' | Should -Be 'C:\scoop\shims\cntlm.exe'
        Should -Invoke Install-CntlmViaScoop -Times 1
    }
}