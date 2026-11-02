#requires -Version 5.1
[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Interface disponible sous Windows uniquement.' }
if (-not [Environment]::Is64BitProcess -or $PSVersionTable.PSEdition -eq 'Core') { throw 'Utiliser Start-58TM1.cmd avec Windows PowerShell 5.1 64 bits.' }
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$script:repair = Join-Path $PSScriptRoot 'Repair-58TM1.ps1'
if (-not (Test-Path -LiteralPath $script:repair)) { throw 'Repair-58TM1.ps1 doit etre dans le meme dossier.' }
$script:choices = @(
    [pscustomobject]@{ Label = 'Diagnostic (aucune modification de configuration)'; Mode = 'Audit'; Admin = $false; Detail = 'Releve versions, WAM, activation partagee et parametres FSLogix. Rapport local uniquement.' },
    [pscustomobject]@{ Label = 'Reparer la session utilisateur'; Mode = 'RepairUser'; Admin = $false; Detail = 'Dans la session affectee : fermer Office. Retire les contournements locaux WAM/ADAL nuisibles et reenregistre le Broker si necessaire.' },
    [pscustomobject]@{ Label = 'Tous les utilisateurs : prochaine ouverture de session'; Mode = 'InstallLogonTask'; Admin = $true; Detail = 'Administrateur : installe une tache limitee a chaque ouverture de session. Pilote obligatoire avant generalisation. Ne ferme aucune session existante.' },
    [pscustomobject]@{ Label = 'Hote : activer Shared Computer Activation'; Mode = 'ConfigureHost'; Admin = $true; Detail = 'Administrateur : exige Microsoft 365 Apps Click-to-Run et des licences eligibles. Ecrit SharedComputerLicensing=1 ; ne corrige pas a elle seule WAM.' },
    [pscustomobject]@{ Label = 'Retirer la tache pour tous les utilisateurs'; Mode = 'RemoveLogonTask'; Admin = $true; Detail = 'Retire les reparations futures. Conserve les sauvegardes, les marqueurs et les changements deja appliques.' },
    [pscustomobject]@{ Label = 'Restaurer une sauvegarde utilisateur'; Mode = 'Restore'; Admin = $false; Detail = 'Choisir le manifest.json de la session concernee. Meme utilisateur et meme hote. Pour une sauvegarde Host : utiliser la commande administrateur du guide.' }
)
$form = New-Object Windows.Forms.Form
$form.Text = '58TM1 - Office / RDS / FSLogix'
$form.ClientSize = New-Object Drawing.Size(790, 670)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.Font = New-Object Drawing.Font('Segoe UI', 10)
function Add-Label([string]$Text, [int]$X, [int]$Y, [int]$Width, [int]$Height) {
    $label = New-Object Windows.Forms.Label
    $label.Text = $Text; $label.SetBounds($X, $Y, $Width, $Height)
    $form.Controls.Add($label)
    return $label
}
$null = Add-Label 'Outil de diagnostic et reparations ciblees - aucun correctif universel pour 58TM1.' 18 15 755 28
$null = Add-Label 'Environnement (la version de Windows est detectee par l''audit)' 18 52 750 24
$environmentBox = New-Object Windows.Forms.ComboBox
$environmentBox.DropDownStyle = 'DropDownList'; $environmentBox.SetBounds(18, 78, 750, 30)
$environmentBox.Items.AddRange(@('Auto / session locale','Serveur RDS','Serveur RDS + FSLogix'))
$environmentBox.SelectedIndex = 0; $form.Controls.Add($environmentBox)
$null = Add-Label 'Action' 18 120 750 24
$actionBox = New-Object Windows.Forms.ComboBox
$actionBox.DropDownStyle = 'DropDownList'; $actionBox.SetBounds(18, 146, 750, 30)
foreach ($choice in $script:choices) { $null = $actionBox.Items.Add($choice.Label) }
$actionBox.SelectedIndex = 0; $form.Controls.Add($actionBox)
$detail = Add-Label '' 18 187 750 65
$checks = @{}
$rows = @(
    @('ReregisterBroker','Forcer le reenregistrement du Broker',260),
    @('ResetOfficeIdentity','Reinitialiser les identites Office (reconnexion requise)',291),
    @('ResetTokenBrokerAccounts','Reinitialiser TokenBroker Accounts (autres apps Microsoft concernees)',322),
    @('ResetOfficeLicensing','Reinitialiser les licences utilisateur Office (reactivation requise)',353)
)
foreach ($row in $rows) {
    $check = New-Object Windows.Forms.CheckBox
    $check.Text = $row[1]; $check.SetBounds(18, $row[2], 750, 26)
    $checks[$row[0]] = $check; $form.Controls.Add($check)
}
$simulate = New-Object Windows.Forms.CheckBox
$simulate.Text = 'Simulation (-WhatIf) : aucune modification'; $simulate.Checked = $true
$simulate.SetBounds(18, 392, 490, 28); $form.Controls.Add($simulate)
$network = New-Object Windows.Forms.CheckBox
$network.Text = 'Test HTTPS Entra (audit)'; $network.SetBounds(510, 392, 270, 28); $form.Controls.Add($network)
$null = Add-Label 'Identifiant de campagne (pour la tache a l''ouverture de session)' 18 433 550 25
$deployment = New-Object Windows.Forms.TextBox
$deployment.Text = 'Pilot-01'; $deployment.SetBounds(575, 430, 192, 28); $form.Controls.Add($deployment)
$preview = New-Object Windows.Forms.TextBox
$preview.Multiline = $true; $preview.ReadOnly = $true; $preview.ScrollBars = 'Vertical'
$preview.SetBounds(18, 471, 750, 75); $form.Controls.Add($preview)
$null = Add-Label 'Les sorties et erreurs s''ouvrent dans une console PowerShell. Relire le rapport avant tout deploiement. Le script n''installe aucune mise a jour Windows, Office ou FSLogix.' 18 555 750 48
$launch = New-Object Windows.Forms.Button
$launch.Text = 'Executer le choix'; $launch.SetBounds(555, 615, 213, 36); $form.Controls.Add($launch)
$guide = New-Object Windows.Forms.Button
$guide.Text = 'Lire le guide'; $guide.SetBounds(18, 615, 170, 36); $form.Controls.Add($guide)

function Get-LaunchArguments {
    $choice = $script:choices[$actionBox.SelectedIndex]
    $argsList = @('-NoProfile','-NoExit','-File',('"' + $script:repair + '"'),'-Mode',$choice.Mode)
    if ($choice.Mode -in @('Audit','RepairUser','InstallLogonTask','ConfigureHost')) {
        $argsList += @('-Environment', @('Auto','RDS','RDSFSLogix')[$environmentBox.SelectedIndex])
    }
    if ($choice.Mode -in @('RepairUser','InstallLogonTask')) {
        foreach ($name in @('ReregisterBroker','ResetOfficeIdentity','ResetTokenBrokerAccounts','ResetOfficeLicensing')) {
            if ($checks[$name].Checked) { $argsList += "-$name" }
        }
    }
    if ($choice.Mode -eq 'InstallLogonTask') {
        if ($deployment.Text -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$') { throw 'Identifiant de campagne : 1 a 64 lettres, chiffres, tirets ou underscores.' }
        $argsList += @('-DeploymentId',$deployment.Text)
    }
    if ($choice.Mode -eq 'ConfigureHost') { $argsList += '-EnableSharedComputerActivation' }
    if ($choice.Mode -eq 'Audit' -and $network.Checked) { $argsList += '-TestNetwork' }
    if ($simulate.Checked) { $argsList += '-WhatIf' }
    return $argsList
}
function Update-Preview {
    $choice = $script:choices[$actionBox.SelectedIndex]
    $detail.Text = $choice.Detail
    foreach ($check in $checks.Values) { $check.Enabled = $choice.Mode -in @('RepairUser','InstallLogonTask') }
    $network.Enabled = $choice.Mode -eq 'Audit'
    $deployment.Enabled = $choice.Mode -eq 'InstallLogonTask'
    try { $preview.Text = 'powershell.exe ' + ((Get-LaunchArguments) -join ' ') }
    catch { $preview.Text = $_.Exception.Message }
}
$actionBox.Add_SelectedIndexChanged({ Update-Preview })
$environmentBox.Add_SelectedIndexChanged({ Update-Preview })
$deployment.Add_TextChanged({ Update-Preview })
$simulate.Add_CheckedChanged({ Update-Preview })
$network.Add_CheckedChanged({ Update-Preview })
foreach ($check in $checks.Values) { $check.Add_CheckedChanged({ Update-Preview }) }
$guide.Add_Click({
    try { Start-Process -FilePath (Join-Path $PSScriptRoot 'README.md') }
    catch { [Windows.Forms.MessageBox]::Show('Ouvrir README.md dans un editeur de texte.', 'Guide') | Out-Null }
})
$launch.Add_Click({
    try {
        $choice = $script:choices[$actionBox.SelectedIndex]
        $arguments = @(Get-LaunchArguments)
        if ($choice.Mode -eq 'Restore') {
            $dialog = New-Object Windows.Forms.OpenFileDialog
            $dialog.Filter = 'Manifeste de sauvegarde (manifest.json)|manifest.json'
            if ($dialog.ShowDialog() -ne 'OK') { return }
            $arguments += @('-ManifestPath',('"' + $dialog.FileName + '"'))
            $dialog.Dispose()
        }
        if (-not $simulate.Checked -and $choice.Mode -ne 'Audit') {
            $message = "Appliquer cette action ?`r`n`r`n" + $choice.Detail + "`r`n`r`nUne reconnexion/MFA peut etre necessaire. Les autres sessions ne seront pas fermees."
            if ([Windows.Forms.MessageBox]::Show($message, 'Confirmer l''action choisie', 'YesNo', 'Warning') -ne 'Yes') { return }
        }
        $exe = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if ($choice.Admin) { Start-Process -FilePath $exe -ArgumentList ($arguments -join ' ') -Verb RunAs }
        else { Start-Process -FilePath $exe -ArgumentList ($arguments -join ' ') }
    } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message, '58TM1 - erreur', 'OK', 'Error') | Out-Null }
})
Update-Preview
$null = $form.ShowDialog()
$form.Dispose()
