using System;
using System.Collections.Generic;
using System.Text;
using System.Text.RegularExpressions;

namespace Repair58Desktop
{
    public sealed class OperationRequest
    {
        public string Mode { get; set; }
        public string Environment { get; set; }
        public string DeploymentId { get; set; }
        public string ManifestPath { get; set; }
        public bool HostRestore { get; set; }
        public bool Simulation { get; set; }
        public bool ReregisterBroker { get; set; }
        public bool ResetOfficeIdentity { get; set; }
        public bool ResetTokenBrokerAccounts { get; set; }
        public bool ResetOfficeLicensing { get; set; }
        public bool TestNetwork { get; set; }
        public string PipeName { get; set; }

        public bool RequiresAdmin
        {
            get { return Mode == "InstallLogonTask" || Mode == "RemoveLogonTask" || Mode == "ConfigureHost" || (Mode == "Restore" && HostRestore); }
        }

        public void Validate()
        {
            if (Array.IndexOf(new[] { "Audit", "RepairUser", "InstallLogonTask", "RemoveLogonTask", "ConfigureHost", "Restore" }, Mode) < 0)
                throw new ArgumentException("Action non reconnue.");
            if (Array.IndexOf(new[] { "Auto", "RDS", "RDSFSLogix" }, Environment) < 0)
                throw new ArgumentException("Environnement non reconnu.");
            if (!Regex.IsMatch(DeploymentId ?? "", @"\A[A-Za-z0-9][A-Za-z0-9_-]{0,63}\z"))
                throw new ArgumentException("Identifiant de campagne : 1 à 64 lettres, chiffres, tirets ou underscores.");
            if (HostRestore && Mode != "Restore") throw new ArgumentException("Contexte de restauration incompatible.");
            if ((ReregisterBroker || ResetOfficeIdentity || ResetTokenBrokerAccounts || ResetOfficeLicensing) && Mode != "RepairUser" && Mode != "InstallLogonTask")
                throw new ArgumentException("Options utilisateur incompatibles avec cette action.");
            if (TestNetwork && Mode != "Audit") throw new ArgumentException("Test réseau réservé au diagnostic.");
            if (Mode == "Restore" && String.IsNullOrWhiteSpace(ManifestPath)) throw new ArgumentException("Choisir un manifeste de sauvegarde.");
            if (!String.IsNullOrEmpty(ManifestPath) && (ManifestPath.IndexOfAny(new[] { '\r', '\n', '\0', '"' }) >= 0 || Mode != "Restore"))
                throw new ArgumentException("Chemin de manifeste invalide.");
            if (!String.IsNullOrEmpty(PipeName) && !Regex.IsMatch(PipeName, @"\A58tm1-[a-f0-9]{32}\z"))
                throw new ArgumentException("Canal de communication invalide.");
        }

        // Windows command-line quoting, without invoking cmd.exe or PowerShell -Command.
        public static string Quote(string value)
        {
            if (value == null) throw new ArgumentNullException("value");
            if (value.IndexOfAny(new[] { '\0', '\r', '\n' }) >= 0) throw new ArgumentException("Argument multiligne interdit.");
            var result = new StringBuilder("\"");
            int slashes = 0;
            foreach (char c in value)
            {
                if (c == '\\') { slashes++; continue; }
                if (c == '"') result.Append('\\', slashes * 2 + 1).Append(c);
                else result.Append('\\', slashes).Append(c);
                slashes = 0;
            }
            result.Append('\\', slashes * 2).Append('"');
            return result.ToString();
        }

        public string Arguments(string script)
        {
            Validate();
            var values = new List<string> { "-NoLogo", "-NoProfile", "-NonInteractive", "-File", script, "-Mode", Mode };
            if (Mode == "Audit" || Mode == "RepairUser" || Mode == "InstallLogonTask" || Mode == "ConfigureHost")
                values.AddRange(new[] { "-Environment", Environment });
            if (Mode == "InstallLogonTask") values.AddRange(new[] { "-DeploymentId", DeploymentId });
            if (Mode == "ConfigureHost") values.Add("-EnableSharedComputerActivation");
            if (Mode == "Restore") values.AddRange(new[] { "-ManifestPath", ManifestPath });
            if (ReregisterBroker) values.Add("-ReregisterBroker");
            if (ResetOfficeIdentity) values.Add("-ResetOfficeIdentity");
            if (ResetTokenBrokerAccounts) values.Add("-ResetTokenBrokerAccounts");
            if (ResetOfficeLicensing) values.Add("-ResetOfficeLicensing");
            if (TestNetwork) values.Add("-TestNetwork");
            if (Simulation) values.Add("-WhatIf");
            return String.Join(" ", values.ConvertAll(Quote).ToArray());
        }
    }
}
