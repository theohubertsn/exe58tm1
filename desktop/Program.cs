using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Pipes;
using System.Reflection;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

[assembly: AssemblyTitle("58TM1 Infrastructure Toolkit")]
[assembly: AssemblyDescription("Diagnostic et réparation Office / RDS / FSLogix")]
[assembly: AssemblyVersion("0.2.0.0")]
[assembly: AssemblyFileVersion("0.2.0.0")]
[assembly: System.Runtime.Versioning.TargetFramework(".NETFramework,Version=v4.8", FrameworkDisplayName = ".NET Framework 4.8")]

namespace Repair58Desktop
{
    internal static class Program
    {
        [STAThread]
        private static int Main(string[] args)
        {
            if (args.Length == 2 && args[0] == "--worker") return Worker(args[1]);
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            object release = Microsoft.Win32.Registry.GetValue(@"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full", "Release", null);
            if (release == null || Convert.ToInt32(release) < 528040) {
                MessageBox.Show(".NET Framework 4.8 est nécessaire. Installer le composant selon la procédure de maintenance de votre organisation.", "58TM1"); return 2;
            }
            if (args.Length != 0) { MessageBox.Show("Lancer l'application sans argument.", "58TM1"); return 2; }
            Application.Run(new MainForm());
            return 0;
        }

        internal static bool IsAdmin()
        {
            using (var identity = WindowsIdentity.GetCurrent())
                return new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
        }

        internal static string PowerShell
        {
            get { return Path.Combine(System.Environment.GetFolderPath(System.Environment.SpecialFolder.Windows), @"System32\WindowsPowerShell\v1.0\powershell.exe"); }
        }

        private static int Worker(string encoded)
        {
            StreamWriter writer = null;
            NamedPipeClientStream pipe = null;
            try
            {
                var json = Encoding.UTF8.GetString(Convert.FromBase64String(encoded));
                if (json.Length > 32768) throw new ArgumentException("Requête trop longue.");
                var request = new JavaScriptSerializer().Deserialize<OperationRequest>(json);
                request.Validate();
                if (String.IsNullOrEmpty(request.PipeName)) throw new ArgumentException("Canal absent.");
                pipe = new NamedPipeClientStream(".", request.PipeName, PipeDirection.Out, PipeOptions.None, TokenImpersonationLevel.Identification);
                pipe.Connect(30000);
                writer = new StreamWriter(pipe, new UTF8Encoding(false)) { AutoFlush = true };
                if (request.RequiresAdmin && !IsAdmin()) throw new InvalidOperationException("Élévation administrateur nécessaire.");
                if (request.HostRestore)
                {
                    string allowed = Path.GetFullPath(Path.Combine(System.Environment.GetFolderPath(System.Environment.SpecialFolder.CommonApplicationData), @"58tm1\Runs")) + Path.DirectorySeparatorChar;
                    if (!Path.GetFullPath(request.ManifestPath).StartsWith(allowed, StringComparison.OrdinalIgnoreCase))
                        throw new ArgumentException("Un manifeste Host doit rester dans ProgramData\\58tm1\\Runs.");
                    Payload.CheckNoReparse(request.ManifestPath);
                    var manifest = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(File.ReadAllText(request.ManifestPath));
                    if (!manifest.ContainsKey("Scope") || Convert.ToString(manifest["Scope"]) != "Host")
                        throw new ArgumentException("Le manifeste sélectionné n'est pas une sauvegarde Host.");
                }
                string folder = Payload.Extract(Program.IsAdmin());
                writer.WriteLine("Moteur intégré : " + folder);
                writer.WriteLine("Compte effectif : " + WindowsIdentity.GetCurrent().Name);
                writer.WriteLine("Action : " + request.Mode + " / " + (request.Simulation ? "SIMULATION" : "APPLICATION"));
                var info = new ProcessStartInfo(PowerShell, request.Arguments(Path.Combine(folder, "Repair-58TM1.ps1"))) {
                    UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true,
                    WorkingDirectory = folder
                };
                object sync = new object();
                using (var process = new Process { StartInfo = info })
                {
                    DataReceivedEventHandler output = delegate(object sender, DataReceivedEventArgs e) {
                        if (e.Data != null) lock (sync) { try { writer.WriteLine(e.Data); } catch (IOException) { } }
                    };
                    process.OutputDataReceived += output;
                    process.ErrorDataReceived += output;
                    process.Start();
                    process.BeginOutputReadLine(); process.BeginErrorReadLine();
                    process.WaitForExit();
                    writer.WriteLine("@@58TM1:EXIT:" + process.ExitCode);
                    return process.ExitCode;
                }
            }
            catch (Exception ex)
            {
                if (writer != null) { try { writer.WriteLine("ERREUR : " + ex.Message); writer.WriteLine("@@58TM1:EXIT:1"); } catch (IOException) { } }
                return 1;
            }
            finally { if (writer != null) writer.Dispose(); if (pipe != null) pipe.Dispose(); }
        }
    }

