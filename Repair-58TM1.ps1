#requires -Version 5.1
<#
.SYNOPSIS
Diagnostic et reparations ciblees de la connexion Office sur RDS / FSLogix.
.DESCRIPTION
Audit par defaut. Aucun correctif n'est deduit du seul tag 58TM1.
Reparations utilisateur dans le contexte de la session interactive uniquement.
Les changements supportent -WhatIf, sont journalises et sauvegardes.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [ValidateSet('Audit','RepairUser','ConfigureHost','InstallLogonTask','RemoveLogonTask','Restore')]
    [string]$Mode = 'Audit',
    [ValidateSet('Auto','RDS','RDSFSLogix')]
    [string]$Environment = 'Auto',
    [switch]$ReregisterBroker,
    [switch]$ResetOfficeIdentity,
    [switch]$ResetTokenBrokerAccounts,
    [switch]$ResetOfficeLicensing,
    [switch]$EnableSharedComputerActivation,
    [switch]$TestNetwork,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$')]
    [string]$DeploymentId = 'Baseline-01',
    [string]$ManifestPath,
    [switch]$Once
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:Caller = $null
$script:RunDirectory = $null
$script:Journal = $null
$script:AnySkipped = $false
$script:TaskName = '58TM1-Office-UserRepair'
$script:SourcePath = $PSCommandPath
$script:IdentityKey = 'HKCU:\Software\Microsoft\Office\16.0\Common\Identity'
$script:LicensingKey = 'HKCU:\Software\Microsoft\Office\16.0\Common\Licensing'
$script:OfficeConfig = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'

function Get-RepairPlan {
    param([switch]$Identity, [switch]$TokenBroker, [switch]$Licensing)
    $plan = @('ModernAuth','Broker')
    if ($Identity) { $plan += 'OfficeIdentity' }
    if ($TokenBroker) { $plan += 'TokenBrokerAccounts' }
    if ($Licensing) { $plan += 'OfficeLicensing' }
    return $plan
}

function Get-SessionProcesses {
    param([object[]]$Processes, [int]$SessionId, [switch]$IncludeOtherMicrosoftApps)
    $names = @('OUTLOOK','WINWORD','EXCEL','POWERPNT','ONENOTE','MSACCESS','MSPUB','VISIO','WINPROJ')
    if ($IncludeOtherMicrosoftApps) { $names += @('Teams','ms-teams','OneDrive') }
    return @($Processes | Where-Object { $_.SessionId -eq $SessionId -and $_.ProcessName -in $names })
}

function Assert-Windows {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'Cet outil doit etre execute sous Windows. Aucune modification effectuee.'
    }
    if (-not [Environment]::Is64BitProcess) { throw 'Utiliser Windows PowerShell 64 bits.' }
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Administrator {
    if (-not (Test-Administrator)) { throw 'Cette operation sur l''hote exige PowerShell administrateur.' }
}

function Get-CurrentSid {
    return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}

