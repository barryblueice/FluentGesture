param([string]$Version = '0.3.1')
$ErrorActionPreference = 'Stop'
$workspace = (Resolve-Path -LiteralPath "$PSScriptRoot/..").Path
$releaseDir = Join-Path $workspace 'build/windows/x64/runner/Release'
$required = @('fluent_gesture.exe','flutter_windows.dll','msvcp140.dll','vcruntime140.dll','vcruntime140_1.dll','data/app.so','data/icudtl.dat','data/flutter_assets/NOTICES.Z')
foreach ($file in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $releaseDir $file) -PathType Leaf)) { throw "Missing release file: $file" }
}
Copy-Item -LiteralPath (Join-Path $workspace 'README.md') -Destination $releaseDir
Copy-Item -LiteralPath (Join-Path $workspace 'LICENSE') -Destination $releaseDir
# Remove documentation left by previous packaging runs.
$docsDir = Join-Path $releaseDir 'docs'
if (Test-Path -LiteralPath $docsDir) {
    $resolvedDocsDir = (Resolve-Path -LiteralPath $docsDir).Path
    if (-not $resolvedDocsDir.StartsWith($workspace + '\', [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Parent $resolvedDocsDir) -ne $releaseDir) {
        throw "Refusing to remove documentation outside the release directory: $resolvedDocsDir"
    }
    Remove-Item -LiteralPath $resolvedDocsDir -Recurse -Force
}
$releases = Join-Path $workspace 'build/releases'
New-Item -ItemType Directory -Path $releases -Force | Out-Null
$archive = Join-Path $releases "FluentGesture-$Version-windows-x64.zip"
Compress-Archive -LiteralPath $releaseDir -DestinationPath $archive -CompressionLevel Optimal -Force
$hash = Get-FileHash -LiteralPath $archive -Algorithm SHA256
"$($hash.Hash.ToLower())  $([IO.Path]::GetFileName($archive))" | Set-Content -LiteralPath "$archive.sha256" -Encoding ascii
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($archive)
try {
    foreach ($file in $required) {
        $entry = 'Release/' + $file
        if (-not ($zip.Entries | Where-Object { $_.FullName.Replace('\','/') -eq $entry })) { throw "Archive missing: $entry" }
    }
    Write-Output "Verified $($zip.Entries.Count) archive entries."
} finally { $zip.Dispose() }
Get-Item -LiteralPath $archive | Select-Object FullName, Length
Write-Output "SHA256: $($hash.Hash.ToLower())"