    internal static class Payload
    {
        internal static void CheckNoReparse(string path)
        {
            string current = Path.GetFullPath(path);
            while (!String.IsNullOrEmpty(current))
            {
                if ((Directory.Exists(current) || File.Exists(current)) && (File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                    throw new IOException("Lien ou jonction refusé : " + current);
                current = Path.GetDirectoryName(current);
            }
        }

        private static void ProtectDirectory(string path, bool userRead)
        {
            CheckNoReparse(path);
            Directory.CreateDirectory(path);
            var acl = new DirectorySecurity();
            acl.SetAccessRuleProtection(true, false);
            foreach (string sid in new[] { "S-1-5-18", "S-1-5-32-544" })
                acl.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(sid), FileSystemRights.FullControl,
                    InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
            if (userRead) acl.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier("S-1-5-32-545"), FileSystemRights.ReadAndExecute,
                InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
            acl.SetOwner(new SecurityIdentifier("S-1-5-32-544"));
            Directory.SetAccessControl(path, acl);
        }

        internal static string Extract(bool elevated)
        {
            string root;
            if (elevated)
            {
                string parent = Path.Combine(System.Environment.GetFolderPath(System.Environment.SpecialFolder.CommonApplicationData), "58tm1");
                ProtectDirectory(parent, true);
                root = Path.Combine(parent, "Desktop");
                ProtectDirectory(root, false);
            }
            else
            {
                root = Path.Combine(System.Environment.GetFolderPath(System.Environment.SpecialFolder.LocalApplicationData), @"58tm1\Desktop");
                CheckNoReparse(root);
                Directory.CreateDirectory(root);
            }
            // A fresh directory prevents reuse of a modified payload from a previous run.
            string folder = Path.Combine(root, "0.2.0-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(folder);
            var assembly = Assembly.GetExecutingAssembly();
            using (var indexStream = assembly.GetManifestResourceStream("58tm1.payload.index"))
            using (var index = new StreamReader(indexStream, Encoding.UTF8))
            {
                string line;
                while ((line = index.ReadLine()) != null)
                {
                    if (String.IsNullOrWhiteSpace(line)) continue;
                    int split = line.IndexOf("  ", StringComparison.Ordinal);
                    if (split != 64) throw new InvalidDataException("Index de ressources invalide.");
                    string hash = line.Substring(0, 64);
                    string name = line.Substring(66);
                    if (name.Contains("..") || name.Contains(":") || Path.IsPathRooted(name)) throw new InvalidDataException("Chemin de ressource invalide.");
                    string target = Path.Combine(folder, name.Replace('/', Path.DirectorySeparatorChar));
                    Directory.CreateDirectory(Path.GetDirectoryName(target));
                    using (var stream = assembly.GetManifestResourceStream("58tm1.payload." + name))
                    using (var file = new FileStream(target, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                    {
                        if (stream == null) throw new InvalidDataException("Ressource absente : " + name);
                        stream.CopyTo(file);
                    }
                    using (var sha = SHA256.Create())
                    using (var file = File.OpenRead(target))
                    {
                        string actual = BitConverter.ToString(sha.ComputeHash(file)).Replace("-", "").ToLowerInvariant();
                        if (actual != hash) throw new InvalidDataException("Intégrité de ressource invalide : " + name);
                    }
                }
            }
            return folder;
        }
    }

    internal sealed class MainForm : Form
    {
        private readonly ComboBox environment = new ComboBox();
        private readonly ComboBox action = new ComboBox();
        private readonly CheckBox simulate = new CheckBox();
        private readonly CheckBox network = new CheckBox();
        private readonly CheckBox[] flags = new CheckBox[4];
        private readonly TextBox deployment = new TextBox();
        private readonly TextBox command = new TextBox();
        private readonly RichTextBox output = new RichTextBox();
        private readonly Label scope = new Label();
        private readonly Label status = new Label();
        private readonly Button execute = new Button();
        private bool running;
        private string documentationFolder;
        private readonly string[] modes = { "Audit", "RepairUser", "InstallLogonTask", "ConfigureHost", "RemoveLogonTask", "Restore", "Restore" };
        private readonly string[] descriptions = {
            "LECTURE • Rapport local : versions, identité, WAM, Office et FSLogix.",
            "SESSION COURANTE • Fermer Office. Le moteur vérifie l'identité de la session avant de modifier le profil.",
            "ADMINISTRATEUR • Tâche utilisateur à la prochaine ouverture de session ; aucun traitement immédiat des sessions ouvertes.",
            "ADMINISTRATEUR • SharedComputerLicensing=1 pour une édition M365 compatible. Vérifier les droits de licence.",
            "ADMINISTRATEUR • Retire la tâche ; conserve les modifications et les sauvegardes existantes.",
            "SESSION COURANTE • Restaurer un manifeste utilisateur du même compte et du même hôte.",
            "ADMINISTRATEUR • Restaurer un manifeste Host conservé dans ProgramData\\58tm1\\Runs."
        };

        internal MainForm()
        {
            Text = "58TM1 Infrastructure Toolkit — 0.2.0";
            MinimumSize = new Size(900, 790); Size = new Size(1050, 900);
            StartPosition = FormStartPosition.CenterScreen;
            AutoScaleMode = AutoScaleMode.Dpi;
            AutoScaleDimensions = new SizeF(96, 96);
            Font = new Font("Segoe UI", 10); BackColor = Color.FromArgb(244, 247, 251);
            var header = new Panel { Dock = DockStyle.Top, Height = 90, BackColor = Color.FromArgb(20, 38, 63) };
            header.Controls.Add(new Label { Text = "58TM1  /  INFRASTRUCTURE TOOLKIT", ForeColor = Color.White, Font = new Font("Segoe UI", 20, FontStyle.Bold), AutoSize = true, Location = new Point(22, 12) });
            header.Controls.Add(new Label { Text = "Office • RDS • FSLogix    |    Opérations ciblées pour administrateurs et spécialistes infrastructure", ForeColor = Color.FromArgb(174, 204, 237), AutoSize = true, Location = new Point(25, 54) });
            var settings = new TableLayoutPanel { Dock = DockStyle.Top, Height = 474, ColumnCount = 2, Padding = new Padding(20, 12, 20, 5) };
            settings.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 170)); settings.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            environment.DropDownStyle = ComboBoxStyle.DropDownList; environment.Items.AddRange(new object[] { "Auto / session locale", "Serveur RDS", "Serveur RDS + FSLogix" }); environment.SelectedIndex = 0;
            action.DropDownStyle = ComboBoxStyle.DropDownList;
            action.Items.AddRange(new object[] { "Diagnostic", "Réparation de la session", "Déployer à l'ouverture de session", "Configurer l'activation partagée", "Retirer la tâche de déploiement", "Restaurer : utilisateur", "Restaurer : hôte" }); action.SelectedIndex = 0;
            AddRow(settings, "Environnement", environment, 34); AddRow(settings, "Action", action, 34);
            scope.AutoSize = false; scope.ForeColor = Color.FromArgb(35, 70, 115); AddRow(settings, "Périmètre", scope, 51);
            var options = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoScroll = true };
            string[] labels = { "Forcer le réenregistrement du Broker", "Réinitialiser les identités Office", "Réinitialiser TokenBroker Accounts", "Réinitialiser les licences utilisateur Office" };
            for (int i = 0; i < flags.Length; i++) { flags[i] = new CheckBox { Text = labels[i], AutoSize = true }; options.Controls.Add(flags[i]); flags[i].CheckedChanged += Changed; }
            AddRow(settings, "Options ciblées", options, 126);
            var execution = new FlowLayoutPanel();
            simulate.Text = "Simulation (-WhatIf)"; simulate.Checked = true; simulate.AutoSize = true;
            network.Text = "Test HTTPS Entra (audit)"; network.AutoSize = true;
            execution.Controls.Add(simulate); execution.Controls.Add(network); AddRow(settings, "Exécution", execution, 34);
            deployment.Text = "Pilot-01"; AddRow(settings, "Campagne", deployment, 32);
            command.ReadOnly = true; command.Multiline = true; command.Font = new Font("Consolas", 9); command.BackColor = Color.White;
            AddRow(settings, "Commande", command, 43);
            var bar = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 52, Padding = new Padding(20, 5, 0, 0) };
            execute.Text = "Exécuter"; execute.AutoSize = true; execute.Height = 32; execute.BackColor = Color.FromArgb(32, 99, 176); execute.ForeColor = Color.White; execute.FlatStyle = FlatStyle.Flat;
            execute.Click += Execute; bar.Controls.Add(execute);
            var save = new Button { Text = "Exporter la sortie…", AutoSize = true, Height = 32 }; save.Click += SaveOutput; bar.Controls.Add(save);
            var docs = new Button { Text = "Documentation", AutoSize = true, Height = 32 }; docs.Click += OpenDocs; bar.Controls.Add(docs);
            var reports = new Button { Text = "Rapports utilisateur", AutoSize = true, Height = 32 };
            reports.Click += delegate { try { string path = Path.Combine(System.Environment.GetFolderPath(System.Environment.SpecialFolder.LocalApplicationData), @"58tm1\Runs"); if (Directory.Exists(path)) Process.Start("explorer.exe", OperationRequest.Quote(path)); else Append("Aucun rapport utilisateur pour ce compte."); } catch (Exception ex) { Append(ex.Message); } }; bar.Controls.Add(reports);
            output.Dock = DockStyle.Fill; output.ReadOnly = true; output.BackColor = Color.FromArgb(18, 26, 39); output.ForeColor = Color.FromArgb(214, 230, 246); output.Font = new Font("Consolas", 10); output.BorderStyle = BorderStyle.None;
            status.Dock = DockStyle.Bottom; status.Height = 34; status.Padding = new Padding(15, 8, 0, 0); status.Text = "Prêt • Les sorties restent locales. Aucun envoi automatique.";
            Controls.Add(output); Controls.Add(bar); Controls.Add(settings); Controls.Add(header); Controls.Add(status);
            environment.SelectedIndexChanged += Changed; action.SelectedIndexChanged += Changed; deployment.TextChanged += Changed; simulate.CheckedChanged += Changed; network.CheckedChanged += Changed;
            FormClosing += delegate(object sender, FormClosingEventArgs e) { if (running) { e.Cancel = true; Append("Une opération est en cours. Attendre sa fin avant de fermer l'application."); } };
            UpdateControls();
            Append("58TM1 0.2.0 — EXE portable x64 / moteur PowerShell intégré.");
            Append("Profil professionnel : choisir le périmètre, les options et le mode d'exécution. Élévation UAC uniquement pour les actions administrateur.");
        }

        private static void AddRow(TableLayoutPanel panel, string label, Control control, int height)
        {
            int row = panel.RowCount++; panel.RowStyles.Add(new RowStyle(SizeType.Absolute, height));
            panel.Controls.Add(new Label { Text = label, Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleLeft }, 0, row);
            control.Dock = DockStyle.Fill; panel.Controls.Add(control, 1, row);
        }
        private void Changed(object sender, EventArgs e) { UpdateControls(); }
        private void UpdateControls()
        {
            bool user = action.SelectedIndex == 1 || action.SelectedIndex == 2;
            foreach (var flag in flags) flag.Enabled = user && !running;
            network.Enabled = action.SelectedIndex == 0 && !running; deployment.Enabled = action.SelectedIndex == 2 && !running;
            environment.Enabled = !running; action.Enabled = !running; simulate.Enabled = !running;
            scope.Text = descriptions[action.SelectedIndex];
            try { command.Text = "powershell.exe " + ReadRequest("<manifest.json>").Arguments("<moteur intégré>\\Repair-58TM1.ps1"); }
            catch (Exception ex) { command.Text = ex.Message; }
        }
        private OperationRequest ReadRequest(string manifest)
        {
            bool user = action.SelectedIndex == 1 || action.SelectedIndex == 2;
            return new OperationRequest { Mode = modes[action.SelectedIndex], Environment = new[] { "Auto", "RDS", "RDSFSLogix" }[environment.SelectedIndex],
                DeploymentId = action.SelectedIndex == 2 ? deployment.Text : "Pilot-01", ManifestPath = action.SelectedIndex >= 5 ? manifest : null, HostRestore = action.SelectedIndex == 6,
                Simulation = simulate.Checked, TestNetwork = action.SelectedIndex == 0 && network.Checked,
                ReregisterBroker = user && flags[0].Checked, ResetOfficeIdentity = user && flags[1].Checked,
                ResetTokenBrokerAccounts = user && flags[2].Checked, ResetOfficeLicensing = user && flags[3].Checked };
        }

        private void Execute(object sender, EventArgs e)
        {
            NamedPipeServerStream pipe = null;
            try
            {
                string manifest = null;
                if (action.SelectedIndex >= 5) using (var dialog = new OpenFileDialog { Filter = "Manifeste de sauvegarde|manifest.json", CheckFileExists = true }) {
                    if (dialog.ShowDialog(this) != DialogResult.OK) return; manifest = dialog.FileName;
                }
                var request = ReadRequest(manifest); request.PipeName = "58tm1-" + Guid.NewGuid().ToString("N"); request.Validate();
                var security = new PipeSecurity();
                security.SetAccessRuleProtection(true, false);
                security.AddAccessRule(new PipeAccessRule(WindowsIdentity.GetCurrent().User, PipeAccessRights.FullControl, AccessControlType.Allow));
                security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier("S-1-5-32-544"), PipeAccessRights.FullControl, AccessControlType.Allow));
                pipe = new NamedPipeServerStream(request.PipeName, PipeDirection.In, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous, 4096, 4096, security);
                string encoded = Convert.ToBase64String(Encoding.UTF8.GetBytes(new JavaScriptSerializer().Serialize(request)));
                var info = new ProcessStartInfo(Application.ExecutablePath, "--worker " + encoded) { UseShellExecute = true };
                if (request.RequiresAdmin && !Program.IsAdmin()) info.Verb = "runas";
                Process worker = Process.Start(info);
                running = true; execute.Enabled = false; UpdateControls();
                status.Text = "En cours • " + request.Mode + " • " + (request.Simulation ? "SIMULATION" : "APPLICATION");
                Append("\r\n[" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "] " + status.Text);
                var channel = pipe;
                var thread = new Thread(delegate() {
                    int code = 1;
                    try {
                        IAsyncResult pending = channel.BeginWaitForConnection(null, null);
                        if (!pending.AsyncWaitHandle.WaitOne(35000)) throw new TimeoutException("Le moteur n'a pas rejoint le canal de sortie. Aucune opération lancée par ce canal.");
                        channel.EndWaitForConnection(pending);
                        using (var reader = new StreamReader(channel, Encoding.UTF8)) {
                            string line;
                            while ((line = reader.ReadLine()) != null) {
                                if (line.StartsWith("@@58TM1:EXIT:", StringComparison.Ordinal)) code = Int32.Parse(line.Substring(13));
                                else Append(line);
                            }
                        }
                    } catch (Exception ex) { Append("ERREUR : " + ex.Message); }
                    finally {
                        channel.Dispose(); if (worker != null) worker.Dispose();
                        int result = code;
                        if (!IsDisposed) BeginInvoke(new Action(delegate {
                            running = false; execute.Enabled = true; UpdateControls();
                            status.Text = result == 0 ? "Terminé • Opérations locales terminées ; connexion Office à vérifier." : "Échec / opération partielle • Lire la sortie et les journaux.";
                            Append(status.Text);
                        }));
                    }
                });
                thread.IsBackground = true; thread.Start();
            }
            catch (Exception ex) { if (pipe != null) pipe.Dispose(); running = false; execute.Enabled = true; UpdateControls(); Append("Action non lancée : " + ex.Message); }
        }

        private void Append(string text)
        {
            if (IsDisposed) return;
            if (InvokeRequired) { BeginInvoke(new Action<string>(Append), text); return; }
            output.AppendText(text + System.Environment.NewLine); output.SelectionStart = output.TextLength; output.ScrollToCaret();
        }
        private void SaveOutput(object sender, EventArgs e)
        {
            using (var dialog = new SaveFileDialog { Filter = "Journal texte|*.log", FileName = "58TM1-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + ".log" })
                if (dialog.ShowDialog(this) == DialogResult.OK) try { File.WriteAllText(dialog.FileName, output.Text, new UTF8Encoding(true)); } catch (Exception ex) { Append(ex.Message); }
        }
        private void OpenDocs(object sender, EventArgs e)
        {
            try {
                if (documentationFolder == null) documentationFolder = Payload.Extract(false);
                Process.Start("notepad.exe", OperationRequest.Quote(Path.Combine(documentationFolder, "README.md")));
            } catch (Exception ex) { Append(ex.Message); }
        }
    }
}
