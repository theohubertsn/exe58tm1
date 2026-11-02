#requires -Version 5.1
[CmdletBinding()]
param(
    # On Windows, uses the inbox .NET Framework compiler unless this directory is supplied.
    # On Linux, run with PowerShell 7 and the official net48 NuGet reference assemblies.
    [string]$ReferenceDirectory,
    [string]$OutputDirectory
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $root 'dist/desktop' }
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).ProviderPath
$output = Join-Path $OutputDirectory '58TM1.exe'
$files = @('Repair-58TM1.ps1','Start-58TM1.ps1','Start-58TM1.cmd','README.md','VERSION','docs/RECHERCHE.md','docs/VALIDATION.md','docs/TESTS.md','docs/DESKTOP.md')
$index = Join-Path $OutputDirectory 'payload.sha256'
$indexLines = foreach ($name in $files) {
    $path = Join-Path $root $name
    (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + $name
}
[IO.File]::WriteAllLines($index, [string[]]$indexLines, (New-Object Text.UTF8Encoding($false)))
$manifest = Join-Path $PSScriptRoot 'app.manifest'
$sources = @((Join-Path $PSScriptRoot 'OperationRequest.cs'), (Join-Path $PSScriptRoot 'Program.cs'))

if (-not $ReferenceDirectory -and [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
    $compiler = Join-Path $env:windir 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
    if (-not (Test-Path -LiteralPath $compiler)) { throw 'Compilateur .NET Framework introuvable. Installer les outils de developpement .NET Framework 4.8.' }
    $arguments = @('/nologo','/target:winexe','/platform:x64','/codepage:65001','/optimize+',('/out:' + $output),('/win32manifest:' + $manifest),
        '/reference:System.dll','/reference:System.Core.dll','/reference:System.Drawing.dll','/reference:System.Windows.Forms.dll','/reference:System.Web.Extensions.dll',
        ('/resource:' + $index + ',58tm1.payload.index'))
    foreach ($name in $files) { $arguments += '/resource:' + (Join-Path $root $name) + ',58tm1.payload.' + $name }
    $arguments += $sources
    & $compiler @arguments
    if ($LASTEXITCODE -ne 0) { throw 'La compilation Windows a echoue.' }
} else {
    if (-not $ReferenceDirectory -or -not (Test-Path (Join-Path $ReferenceDirectory 'mscorlib.dll'))) { throw 'Fournir -ReferenceDirectory vers les references officielles .NET Framework 4.8.' }
    $parseOptions = [Microsoft.CodeAnalysis.CSharp.CSharpParseOptions]::Default.WithLanguageVersion([Microsoft.CodeAnalysis.CSharp.LanguageVersion]::CSharp5)
    $trees = [Microsoft.CodeAnalysis.SyntaxTree[]]@($sources | ForEach-Object {
        [Microsoft.CodeAnalysis.CSharp.CSharpSyntaxTree]::ParseText([IO.File]::ReadAllText($_), $parseOptions, $_, [Text.Encoding]::UTF8)
    })
    $referenceNames = @('mscorlib.dll','System.dll','System.Core.dll','System.Drawing.dll','System.Windows.Forms.dll','System.Web.Extensions.dll')
    $references = [Microsoft.CodeAnalysis.MetadataReference[]]@($referenceNames | ForEach-Object {
        [Microsoft.CodeAnalysis.MetadataReference]::CreateFromFile((Join-Path $ReferenceDirectory $_))
    })
    $options = [Microsoft.CodeAnalysis.CSharp.CSharpCompilationOptions]::new([Microsoft.CodeAnalysis.OutputKind]::WindowsApplication).
        WithPlatform([Microsoft.CodeAnalysis.Platform]::X64).WithOptimizationLevel([Microsoft.CodeAnalysis.OptimizationLevel]::Release).
        WithDeterministic($true)
    $compilation = [Microsoft.CodeAnalysis.CSharp.CSharpCompilation]::Create('58TM1', $trees, $references, $options)
    $resources = New-Object 'System.Collections.Generic.List[Microsoft.CodeAnalysis.ResourceDescription]'
    foreach ($name in @('index') + $files) {
        $resourceFile = if ($name -eq 'index') { $index } else { Join-Path $root $name }
        $provider = [Func[IO.Stream]]{ [IO.File]::OpenRead($resourceFile) }.GetNewClosure()
        $resources.Add([Microsoft.CodeAnalysis.ResourceDescription]::new(('58tm1.payload.' + $name), $provider, $true))
    }
    $manifestStream = [IO.File]::OpenRead($manifest)
    $win32 = $compilation.CreateDefaultWin32Resources($true, $false, $manifestStream, $null)
    $stream = [IO.File]::Create($output)
    try {
        $result = $compilation.Emit($stream, $null, $null, $win32, $resources, $null, [Threading.CancellationToken]::None)
        $result.Diagnostics | Where-Object Severity -in @('Error','Warning') | ForEach-Object { Write-Host $_ }
        if (-not $result.Success) { throw 'La compilation Roslyn a echoue.' }
    } finally { $stream.Dispose(); $win32.Dispose(); $manifestStream.Dispose() }
}
$hash = (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText(($output + '.sha256'), ($hash + '  58TM1.exe' + [Environment]::NewLine))
Write-Host "EXE compile : $output"
Write-Host "SHA256 : $hash"
