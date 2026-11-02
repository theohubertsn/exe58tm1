#requires -Version 5.1
[CmdletBinding()]
param([string]$Executable)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $Executable) { $Executable = Join-Path $root 'dist/desktop/58TM1.exe' }
Add-Type -Path (Join-Path $root 'desktop/OperationRequest.cs')
$script:PassedDesktop = 0
function Check([bool]$Value, [string]$Name) {
    if (-not $Value) { throw "ECHEC : $Name" }
    $script:PassedDesktop++; Write-Host "PASS $Name"
}
function Reject([scriptblock]$Body, [string]$Name) {
    $rejected = $false
    try { & $Body } catch { $rejected = $true }
    Check $rejected $Name
}
function New-Request {
    $r = New-Object Repair58Desktop.OperationRequest
    $r.Mode='Audit';$r.Environment='RDSFSLogix';$r.DeploymentId='Pilot-01';$r.Simulation=$true
    return $r
}
$r = New-Request
$r.Validate()
Check (-not $r.RequiresAdmin) 'Audit sans elevation'
$argsText = $r.Arguments('C:\Kit Office\Repair-58TM1.ps1')
Check ($argsText.Contains('"-File" "C:\Kit Office\Repair-58TM1.ps1"')) 'Chemin du moteur avec espaces'
Check ($argsText.Contains('"-WhatIf"')) 'Simulation transmise au moteur'
Check (-not $argsText.Contains('ExecutionPolicy')) 'Aucun contournement de strategie PowerShell'
Check (-not $argsText.Contains('-Command')) 'Aucune evaluation de commande construite'
Check ([Repair58Desktop.OperationRequest]::Quote('C:\fin\') -eq '"C:\fin\\"') 'Echappement du backslash final Windows'
Check ([Repair58Desktop.OperationRequest]::Quote('a"b') -eq '"a\"b"') 'Echappement des guillemets Windows'
Reject { [Repair58Desktop.OperationRequest]::Quote("test`nsecond") } 'Refus des arguments multiligne'
foreach ($mode in @('ConfigureHost','InstallLogonTask','RemoveLogonTask')) {
    $r=New-Request;$r.Mode=$mode;$r.Validate();Check $r.RequiresAdmin "Elevation pour $mode"
}
$r=New-Request;$r.Mode='RepairUser';$r.ResetOfficeIdentity=$true;$r.Simulation=$false
Check (-not $r.RequiresAdmin) 'Reparation utilisateur sans elevation'
Check ($r.Arguments('engine.ps1').Contains('"-ResetOfficeIdentity"')) 'Option ciblee transmise'
Check (-not $r.Arguments('engine.ps1').Contains('-WhatIf')) 'Mode application sans simulation'
$r=New-Request;$r.Mode='Restore';$r.ManifestPath='C:\Users\Jean Paul\manifest.json'
Check (-not $r.RequiresAdmin) 'Restauration utilisateur sans elevation'
$r.HostRestore=$true;Check $r.RequiresAdmin 'Restauration hote avec elevation'
Check ($r.Arguments('engine.ps1').Contains('"C:\Users\Jean Paul\manifest.json"')) 'Manifeste avec espaces'
$r=New-Request;$r.Mode='RunAnything';Reject { $r.Validate() } 'Refus dune action arbitraire'
$r=New-Request;$r.Environment='Injected';Reject { $r.Validate() } 'Refus dun environnement arbitraire'
$r=New-Request;$r.DeploymentId='test;whoami';Reject { $r.Validate() } 'Refus dune campagne avec injection'
$r=New-Request;$r.PipeName='arbitrary';Reject { $r.Validate() } 'Canal local au format contraint'
$r=New-Request;$r.ResetOfficeIdentity=$true;Reject { $r.Validate() } 'Options de mutation refusees pour audit'
$r=New-Request;$r.Mode='RepairUser';$r.TestNetwork=$true;Reject { $r.Validate() } 'Test reseau reserve au diagnostic'
$r=New-Request;$r.HostRestore=$true;Reject { $r.Validate() } 'Restauration hote reservee a Restore'
$r=New-Request;$r.Mode='Restore';Reject { $r.Validate() } 'Manifeste obligatoire'
$r.ManifestPath='C:\bad"path';Reject { $r.Validate() } 'Refus dun chemin de manifeste invalide'

# PE metadata inspection only: this does not execute the Windows application.
$bytes=[IO.File]::ReadAllBytes($Executable)
$stream=[IO.MemoryStream]::new($bytes, $false)
if ($PSVersionTable.PSEdition -eq 'Core') {
    $pe=[Reflection.PortableExecutable.PEReader]::new($stream)
    try {
        Check ($pe.PEHeaders.CoffHeader.Machine.ToString() -eq 'Amd64') 'EXE cible AMD64'
        Check ($pe.PEHeaders.PEHeader.Subsystem.ToString() -eq 'WindowsGui') 'Sous-systeme application graphique Windows'
        Check ($pe.PEHeaders.CorHeader.Flags.ToString() -match 'ILOnly') 'Binaire CLR gere'
    } finally { $pe.Dispose() }
} else { $stream.Dispose() }
$assembly=[Reflection.Assembly]::Load($bytes)
Check ($assembly.GetName().Version.ToString() -eq '0.2.0.0') 'Version de lassemblage'
$indexStream=$assembly.GetManifestResourceStream('58tm1.payload.index')
$reader=[IO.StreamReader]::new($indexStream)
try { $lines=$reader.ReadToEnd() -split '\r?\n' | Where-Object { $_ } } finally { $reader.Dispose() }
Check (@($lines).Count -eq 9) 'Neuf ressources utiles integrees'
foreach ($line in $lines) {
    $expected=$line.Substring(0,64);$name=$line.Substring(66)
    $resource=$assembly.GetManifestResourceStream('58tm1.payload.'+$name)
    $sha=[Security.Cryptography.SHA256]::Create()
    try { $actual=[BitConverter]::ToString($sha.ComputeHash($resource)).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose();$resource.Dispose() }
    Check ($actual -eq $expected) "Integrite ressource embarquee $name"
    Check ((Get-FileHash -LiteralPath (Join-Path $root $name) -Algorithm SHA256).Hash.ToLowerInvariant() -eq $expected) "Ressource identique au source $name"
}
$raw=[Text.Encoding]::UTF8.GetString($bytes)
Check ($raw.Contains('requestedExecutionLevel level="asInvoker"')) 'Manifeste sans elevation globale'
Write-Host "Resultat Desktop : $script:PassedDesktop tests reussis. Aucun lancement Windows realise."
