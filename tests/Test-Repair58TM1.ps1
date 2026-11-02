#requires -Version 5.1
[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:Source = Join-Path (Split-Path -Parent $PSScriptRoot) 'Repair-58TM1.ps1'
$script:Passed = 0
$script:Failed = 0
$script:Fixture = Join-Path ([IO.Path]::GetTempPath()) ('58tm1-tests-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $script:Fixture | Out-Null
function Assert-True($Value, [string]$Message = 'Assertion fausse') { if (-not $Value) { throw $Message } }
function Assert-Equal($Actual, $Expected) {
    if (($Actual | ConvertTo-Json -Compress -Depth 10) -ne ($Expected | ConvertTo-Json -Compress -Depth 10)) {
        throw "Attendu : $Expected ; obtenu : $Actual"
    }
}
function Assert-Throws([scriptblock]$Body, [string]$Pattern) {
    try { & $Body } catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw "Erreur inattendue : $($_.Exception.Message)" }
        return
    }
    throw 'Une erreur etait attendue.'
}
function Test-Case([string]$Name, [scriptblock]$Body) {
    try {
        . $script:Source
        & $Body
        $script:Passed++
        Write-Host "PASS $Name"
    } catch {
        $script:Failed++
        Write-Host "FAIL $Name : $($_.Exception.Message)" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace
    }
}
$savedEnvironment = @{}
foreach ($name in @('LOCALAPPDATA','windir','COMPUTERNAME','ProgramFiles')) { $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
try {
    # Only fixture paths; Windows commands are replaced in tests that need them.
    $env:LOCALAPPDATA = $script:Fixture
    $env:windir = $script:Fixture
    $env:COMPUTERNAME = 'RDS-TEST'
    $env:ProgramFiles = $script:Fixture

    Test-Case 'Tous les scripts ont une syntaxe PowerShell valide' {
        foreach ($file in Get-ChildItem (Split-Path -Parent $PSScriptRoot) -Filter '*.ps1' -Recurse) {
            $tokens = $null; $errors = $null
            $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
            Assert-Equal @($errors).Count 0
        }
    }
    Test-Case 'Dot sourcing sans effet disque et sans journal' {
        Assert-True ($null -eq $script:RunDirectory)
        Assert-True ($null -eq $script:Journal)
        Assert-Equal @(Get-ChildItem $script:Fixture -Force).Count 0
    }
    Test-Case 'Le plan par defaut ne purge aucun cache' {
        Assert-Equal @(Get-RepairPlan) @('ModernAuth','Broker')
    }
    Test-Case 'Les reinitialisations sont independantes' {
        Assert-Equal @(Get-RepairPlan -TokenBroker) @('ModernAuth','Broker','TokenBrokerAccounts')
        Assert-Equal @(Get-RepairPlan -Identity -Licensing) @('ModernAuth','Broker','OfficeIdentity','OfficeLicensing')
    }
    Test-Case 'Isolation des processus par session' {
        $processes = @(
            [pscustomobject]@{ ProcessName = 'OUTLOOK'; SessionId = 2 },
            [pscustomobject]@{ ProcessName = 'WINWORD'; SessionId = 7 },
            [pscustomobject]@{ ProcessName = 'OneDrive'; SessionId = 2 },
            [pscustomobject]@{ ProcessName = 'svchost'; SessionId = 2 }
        )
        Assert-Equal @((Get-SessionProcesses $processes 2).ProcessName) @('OUTLOOK')
        Assert-Equal @((Get-SessionProcesses $processes 2 -IncludeOtherMicrosoftApps).ProcessName) @('OUTLOOK','OneDrive')
        Assert-Equal @(Get-SessionProcesses $processes 1).Count 0
    }
    Test-Case 'Garde-fou plateforme non Windows' {
        if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { Assert-Throws { Assert-Windows } 'sous Windows' }
        else { Assert-Windows }
    }
    Test-Case 'Ne retire que les valeurs locales bloquantes' {
        $script:Mutations = @()
        function Get-ValueState {
            param($Path,$Name)
            $value = @{ DisableAADWAM = 1; DisableADALatopWAMOverride = 0; EnableADAL = 0 }[$Name]
            [pscustomobject]@{ Exists = $true; Value = $value; Kind = 'DWord' }
        }
        function Set-BackedUpValue { param($Path,$Name,[switch]$Remove); $script:Mutations += "$Path|$Name|$Remove" }
        Invoke-ModernAuthRepair
        Assert-Equal $script:Mutations.Count 2
        Assert-True ($script:Mutations[0] -like '*|DisableAADWAM|True')
        Assert-True ($script:Mutations[1] -like '*|EnableADAL|True')
        Assert-True (-not @($script:Mutations | Where-Object { $_ -like '*Policies*' }).Count)
    }
    Test-Case 'Valeurs modernes saines conservees' {
        function Get-ValueState { param($Path,$Name); [pscustomobject]@{ Exists=$true; Value=(@{EnableADAL=1;DisableAADWAM=0;DisableADALatopWAMOverride=0}[$Name]);Kind='DWord' } }
        function Set-BackedUpValue { throw 'Aucune modification attendue' }
        Invoke-ModernAuthRepair
    }
    Test-Case 'Audit assemble les resultats meme sans Office ni FSLogix' {
        function Get-CimInstance { [pscustomobject]@{ Caption='Windows Test';Version='10.0';BuildNumber='TEST';OSArchitecture='64-bit' } }
        function Get-ValueState { param($Path,$Name); [pscustomobject]@{Exists=$false;Value=$null;Kind=$null} }
        function Get-Service { param($Name); return @() }
        function Get-CurrentSid { 'S-1-5-21-TEST' }
        function Get-AppxPackage { [pscustomobject]@{Name='Microsoft.AAD.BrokerPlugin';Version='Test';Status='Ok'} }
        function Get-WinEvent { throw 'Journal indisponible (simule)' }
        $audit = Get-Audit
        Assert-Equal $audit.OS.Caption 'Windows Test'
        Assert-True ($null -eq $audit.FSLogix.Version)
        Assert-Equal $audit.Network.Tested $false
        Assert-True ($audit.Warnings.Count -ge 2)
    }
    Test-Case 'Une strategie WAM bloquante empeche toute reparation' {
        function Assert-InteractiveUser {}
        function Assert-SelectedEnvironment {}
        function Assert-AppsClosed {}
        function Get-AuthPolicyBlockers { 'HKCU:\Software\Policies\Microsoft\Office\16.0\Common\Identity\DisableAADWAM' }
        function Invoke-ModernAuthRepair { throw 'MUTATION INTERDITE' }
        Assert-Throws { Invoke-UserRepair } 'corriger la GPO'
        Assert-True ($null -eq $script:RunDirectory)
    }
    Test-Case 'Un manifeste Broker absent empeche toute purge' {
        function Assert-InteractiveUser {}
        function Assert-SelectedEnvironment {}
        function Assert-AppsClosed {}
        function Get-AuthPolicyBlockers {}
        function Get-AppxPackage {}
        function Add-AppxPackage {}
        function Invoke-ModernAuthRepair { throw 'MUTATION INTERDITE' }
        Assert-Throws { Invoke-UserRepair } 'Manifeste du Broker absent'
    }
    Test-Case 'Broker sain : pas de reenregistrement inutile' {
        function Get-AppxPackage { [pscustomobject]@{ Name='Microsoft.AAD.BrokerPlugin';Status='Ok' } }
        function Add-AppxPackage { throw 'MUTATION INTERDITE' }
        Invoke-BrokerRepair
        Assert-True ($null -eq $script:RunDirectory)
    }
    Test-Case 'Refus ShouldProcess : aucun renommage ni journal' {
        $cache = Join-Path $script:Fixture 'cache'
        New-Item -ItemType Directory -Path $cache | Out-Null
        $script:Caller = New-Object PSObject
        $script:Caller | Add-Member ScriptMethod ShouldProcess { param($Target,$Action); return $false }
        Move-BackedUpCache $cache
        Assert-True (Test-Path -LiteralPath $cache)
        Assert-True ($null -eq $script:RunDirectory)
        Assert-True $script:AnySkipped
        Remove-Item -LiteralPath $cache
    }
    Test-Case 'Vrai WhatIf PowerShell : aucun renommage ni sauvegarde' {
        $cache = Join-Path $script:Fixture 'whatif-cache'
        New-Item -ItemType Directory -Path $cache | Out-Null
        function Invoke-WhatIfProbe {
            [CmdletBinding(SupportsShouldProcess=$true)]
            param($Path)
            $script:Caller = $PSCmdlet
            Move-BackedUpCache $Path
        }
        Invoke-WhatIfProbe -Path $cache -WhatIf
        Assert-True (Test-Path -LiteralPath $cache)
        Assert-True ($null -eq $script:RunDirectory)
        Remove-Item -LiteralPath $cache
    }
    Test-Case 'Sauvegarde de cache preparee avant renommage' {
        $cache = Join-Path $script:Fixture 'cache-order'
        New-Item -ItemType Directory -Path $cache | Out-Null
        Set-Content -LiteralPath (Join-Path $cache 'token-test') -Value 'test fixture, not a token'
        $script:Caller = New-Object PSObject
        $script:Caller | Add-Member ScriptMethod ShouldProcess { param($Target,$Action); return $true }
        function Initialize-Run { param($Scope); $script:Journal = @{ RunId='20261102T120000Z-0123456789abcdef0123456789abcdef'; Actions=@() } }
        function Add-JournalAction {
            param($Action)
            Assert-True (Test-Path -LiteralPath $Action.Path) 'Cache deja renomme avant journal'
            $script:Journal.Actions += $Action
        }
        function Complete-JournalAction {
            Assert-True (-not (Test-Path -LiteralPath $script:Journal.Actions[-1].Path))
            Assert-True (Test-Path -LiteralPath $script:Journal.Actions[-1].Backup)
        }
        Move-BackedUpCache $cache
        Assert-Equal (Get-Content -LiteralPath (Join-Path $script:Journal.Actions[0].Backup 'token-test')) 'test fixture, not a token'
        Remove-Item -LiteralPath $script:Journal.Actions[0].Backup -Recurse
    }
    Test-Case 'Manifeste : rejette un cache hors liste' {
        function Get-CurrentSid { 'S-1-5-21-TEST' }
        $data = [pscustomobject]@{ Schema=1;RunId='20261102T120000Z-0123456789abcdef0123456789abcdef';Scope='User';Sid='S-1-5-21-TEST';Computer='RDS-TEST';Actions=@(
            [pscustomobject]@{State='Applied';Type='Cache';Path='C:\Windows';Backup='C:\Windows.backup'}
        ) }
        Assert-Throws { Assert-Manifest $data } 'Chemin de cache non autorise'
    }
    Test-Case 'Une sauvegarde reg ne peut pas importer une cle hors perimetre' {
        $file = Join-Path $script:Fixture 'backup.reg'
        @('Windows Registry Editor Version 5.00','','[HKEY_CURRENT_USER\Software\Microsoft\Office\16.0\Common\Identity]','"EnableADAL"=dword:00000001') | Set-Content -LiteralPath $file
        Assert-RegistryBackupContent $file $script:IdentityKey
        Add-Content -LiteralPath $file -Value '[HKEY_LOCAL_MACHINE\SOFTWARE\Unsafe]'
        Assert-Throws { Assert-RegistryBackupContent $file $script:IdentityKey } 'hors du perimetre'
        Remove-Item -LiteralPath $file
    }
    Test-Case 'Manifeste : rejette un autre hote ou utilisateur' {
        function Get-CurrentSid { 'S-1-5-21-TEST' }
        $data = [pscustomobject]@{ Schema=1;RunId='20261102T120000Z-0123456789abcdef0123456789abcdef';Scope='User';Sid='AUTRE';Computer='RDS-TEST';Actions=@() }
        Assert-Throws { Assert-Manifest $data } 'autre utilisateur'
        $data.Sid='S-1-5-21-TEST';$data.Computer='AUTRE-HOTE'
        Assert-Throws { Assert-Manifest $data } 'autre hote'
    }
    Test-Case 'Manifeste : refuse une valeur HKLM arbitraire' {
        function Get-CurrentSid { 'S-1-5-21-TEST' }
        $data = [pscustomobject]@{ Schema=1;RunId='20261102T120000Z-0123456789abcdef0123456789abcdef';Scope='Host';Sid='S-1-5-21-TEST';Computer='RDS-TEST';Actions=@(
            [pscustomobject]@{State='Applied';Type='RegistryValue';Path='HKLM:\SOFTWARE\Other';Name='Unsafe';Existed=$false}
        ) }
        Assert-Throws { Assert-Manifest $data } 'Valeur de restauration non autorisee'
    }
    Test-Case 'Manifeste : accepte uniquement une cible de cache connue et son suffixe exact' {
        function Get-CurrentSid { 'S-1-5-21-TEST' }
        $runId='20261102T120000Z-0123456789abcdef0123456789abcdef'
        $path=@(Get-CacheTargets)[0]
        $data = [pscustomobject]@{Schema=1;RunId=$runId;Scope='User';Sid='S-1-5-21-TEST';Computer='RDS-TEST';Actions=@(
            [pscustomobject]@{State='Applied';Type='Cache';Path=$path;Backup=($path+'.58tm1-backup-'+$runId)}
        )}
        Assert-Manifest $data
        $data.Actions[0].Backup += '-altered'
        Assert-Throws { Assert-Manifest $data } 'Chemin de cache non autorise'
    }
    Test-Case 'Les marqueurs itinerants sont propres a chaque hote' {
        $a = Get-DeploymentMarker 'Pilot-01'
        $env:COMPUTERNAME = 'RDS-SECOND'
        $b = Get-DeploymentMarker 'Pilot-01'
        $env:COMPUTERNAME = 'RDS-TEST'
        Assert-True ($a -ne $b)
        Assert-True ($a -like '*RDS-TEST-Pilot-01.json')
    }
    Test-Case 'Controle des parametres de campagne contre injection' {
        Assert-Throws { & $script:Source -DeploymentId 'test;whoami' } 'DeploymentId|pattern|modele|ValidatePattern'
    }
    Test-Case 'SCA : refuse un produit perpetuel avant modification' {
        function Assert-Administrator {}
        $EnableSharedComputerActivation = $true
        function Get-ValueState { param($Path,$Name); [pscustomobject]@{ Exists=$true;Value='ProPlus2021Volume';Kind='String' } }
        function Set-BackedUpValue { throw 'MUTATION INTERDITE' }
        Assert-Throws { Invoke-HostConfiguration } 'compatible non identifiee'
    }
    Test-Case 'SCA : refuse une strategie contradictoire' {
        function Assert-Administrator {}
        $EnableSharedComputerActivation = $true
        function Get-ValueState {
            param($Path,$Name)
            $value = if ($Name -eq 'ProductReleaseIds') { 'O365ProPlusRetail' } else { 0 }
            [pscustomobject]@{ Exists=$true;Value=$value;Kind='String' }
        }
        function Set-BackedUpValue { throw 'MUTATION INTERDITE' }
        Assert-Throws { Invoke-HostConfiguration } 'Strategie.*contradictoire'
    }
    Test-Case 'SCA : necrit que la valeur autorisee sur une edition M365' {
        function Assert-Administrator {}
        function Assert-SelectedEnvironment {}
        $EnableSharedComputerActivation = $true
        function Get-ValueState {
            param($Path,$Name)
            if ($Name -eq 'ProductReleaseIds') { return [pscustomobject]@{Exists=$true;Value='O365ProPlusRetail';Kind='String'} }
            [pscustomobject]@{Exists=$false;Value=$null;Kind=$null}
        }
        $script:Captured = @()
        function Set-BackedUpValue { param($Path,$Name,$Value,$Kind,$Scope); $script:Captured=@($Path,$Name,$Value,$Kind,$Scope) }
        Invoke-HostConfiguration
        Assert-Equal $script:Captured @($script:OfficeConfig,'SharedComputerLicensing','1','String','Host')
    }
    Test-Case 'Modifier une valeur ne recree pas une cle existante' {
        $script:Caller = New-Object PSObject
        $script:Caller | Add-Member ScriptMethod ShouldProcess { param($Target,$Action); return $true }
        function Get-ValueState { [pscustomobject]@{Exists=$true;Value='0';Kind='String'} }
        function Initialize-Run {}
        function Add-JournalAction { param($Action); Assert-Equal $Action.Value '0' }
        function Complete-JournalAction {}
        function Test-Path { return $true }
        function New-Item { throw 'Ne pas recreer une cle existante' }
        $script:Captured = @()
        function New-ItemProperty { param($LiteralPath,$Name,$Value,$PropertyType,[switch]$Force); $script:Captured=@($LiteralPath,$Name,$Value,$PropertyType) }
        Set-BackedUpValue $script:OfficeConfig 'SharedComputerLicensing' '1' 'String' -Scope Host
        Assert-Equal $script:Captured @($script:OfficeConfig,'SharedComputerLicensing','1','String')
    }
    Test-Case 'Restauration de cache preserve aussi le cache regenere' {
        function Get-CurrentSid { 'S-1-5-21-TEST' }
        function Assert-InteractiveUser {}
        function Assert-AppsClosed { param([switch]$IncludeOtherMicrosoftApps) }
        $runId = '20261102T120000Z-0123456789abcdef0123456789abcdef'
        $path = @(Get-CacheTargets)[1]
        $backup = $path + '.58tm1-backup-' + $runId
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        New-Item -ItemType Directory -Path $backup -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $path 'content') -Value 'nouveau'
        Set-Content -LiteralPath (Join-Path $backup 'content') -Value 'ancien'
        $run = Join-Path $script:Fixture 'restore-run'
        New-Item -ItemType Directory -Path $run | Out-Null
        $ManifestPath = Join-Path $run 'manifest.json'
        @{Schema=1;RunId=$runId;Scope='User';Sid='S-1-5-21-TEST';Computer='RDS-TEST';Actions=@(
            @{State='Applied';Type='Cache';Path=$path;Backup=$backup}
        )} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ManifestPath
        $script:Caller = New-Object PSObject
        $script:Caller | Add-Member ScriptMethod ShouldProcess { param($Target,$Action); return $true }
        Restore-Repair
        Assert-Equal (Get-Content -LiteralPath (Join-Path $path 'content')) 'ancien'
        $displaced = @(Get-ChildItem (Split-Path -Parent $path) -Directory | Where-Object Name -Like 'Licenses.58tm1-before-restore-*')
        Assert-Equal $displaced.Count 1
        Assert-Equal (Get-Content -LiteralPath (Join-Path $displaced[0].FullName 'content')) 'nouveau'
        Assert-True (Test-Path -LiteralPath (Join-Path $run 'restore-completed.json'))
        Assert-Throws { Restore-Repair } 'deja termine'
    }
    Test-Case 'Un lien symbolique est refuse avant toute modification' {
        if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
            $target = Join-Path $script:Fixture 'real'
            $link = Join-Path $script:Fixture 'link'
            New-Item -ItemType Directory -Path $target | Out-Null
            New-Item -ItemType SymbolicLink -Path $link -Target $target | Out-Null
            Assert-Throws { Assert-NoReparsePath (Join-Path $link 'child') } 'Lien/jonction'
            Remove-Item -LiteralPath $link
            Remove-Item -LiteralPath $target
        } else {
            # Does not require symlink privilege on Windows.
            Assert-NoReparsePath $script:Fixture
        }
    }
} finally {
    foreach ($name in $savedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process') }
    Remove-Item -LiteralPath $script:Fixture -Recurse -Force
}
Write-Host ("Resultat : {0} reussis, {1} echecs." -f $script:Passed,$script:Failed)
if ($script:Failed) { exit 1 }
