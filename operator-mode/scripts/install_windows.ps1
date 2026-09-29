param(
    [string] $InputDir,
    [switch] $InstallPrerequisites
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$workbench = Join-Path $scriptDir 'workbench.ps1'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'PowerShell 7 is required. Install it with: winget install --exact --id Microsoft.PowerShell'
}

$dependencyArgs = @('install-deps')
if ($InstallPrerequisites) { $dependencyArgs += '-InstallPrerequisites' }
& $workbench @dependencyArgs
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$initArgs = @('init')
if ($InputDir) { $initArgs += @('-InputDir', $InputDir) }
& $workbench @initArgs
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host ''
Write-Host 'Installation checks and local workspace setup are complete.'
Write-Host 'Next: run workbench.ps1 pull, then workbench.ps1 start.'
