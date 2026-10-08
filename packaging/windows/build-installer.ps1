# Builds dist\sotto-windows-x64-setup.exe from the Flutter Windows build
# with Inno Setup 6 (installed with Chocolatey if the machine lacks it).
#   pwsh packaging/windows/build-installer.ps1 -Version 0.1.7
param([Parameter(Mandatory)][string]$Version)
$ErrorActionPreference = 'Stop'

$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$source = Join-Path $root 'app\build\windows\x64\runner\Release'
$out = Join-Path $root 'dist'
New-Item -ItemType Directory -Force -Path $out | Out-Null

$iscc = Get-Command iscc.exe -ErrorAction SilentlyContinue
if (-not $iscc) {
  $candidate = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'
  if (-not (Test-Path $candidate)) {
    choco install innosetup --no-progress -y | Out-Host
  }
  $iscc = Get-Item $candidate
}

& $iscc.Source "/DAppVersion=$Version" "/DSourceDir=$source" "/DOutputDir=$out" `
  (Join-Path $PSScriptRoot 'sotto.iss')
if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed ($LASTEXITCODE)" }
Get-Item (Join-Path $out 'sotto-windows-x64-setup.exe')
