#requires -Version 5.1
#requires -Modules Pester

BeforeAll {
    $script:ScriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..\src\bustermyconnection\Buster-MyConnection.ps1')).Path
    . $script:ScriptPath -DotSourceOnly
}

Describe 'Proxy credential cache' {

    BeforeEach {
        Set-Variable -Name CredentialCachePath -Scope Script `
            -Value (Join-Path $TestDrive 'credentials.xml')
    }

    It 'stores and retrieves a credential for a matching domain/user' {
        $sec  = ConvertTo-SecureString 'pw' -AsPlainText -Force
        $cred = New-Object System.Management.Automation.PSCredential('DOMINIO\userid', $sec)

        Set-StoredProxyCredential -Domain 'DOMINIO' -Username 'userid' -Credential $cred

        $got = Get-StoredProxyCredential -Domain 'DOMINIO' -Username 'userid'
        $got | Should -Not -BeNullOrEmpty
        $got.UserName | Should -Be 'DOMINIO\userid'
    }

    It 'returns null when domain/user do not match the cached entry' {
        $sec  = ConvertTo-SecureString 'pw' -AsPlainText -Force
        $cred = New-Object System.Management.Automation.PSCredential('DOMINIO\userid', $sec)
        Set-StoredProxyCredential -Domain 'DOMINIO' -Username 'userid' -Credential $cred

        Get-StoredProxyCredential -Domain 'OTHER' -Username 'someone' | Should -BeNullOrEmpty
    }

    It 'returns null when no cache file exists' {
        Remove-Item $CredentialCachePath -ErrorAction SilentlyContinue
        Get-StoredProxyCredential -Domain 'DOMINIO' -Username 'userid' | Should -BeNullOrEmpty
    }
}

Describe 'Get-ProxyCredential (cache hit path, no prompt)' {

    BeforeEach {
        Set-Variable -Name CredentialCachePath -Scope Script `
            -Value (Join-Path $TestDrive 'credentials.xml')
        $sec  = ConvertTo-SecureString 'pw' -AsPlainText -Force
        $cred = New-Object System.Management.Automation.PSCredential('DOMINIO\userid', $sec)
        Set-StoredProxyCredential -Domain 'DOMINIO' -Username 'userid' -Credential $cred
    }

    It 'returns the cached credential without prompting when -UseCache hits' {
        Mock Read-Host { throw 'Read-Host must not be called on a cache hit' }

        $got = Get-ProxyCredential -Domain 'DOMINIO' -Username 'userid' -UseCache
        $got.UserName | Should -Be 'DOMINIO\userid'
        Should -Invoke Read-Host -Times 0
    }
}