function Assert-InteractiveUser {
    # WTS works for full desktop and RemoteApp, without depending on explorer.exe.
    $sessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
    if ($sessionId -eq 0 -or (Get-CurrentSid) -in @('S-1-5-18','S-1-5-19','S-1-5-20')) {
        throw 'Reparation refusee hors session utilisateur interactive (SYSTEM, service, WinRM).'
    }
    if (-not ('Repair58TM1.Wts' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace Repair58TM1 {
  public static class Wts {
    [DllImport("wtsapi32.dll", CharSet=CharSet.Unicode, ExactSpelling=true, SetLastError=true)]
    static extern bool WTSQuerySessionInformationW(IntPtr server, int session, int info, out IntPtr buffer, out int bytes);
    [DllImport("wtsapi32.dll")] static extern void WTSFreeMemory(IntPtr buffer);
    public static string Query(int session, int info) {
      IntPtr p; int n;
      if (!WTSQuerySessionInformationW(IntPtr.Zero, session, info, out p, out n))
        throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
      try { return Marshal.PtrToStringUni(p) ?? ""; } finally { WTSFreeMemory(p); }
    }
  }
}
'@
    }
    $user = [Repair58TM1.Wts]::Query($sessionId, 5)
    $domain = [Repair58TM1.Wts]::Query($sessionId, 7)
    if ([string]::IsNullOrWhiteSpace($user)) { throw 'Impossible d''identifier l''utilisateur de la session.' }
    $account = if ($domain) { "$domain\$user" } else { $user }
    $sid = (New-Object Security.Principal.NTAccount($account)).Translate([Security.Principal.SecurityIdentifier]).Value
    if ($sid -ne (Get-CurrentSid)) {
        throw 'Compte different de celui de la session. Ouvrir PowerShell avec l''utilisateur affecte, sans RunAs.'
    }
}

function Assert-AppsClosed {
    param([switch]$IncludeOtherMicrosoftApps)
    $processes = @(Get-Process -ErrorAction Stop)
    $blocking = @(Get-SessionProcesses -Processes $processes -SessionId ([Diagnostics.Process]::GetCurrentProcess().SessionId) -IncludeOtherMicrosoftApps:($ResetTokenBrokerAccounts -or $IncludeOtherMicrosoftApps))
    if ($blocking.Count) {
        throw ('Fermer les applications de cette session avant de continuer : ' + (($blocking.ProcessName | Sort-Object -Unique) -join ', ') + '. Aucun processus n''a ete arrete.')
    }
}

function Assert-SelectedEnvironment {
    if ($Environment -eq 'Auto') { return }
    $os = Get-CimInstance Win32_OperatingSystem
    if ($os.ProductType -eq 1) { throw 'Un environnement RDS a ete choisi sur un OS client. Choisir Auto ou le bon serveur.' }
    if (-not (Get-Service -Name TermService -ErrorAction SilentlyContinue)) { throw 'Service RDS absent.' }
    if ($Environment -eq 'RDSFSLogix') {
        $profiles = (Get-ValueState 'HKLM:\SOFTWARE\FSLogix\Profiles' 'Enabled').Value
        $odfc = (Get-ValueState 'HKLM:\SOFTWARE\Policies\FSLogix\ODFC' 'Enabled').Value
        $service = Get-Service -Name frxsvc -ErrorAction SilentlyContinue
        if (($profiles -ne 1 -and $odfc -ne 1) -or -not $service -or $service.Status -ne 'Running') {
            throw 'RDSFSLogix choisi mais conteneurs non actives ou service FSLogix non demarre. Examiner l''audit avant de modifier le profil.'
        }
    }
}

function Get-ValueState {
    param([string]$Path, [string]$Name)
    if (Test-Path -LiteralPath $Path) {
        $key = Get-Item -LiteralPath $Path
        if ($key.GetValueNames() -contains $Name) {
            return [pscustomobject]@{
                Exists = $true
                Value = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                Kind = $key.GetValueKind($Name).ToString()
            }
        }
    }
    return [pscustomobject]@{ Exists = $false; Value = $null; Kind = $null }
}

function Get-SelectedValues {
    param([string]$Path, [string[]]$Names)
    $values = [ordered]@{}
    foreach ($name in $Names) { $values[$name] = (Get-ValueState $Path $name).Value }
    return $values
}

function Get-AuthPolicyBlockers {
    $paths = @(
        'HKCU:\Software\Policies\Microsoft\Office\16.0\Common\Identity',
        'HKLM:\Software\Policies\Microsoft\Office\16.0\Common\Identity'
    )
    foreach ($path in $paths) {
        foreach ($name in @('DisableAADWAM','DisableADALatopWAMOverride','EnableADAL')) {
            $state = Get-ValueState $path $name
            if ($state.Exists -and (($name -eq 'EnableADAL' -and "$($state.Value)" -eq '0') -or
                ($name -ne 'EnableADAL' -and "$($state.Value)" -eq '1'))) {
                "$path\$name"
            }
        }
    }
}

function Get-CacheTargets {
    return @(
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.AAD.BrokerPlugin_cw5n1h2txyewy\AC\TokenBroker\Accounts'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Office\Licenses'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Office\16.0\Licensing')
    )
}

function Get-BrokerManifest {
    return Join-Path $env:windir 'SystemApps\Microsoft.AAD.BrokerPlugin_cw5n1h2txyewy\AppxManifest.xml'
}

function Write-Notice {
    param([string]$Message)
    Write-Host $Message
    if ($script:RunDirectory) {
        Add-Content -LiteralPath (Join-Path $script:RunDirectory 'operations.log') -Value ("{0:o} {1}" -f [DateTime]::UtcNow, $Message) -Encoding UTF8
    }
}

function Confirm-Change {
    param([string]$Target, [string]$Operation)
    $approved = $script:Caller.ShouldProcess($Target, $Operation)
    if (-not $approved) { $script:AnySkipped = $true }
    return $approved
}

function Initialize-Run {
    param([ValidateSet('User','Host')][string]$Scope)
    if ($script:RunDirectory) { return }
    $root = if ($Scope -eq 'Host') { Join-Path $env:ProgramData '58tm1\Runs' } else { Join-Path $env:LOCALAPPDATA '58tm1\Runs' }
    if ($Scope -eq 'Host') {
        Initialize-ProtectedDirectory (Join-Path $env:ProgramData '58tm1') -AllowUsersRead
        Initialize-ProtectedDirectory $root
    }
    Assert-NoReparsePath $root
    $id = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [Guid]::NewGuid().ToString('N')
    $script:RunDirectory = Join-Path $root $id
    New-Item -ItemType Directory -Path $script:RunDirectory -Force | Out-Null
    $script:Journal = [ordered]@{
        Schema = 1; RunId = $id; Scope = $Scope; Sid = Get-CurrentSid
        Computer = $env:COMPUTERNAME; CreatedUtc = [DateTime]::UtcNow.ToString('o')
        Status = 'InProgress'; Actions = @()
    }
    Save-Journal
    Write-Notice ("Sauvegarde et journal : " + $script:RunDirectory)
}

function Save-Journal {
    $file = Join-Path $script:RunDirectory 'manifest.json'
    $tmp = Join-Path $script:RunDirectory 'manifest.tmp'
    $script:Journal | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $file -Force
}

function Add-JournalAction {
    param([System.Collections.IDictionary]$Action)
    $Action['State'] = 'Prepared'
    $script:Journal.Actions += $Action
    Save-Journal
}

function Complete-JournalAction {
    $script:Journal.Actions[-1].State = 'Applied'
    Save-Journal
}

function Invoke-RegExport {
    param([string]$Path, [string]$File)
    $native = $Path.Replace('HKCU:\','HKEY_CURRENT_USER\').Replace('HKLM:\','HKEY_LOCAL_MACHINE\')
    $output = & "$env:windir\System32\reg.exe" export $native $File /y 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Sauvegarde registre impossible : $Path ($output)" }
}

function Assert-RegistryBackupContent {
    param([string]$File, [string]$Path)
    $content = Get-Content -LiteralPath $File -Raw
    if ($content -notmatch '^Windows Registry Editor Version 5\.00') { throw 'Entete de sauvegarde registre invalide.' }
    $root = $Path.Replace('HKCU:\','HKEY_CURRENT_USER\').Replace('HKLM:\','HKEY_LOCAL_MACHINE\')
    $sections = [regex]::Matches($content, '(?m)^\[([^\r\n]+)\]\r?$')
    if (-not $sections.Count) { throw 'Sauvegarde registre sans section.' }
    foreach ($section in $sections) {
        $key = $section.Groups[1].Value
        if ($key -ne $root -and -not $key.StartsWith(($root + '\'), [StringComparison]::OrdinalIgnoreCase)) {
            throw 'La sauvegarde registre contient une cle hors du perimetre autorise.'
        }
    }
}

function Backup-RegistryKey {
    param([string]$Path)
    $exists = Test-Path -LiteralPath $Path
    $file = $null; $hash = $null
    if ($exists) {
        $file = [Guid]::NewGuid().ToString('N') + '.reg'
        $full = Join-Path $script:RunDirectory $file
        Invoke-RegExport $Path $full
        $hash = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash
    }
    return @{ Type = 'RegistryKey'; Path = $Path; Existed = $exists; Backup = $file; Hash = $hash }
}

function Remove-BackedUpKey {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { Write-Notice "Absent, aucune action : $Path"; return }
    if (Confirm-Change $Path 'Sauvegarder puis reinitialiser cette cle utilisateur') {
        Initialize-Run User
        $action = Backup-RegistryKey $Path
        Add-JournalAction $action
        Remove-Item -LiteralPath $Path -Recurse -Force
        Complete-JournalAction
        Write-Notice "Cle sauvegardee et reinitialisee : $Path"
    }
}

function Move-BackedUpCache {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { Write-Notice "Absent, aucune action : $Path"; return }
    Assert-NoReparsePath $Path
    if (Confirm-Change $Path 'Renommer ce cache pour le regenerer (reconnexion necessaire)') {
        Initialize-Run User
        $backup = $Path + '.58tm1-backup-' + $script:Journal.RunId
        if (Test-Path -LiteralPath $backup) { throw "Sauvegarde deja presente : $backup" }
        Add-JournalAction @{ Type = 'Cache'; Path = $Path; Backup = $backup }
        Move-Item -LiteralPath $Path -Destination $backup
        Complete-JournalAction
        Write-Notice "Cache sauvegarde par renommage : $Path"
    }
}

function Set-BackedUpValue {
    param([string]$Path, [string]$Name, $Value, [string]$Kind, [switch]$Remove, [string]$Scope = 'User')
    $old = Get-ValueState $Path $Name
    if ($old.Exists -and $old.Kind -notin @('DWord','QWord','String','ExpandString')) { throw "Type de registre inattendu : $Path\$Name" }
    if ($Remove -and -not $old.Exists) { return }
    if (-not $Remove -and $old.Exists -and "$($old.Value)" -eq "$Value" -and $old.Kind -eq $Kind) { return }
    if (Confirm-Change "$Path\$Name" 'Sauvegarder et modifier la valeur') {
        Initialize-Run $Scope
        Add-JournalAction @{ Type = 'RegistryValue'; Path = $Path; Name = $Name; Existed = $old.Exists; Value = $old.Value; Kind = $old.Kind }
        if ($Remove) { Remove-ItemProperty -LiteralPath $Path -Name $Name }
        else {
            if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
            New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Kind -Force | Out-Null
        }
        Complete-JournalAction
        Write-Notice "Valeur modifiee : $Path\$Name"
    }
}

function Invoke-ModernAuthRepair {
    foreach ($name in @('DisableAADWAM','DisableADALatopWAMOverride','EnableADAL')) {
        $old = Get-ValueState $script:IdentityKey $name
        $bad = $old.Exists -and (($name -eq 'EnableADAL' -and "$($old.Value)" -eq '0') -or
            ($name -ne 'EnableADAL' -and "$($old.Value)" -eq '1'))
        if ($bad) { Set-BackedUpValue $script:IdentityKey $name -Remove }
    }
}

function Invoke-BrokerRepair {
    $package = @(Get-AppxPackage -Name Microsoft.AAD.BrokerPlugin -ErrorAction Stop)
    $healthy = $package.Count -gt 0 -and @($package | Where-Object { "$($_.Status)" -ne 'Ok' }).Count -eq 0
    if ($healthy -and -not $ReregisterBroker) { Write-Notice 'Broker deja enregistre, statut OK ; reenregistrement force non demande.'; return }
    $manifest = Get-BrokerManifest
    if (Confirm-Change $manifest 'Reenregistrer le Broker pour cet utilisateur uniquement') {
        Initialize-Run User
        Add-JournalAction @{ Type = 'AppxRegistration'; Path = $manifest }
        Add-AppxPackage -Register $manifest -DisableDevelopmentMode -ErrorAction Stop
        $after = @(Get-AppxPackage -Name Microsoft.AAD.BrokerPlugin -ErrorAction Stop)
        if (-not $after.Count -or @($after | Where-Object { "$($_.Status)" -ne 'Ok' }).Count) {
            throw 'Le reenregistrement ne donne pas un package Broker de statut OK.'
        }
        Complete-JournalAction
        Write-Notice 'Broker reenregistre. Cette operation additive ne sera pas annulee par une desinstallation.'
    }
}

function Invoke-UserRepair {
    Assert-InteractiveUser
    Assert-SelectedEnvironment
    Assert-AppsClosed
    $blockers = @(Get-AuthPolicyBlockers)
    if ($blockers.Count) { throw ('Strategie bloquant WAM/ADAL : corriger la GPO source, puis relancer. ' + ($blockers -join '; ')) }
    if (-not (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue) -or
        -not (Get-Command Add-AppxPackage -ErrorAction SilentlyContinue)) { throw 'Composants AppX indisponibles. Utiliser Windows PowerShell 5.1 sur un OS avec WAM.' }
    if (-not (Test-Path -LiteralPath (Get-BrokerManifest))) { throw 'Manifeste du Broker absent. Diagnostiquer les composants Windows et la compatibilite avant toute purge.' }
    Write-Notice ('Plan : ' + ((Get-RepairPlan -Identity:$ResetOfficeIdentity -TokenBroker:$ResetTokenBrokerAccounts -Licensing:$ResetOfficeLicensing) -join ', '))
    Invoke-ModernAuthRepair
    Invoke-BrokerRepair
    if ($ResetOfficeIdentity) { Remove-BackedUpKey $script:IdentityKey }
    $targets = @(Get-CacheTargets)
    if ($ResetTokenBrokerAccounts) { Move-BackedUpCache $targets[0] }
    if ($ResetOfficeLicensing) {
        Move-BackedUpCache $targets[1]
        Move-BackedUpCache $targets[2]
        Remove-BackedUpKey $script:LicensingKey
    }
    if ($WhatIfPreference) { Write-Notice 'Simulation terminee. Aucune reparation effectuee.' }
    elseif ($script:AnySkipped) { Write-Notice 'Certaines operations ont ete refusees. Aucune reussite de campagne ne sera enregistree.' }
    else { Write-Notice 'Operations locales terminees. Ouvrir Word et verifier la connexion ; un MFA peut etre demande.' }
}

function Get-Audit {
    $os = Get-CimInstance Win32_OperatingSystem
    $warnings = New-Object 'System.Collections.Generic.List[string]'
    $office = Get-SelectedValues $script:OfficeConfig @('VersionToReport','ProductReleaseIds','Platform','UpdateChannel','SharedComputerLicensing','SCLCacheOverride','SCLCacheOverrideDirectory')
    $fs = [ordered]@{}
    foreach ($branch in @('Profiles','ODFC')) {
        $path = if ($branch -eq 'ODFC') { 'HKLM:\SOFTWARE\Policies\FSLogix\ODFC' } else { 'HKLM:\SOFTWARE\FSLogix\Profiles' }
        $fs[$branch] = Get-SelectedValues $path @('Enabled','RoamIdentity','IncludeOfficeActivation','IncludeOfficeFileCache','IncludeOutlook','RedirXMLSourceFolder','ProfileType','VHDAccessMode')
    }
    $frx = Join-Path $env:ProgramFiles 'FSLogix\Apps\frxsvc.exe'
    $fs.Version = if (Test-Path -LiteralPath $frx) { (Get-Item -LiteralPath $frx).VersionInfo.FileVersion } else { $null }
    $fs.Service = @(Get-Service -Name frxsvc -ErrorAction SilentlyContinue | Select-Object Name, Status, StartType)
    $identity = Get-SelectedValues $script:IdentityKey @('EnableADAL','DisableAADWAM','DisableADALatopWAMOverride')
    $policy = [ordered]@{}
    foreach ($hive in @('HKCU','HKLM')) {
        $policy[$hive] = Get-SelectedValues ("${hive}:\Software\Policies\Microsoft\Office\16.0\Common\Identity") @('EnableADAL','DisableAADWAM','DisableADALatopWAMOverride')
    }
    $sharedPolicy = Get-SelectedValues 'HKLM:\SOFTWARE\Policies\Microsoft\Office\16.0\Common\Licensing' @('SharedComputerLicensing')
    $broker = @()
    if (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue) {
        try { $broker = @(Get-AppxPackage -Name Microsoft.AAD.BrokerPlugin | Select-Object Name, Version, Status) }
        catch { $warnings.Add('Lecture du package Broker impossible : ' + $_.Exception.Message) }
    } else { $warnings.Add('Get-AppxPackage indisponible dans cet interpreteur.') }
    $states = [ordered]@{}
    $dsreg = Join-Path $env:windir 'System32\dsregcmd.exe'
    if (Test-Path -LiteralPath $dsreg) {
        $lines = & $dsreg /status 2>&1
        if ($LASTEXITCODE -eq 0) {
            foreach ($line in $lines) {
                if ("$line" -match '^\s*(AzureAdJoined|EnterpriseJoined|DomainJoined|WorkplaceJoined|AzureAdPrt|WamDefaultSet|DeviceAuthStatus)\s*:\s*(.*?)\s*$') {
                    $states[$matches[1]] = $matches[2]
                }
            }
        } else { $warnings.Add('dsregcmd /status a echoue. Aucun etat de jointure deduit.') }
    }
    $events = @()
    try {
        $sid = Get-CurrentSid
        $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-AAD/Operational'; StartTime = (Get-Date).AddDays(-3); Level = @(2,3) } -MaxEvents 100 -ErrorAction Stop |
            Where-Object { $_.UserId -and $_.UserId.Value -eq $sid } | ForEach-Object {
                [pscustomobject]@{ TimeCreated = $_.TimeCreated; Id = $_.Id
                    Codes = @([regex]::Matches([string]$_.Message, '(?i)\b0x[0-9a-f]{8,16}\b|\b58tm1\b') | ForEach-Object Value | Sort-Object -Unique) }
            })
    } catch { $warnings.Add('Journal AAD absent, sans evenement accessible ou acces refuse ; ce n''est pas un test reussi.') }
    $network = [ordered]@{ Tested = $false; Success = $null; Detail = 'Non demande' }
    if ($TestNetwork) {
        $network.Tested = $true
        try {
            $response = Invoke-WebRequest -Uri 'https://login.microsoftonline.com/common/v2.0/.well-known/openid-configuration' -UseBasicParsing -TimeoutSec 20
            $metadata = $response.Content | ConvertFrom-Json
            $network.Success = $response.StatusCode -eq 200 -and $metadata.authorization_endpoint -like 'https://login.microsoftonline.com/*'
            $network.Detail = 'Metadonnees Entra anonymes uniquement ; ne valide ni MFA, ni licence, ni tous les endpoints Office.'
        } catch { $network.Success = $false; $network.Detail = $_.Exception.Message }
    }
    if ($fs.Profiles.RoamIdentity -eq 1) { $warnings.Add('RoamIdentity=1 : revoir la necessite et la documentation FSLogix pour ce mode de jointure. Aucun changement automatique.') }
    if ($office.ProductReleaseIds -match 'O365' -and "$($office.SharedComputerLicensing)" -ne '1') { $warnings.Add('Activation partagee non detectee dans la configuration C2R. Verifier les strategies et les droits de licence RDS.') }
    if (@(Get-AuthPolicyBlockers).Count) { $warnings.Add('Une strategie desactive WAM/ADAL. Corriger sa source, sans la contourner localement.') }
    $warnings.Add('Verifier les cycles de support exacts Windows Server / canal Office / FSLogix. Aucun KB universel pour le tag 58TM1.')
    return [ordered]@{
        Schema = 1; TimestampUtc = [DateTime]::UtcNow.ToString('o'); Computer = $env:COMPUTERNAME; SelectedEnvironment = $Environment
        UserSid = Get-CurrentSid; SessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
        OS = @{ Caption = $os.Caption; Version = $os.Version; Build = $os.BuildNumber; Architecture = $os.OSArchitecture
            UBR = (Get-ValueState 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'UBR').Value }
        Office = $office; SharedComputerPolicy = $sharedPolicy; FSLogix = $fs; Identity = $identity; IdentityPolicies = $policy
        Broker = $broker; BrokerManifestPresent = Test-Path -LiteralPath (Get-BrokerManifest)
        DeviceStates = $states; RecentAadErrorsForCurrentSid = $events; Network = $network; Warnings = @($warnings.ToArray())
    }
}

function Invoke-HostConfiguration {
    Assert-Administrator
    Assert-SelectedEnvironment
    if (-not $EnableSharedComputerActivation) { throw 'Choisir explicitement -EnableSharedComputerActivation apres verification des droits de licence.' }
    $product = (Get-ValueState $script:OfficeConfig 'ProductReleaseIds').Value
    if ("$product" -notmatch '(^|,)(O365ProPlusRetail|O365BusinessRetail)(,|$)') {
        throw 'Installation Microsoft 365 Apps C2R compatible non identifiee. Aucune modification de licence.'
    }
    $policy = Get-ValueState 'HKLM:\SOFTWARE\Policies\Microsoft\Office\16.0\Common\Licensing' 'SharedComputerLicensing'
    if ($policy.Exists -and "$($policy.Value)" -ne '1') { throw 'Strategie SharedComputerLicensing contradictoire : corriger la GPO source.' }
    Set-BackedUpValue $script:OfficeConfig 'SharedComputerLicensing' '1' 'String' -Scope Host
    if ($WhatIfPreference -or $script:AnySkipped) { Write-Notice 'SCA : simulation ou operation refusee ; aucune modification annoncee comme appliquee.' }
    else { Write-Notice 'Configuration SCA verifiee/ecrite. Droits de licence et reactivation Office restent a verifier.' }
}

function Assert-NoReparsePath {
    param([string]$Path)
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Lien/jonction detecte : $current. Operation refusee ; analyser la redirection du profil."
            }
        }
        $parent = [IO.Path]::GetDirectoryName($current)
        if ($parent -eq $current) { break }
        $current = $parent
    }
}

function Initialize-ProtectedDirectory {
    param([string]$Path, [switch]$AllowUsersRead)
    Assert-NoReparsePath $Path
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-18','S-1-5-32-544')) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule(
            (New-Object Security.Principal.SecurityIdentifier($sid)), 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    # Users may read/execute the staged script, never replace it.
    if ($AllowUsersRead) {
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
            (New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')), 'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
    }
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Get-DeploymentMarker {
    param([string]$Id)
    # Host included because LOCALAPPDATA may roam in a profile container.
    $hostKey = $env:COMPUTERNAME -replace '[^A-Za-z0-9_-]', '_'
    return Join-Path $env:LOCALAPPDATA ("58tm1\Markers\$hostKey-$Id.json")
}

function Install-RepairTask {
    Assert-Administrator
    Assert-SelectedEnvironment
    if (-not (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue)) { throw 'Module ScheduledTasks indisponible.' }
    if (Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue) {
        throw 'Tache deja presente. Retirer la tache avec RemoveLogonTask avant une nouvelle campagne.'
    }
    $installDir = Join-Path $env:ProgramData '58tm1\Agent'
    $installedScript = Join-Path $installDir 'Repair-58TM1.ps1'
    if (Confirm-Change $script:TaskName "Installer une reparation a l'ouverture de session, campagne $DeploymentId") {
        Initialize-ProtectedDirectory (Join-Path $env:ProgramData '58tm1') -AllowUsersRead
        Initialize-ProtectedDirectory $installDir -AllowUsersRead
        if ([IO.Path]::GetFullPath($script:SourcePath) -ne [IO.Path]::GetFullPath($installedScript)) {
            Assert-NoReparsePath $installedScript
            $stage = Join-Path $installDir ([Guid]::NewGuid().ToString('N') + '.ps1')
            Copy-Item -LiteralPath $script:SourcePath -Destination $stage
            # Reset file ACL even if the source had explicit permissions.
            $acl = New-Object Security.AccessControl.FileSecurity
            $acl.SetAccessRuleProtection($false, $false)
            Set-Acl -LiteralPath $stage -AclObject $acl
            Move-Item -LiteralPath $stage -Destination $installedScript -Force
        }
        $arguments = '-NoProfile -NonInteractive -File "' + $installedScript + '" -Mode RepairUser -Once -Environment ' + $Environment + ' -DeploymentId ' + $DeploymentId
        foreach ($name in @('ReregisterBroker','ResetOfficeIdentity','ResetTokenBrokerAccounts','ResetOfficeLicensing')) {
            if (Get-Variable -Name $name -ValueOnly) { $arguments += " -$name" }
        }
        $exe = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $action = New-ScheduledTaskAction -Execute $exe -Argument $arguments -WorkingDirectory $installDir
        $trigger = New-ScheduledTaskTrigger -AtLogOn
        $principal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -MultipleInstances Parallel -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description "58TM1 - reparation utilisateur limitee - $DeploymentId" | Out-Null
        Write-Notice 'Tache installee. Tester une nouvelle ouverture de session pilote puis les resultats et marqueurs.'
    }
}

function Assert-Manifest {
    param($Data)
    if ($Data.Schema -ne 1 -or $Data.RunId -notmatch '^\d{8}T\d{6}Z-[a-f0-9]{32}$' -or $Data.Scope -notin @('User','Host')) { throw 'Format de manifeste invalide.' }
    if ($Data.Computer -ne $env:COMPUTERNAME) { throw 'Ce manifeste appartient a un autre hote.' }
    if ($Data.Scope -eq 'User' -and $Data.Sid -ne (Get-CurrentSid)) { throw 'Ce manifeste appartient a un autre utilisateur.' }
    $cacheTargets = @(Get-CacheTargets)
    foreach ($a in @($Data.Actions)) {
        if ($a.State -notin @('Prepared','Applied')) { throw 'Etat d''action invalide.' }
        switch ($a.Type) {
            'RegistryKey' {
                if ($Data.Scope -ne 'User' -or $a.Path -notin @($script:IdentityKey,$script:LicensingKey)) { throw 'Cle de restauration non autorisee.' }
                if ($a.Existed -and ($a.Backup -notmatch '^[a-f0-9]{32}\.reg$' -or $a.Hash -notmatch '^[A-Fa-f0-9]{64}$')) { throw 'Sauvegarde registre invalide.' }
            }
            'RegistryValue' {
                $userAllowed = $Data.Scope -eq 'User' -and $a.Path -eq $script:IdentityKey -and $a.Name -in @('DisableAADWAM','DisableADALatopWAMOverride','EnableADAL')
                $hostAllowed = $Data.Scope -eq 'Host' -and $a.Path -eq $script:OfficeConfig -and $a.Name -eq 'SharedComputerLicensing'
                if (-not ($userAllowed -or $hostAllowed)) { throw 'Valeur de restauration non autorisee.' }
                if ($a.Existed -and $a.Kind -notin @('DWord','QWord','String','ExpandString')) { throw 'Type de registre inattendu.' }
            }
            'Cache' {
                if ($Data.Scope -ne 'User' -or $a.Path -notin $cacheTargets -or $a.Backup -ne ($a.Path + '.58tm1-backup-' + $Data.RunId)) { throw 'Chemin de cache non autorise.' }
            }
            'AppxRegistration' {
                if ($Data.Scope -ne 'User' -or $a.Path -ne (Get-BrokerManifest)) { throw 'Package de restauration non autorise.' }
            }
            default { throw 'Type d''action non autorise.' }
        }
    }
}

function Restore-Repair {
    if (-not $ManifestPath) { throw '-ManifestPath est obligatoire pour Restore.' }
    $fullManifest = (Resolve-Path -LiteralPath $ManifestPath).ProviderPath
    Assert-NoReparsePath $fullManifest
    $data = Get-Content -LiteralPath $fullManifest -Raw | ConvertFrom-Json
    Assert-Manifest $data
    if ($data.Scope -eq 'Host') {
        Assert-Administrator
        $trustedRoot = [IO.Path]::GetFullPath((Join-Path $env:ProgramData '58tm1\Runs')) + '\'
        if (-not $fullManifest.StartsWith($trustedRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Un manifeste Host doit rester dans ProgramData\58tm1\Runs.' }
    } else {
        Assert-InteractiveUser
        $tokenTarget = @(Get-CacheTargets)[0]
        $restoresTokens = @($data.Actions | Where-Object { $_.Type -eq 'Cache' -and $_.Path -eq $tokenTarget }).Count -gt 0
        Assert-AppsClosed -IncludeOtherMicrosoftApps:$restoresTokens
    }
    $directory = Split-Path -Parent $fullManifest
    if (Test-Path -LiteralPath (Join-Path $directory 'restore-completed.json')) { throw 'Retour arriere deja termine pour ce manifeste.' }
    $progressPath = Join-Path $directory 'restore-progress.json'
    $manifestHash = (Get-FileHash -LiteralPath $fullManifest -Algorithm SHA256).Hash
    $progress = [pscustomobject]@{ ManifestHash = $manifestHash; Completed = @() }
    if (Test-Path -LiteralPath $progressPath) {
        Assert-NoReparsePath $progressPath
        $progress = Get-Content -LiteralPath $progressPath -Raw | ConvertFrom-Json
        if ($progress.ManifestHash -ne $manifestHash) { throw 'Le manifeste a change depuis le debut du retour arriere.' }
        foreach ($index in @($progress.Completed)) {
            if ($index -isnot [int] -and $index -isnot [long]) { throw 'Index de reprise invalide.' }
            if ($index -lt 0 -or $index -ge @($data.Actions).Count) { throw 'Index de reprise hors limites.' }
        }
    }
    # Validate ALL available backups before starting any restoration.
    for ($i = 0; $i -lt @($data.Actions).Count; $i++) {
        if ($i -in @($progress.Completed)) { continue }
        $a = $data.Actions[$i]
        if ($a.Type -eq 'RegistryKey' -and $a.Existed) {
            $file = Join-Path $directory $a.Backup
            Assert-NoReparsePath $file
            if (-not (Test-Path -LiteralPath $file) -or (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $a.Hash) { throw 'Sauvegarde registre absente ou integrite invalide.' }
            Assert-RegistryBackupContent $file $a.Path
        }
        if ($a.Type -eq 'Cache') {
            Assert-NoReparsePath $a.Path
            Assert-NoReparsePath $a.Backup
            if ($a.State -eq 'Applied' -and -not (Test-Path -LiteralPath $a.Backup)) { throw 'Sauvegarde de cache absente. Arret avant restauration.' }
        }
    }
    for ($i = @($data.Actions).Count - 1; $i -ge 0; $i--) {
        if ($i -in @($progress.Completed)) { continue }
        $a = $data.Actions[$i]
        if ($a.Type -eq 'AppxRegistration') { Write-Notice 'Enregistrement AppX conserve ; aucune desinstallation.'; continue }
        if (-not (Confirm-Change $a.Path 'Restaurer la sauvegarde locale ; les jetons peuvent etre expires')) { continue }
        switch ($a.Type) {
            'RegistryValue' {
                Initialize-Run $data.Scope
                $before = Get-ValueState $a.Path $a.Name
                Add-JournalAction @{ Type = 'RegistryValue'; Path = $a.Path; Name = $a.Name; Existed = $before.Exists; Kind = $before.Kind; Value = $before.Value }
                if ($a.Existed) {
                    if (-not (Test-Path -LiteralPath $a.Path)) { New-Item -Path $a.Path -Force | Out-Null }
                    New-ItemProperty -LiteralPath $a.Path -Name $a.Name -Value $a.Value -PropertyType $a.Kind -Force | Out-Null
                } elseif (Test-Path -LiteralPath $a.Path) { Remove-ItemProperty -LiteralPath $a.Path -Name $a.Name -ErrorAction SilentlyContinue }
                Complete-JournalAction
            }
            'RegistryKey' {
                Initialize-Run $data.Scope
                Add-JournalAction (Backup-RegistryKey $a.Path)
                if (Test-Path -LiteralPath $a.Path) { Remove-Item -LiteralPath $a.Path -Recurse -Force }
                if ($a.Existed) {
                    $output = & "$env:windir\System32\reg.exe" import (Join-Path $directory $a.Backup) 2>&1
                    if ($LASTEXITCODE -ne 0) { throw "Import de sauvegarde impossible : $output" }
                }
                Complete-JournalAction
            }
            'Cache' {
                if (-not (Test-Path -LiteralPath $a.Backup)) { Write-Notice 'Action preparee mais aucun cache renomme : aucune restauration.'; continue }
                # Keep the newly generated cache too; never recursively delete it.
                if (Test-Path -LiteralPath $a.Path) {
                    $displaced = $a.Path + '.58tm1-before-restore-' + [Guid]::NewGuid().ToString('N')
                    Move-Item -LiteralPath $a.Path -Destination $displaced
                    Write-Notice "Cache regenere conserve : $displaced"
                }
                Move-Item -LiteralPath $a.Backup -Destination $a.Path
                Write-Notice "Cache restaure : $($a.Path)"
            }
        }
        $progress.Completed = @($progress.Completed) + $i
        $progressTemp = Join-Path $directory 'restore-progress.tmp'
        $progress | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $progressTemp -Encoding UTF8
        Move-Item -LiteralPath $progressTemp -Destination $progressPath -Force
    }
    # No marker for partial/declined/-WhatIf restoration.
    if (-not $WhatIfPreference -and -not $script:AnySkipped -and (Confirm-Change $fullManifest 'Marquer cette restauration comme terminee')) {
        @{ CompletedUtc = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $directory 'restore-completed.json') -Encoding UTF8
    }
}

function Invoke-Repair58Main {
    param([System.Management.Automation.PSCmdlet]$Caller)
    $script:Caller = $Caller
    Assert-Windows
    if ($PSVersionTable.PSEdition -eq 'Core') { throw 'Executer avec Windows PowerShell 5.1 (powershell.exe), requis pour AppX et ScheduledTasks.' }
    if ($Once -and $Mode -ne 'RepairUser') { throw '-Once est reserve au mode RepairUser.' }
    if ($EnableSharedComputerActivation -and $Mode -ne 'ConfigureHost') { throw '-EnableSharedComputerActivation est reserve au mode ConfigureHost.' }
    if ($TestNetwork -and $Mode -ne 'Audit') { throw '-TestNetwork est reserve au mode Audit.' }
    if ($ManifestPath -and $Mode -ne 'Restore') { throw '-ManifestPath est reserve au mode Restore.' }
    if ($Mode -notin @('RepairUser','InstallLogonTask') -and ($ResetOfficeIdentity -or $ResetTokenBrokerAccounts -or $ResetOfficeLicensing -or $ReregisterBroker)) { throw 'Options de reparation utilisateur incompatibles avec ce mode.' }
    $marker = if ($Once) { Get-DeploymentMarker $DeploymentId } else { $null }
    $mutex = $null
    $ownsMutex = $false
    try {
        if ($Mode -in @('RepairUser','Restore')) {
            # Global Windows namespace: also excludes another RDS session of this SID.
            # This cannot coordinate different hosts sharing a profile container.
            $mutex = New-Object Threading.Mutex($false, ('Global\58tm1-User-' + (Get-CurrentSid)))
            try { $ownsMutex = $mutex.WaitOne(0) }
            catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
            if (-not $ownsMutex) { throw 'Une autre operation 58tm1 utilise deja ce compte sur cet hote. Reessayer apres sa fin.' }
        }
        if ($marker -and (Test-Path -LiteralPath $marker)) { Write-Notice 'Campagne deja executee localement pour cet utilisateur sur cet hote.'; return }
        switch ($Mode) {
            'Audit' {
                $audit = Get-Audit
                if (Confirm-Change 'Rapport local 58tm1' 'Ecrire le rapport de diagnostic') {
                    Initialize-Run User
                    $audit | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath (Join-Path $script:RunDirectory 'audit.json') -Encoding UTF8
                }
                $audit | ConvertTo-Json -Depth 16 | Write-Output
            }
            'RepairUser' { Invoke-UserRepair }
            'ConfigureHost' { Invoke-HostConfiguration }
            'InstallLogonTask' { Install-RepairTask }
            'RemoveLogonTask' {
                Assert-Administrator
                if (Confirm-Change $script:TaskName 'Retirer la tache ; conserver les sauvegardes et le script installe') {
                    if (Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false }
                }
            }
            'Restore' { Restore-Repair }
        }
        if ($script:Journal) {
            $script:Journal.Status = if ($script:AnySkipped) { 'PartialOrDeclined' } else { 'LocalOperationsCompleted' }
            Save-Journal
        }
        if ($marker -and -not $WhatIfPreference -and -not $script:AnySkipped -and (Confirm-Change $marker 'Marquer la campagne locale terminee (connexion Office non validee)')) {
            New-Item -ItemType Directory -Path (Split-Path -Parent $marker) -Force | Out-Null
            @{ CompletedUtc = [DateTime]::UtcNow.ToString('o'); DeploymentId = $DeploymentId; ConnectionVerified = $false } |
                ConvertTo-Json | Set-Content -LiteralPath $marker -Encoding UTF8
        }
    } catch {
        $failure = $_
        if (-not $WhatIfPreference) {
            try {
                if (-not $script:Journal -and $Mode -eq 'RepairUser') { Initialize-Run User }
                if ($script:Journal) {
                    $script:Journal.Status = 'FailedOrPartial'
                    Save-Journal
                    Write-Notice ('ECHEC : ' + $failure.Exception.Message)
                    Write-Notice 'Echec/operation partielle. Consulter le journal et les sauvegardes.'
                }
            } catch { Write-Warning ('Journalisation de l''erreur impossible : ' + $_.Exception.Message) }
        }
        throw $failure
    } finally {
        if ($ownsMutex) { $mutex.ReleaseMutex() }
        if ($mutex) { $mutex.Dispose() }
    }
}

# Dot-sourcing loads functions for offline tests only; it never runs a repair.
if ($MyInvocation.InvocationName -ne '.') { Invoke-Repair58Main $PSCmdlet }
