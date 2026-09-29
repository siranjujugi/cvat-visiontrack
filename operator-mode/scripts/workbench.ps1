param(
    [Parameter(Position = 0)]
    [ValidateSet('init', 'install-deps', 'pull', 'start', 'open', 'import-comparison', 'export', 'status', 'logs', 'credentials', 'backup', 'diagnostics', 'trim-disk', 'stop', 'shutdown', 'help')]
    [string] $Command = 'help',
    [string] $InputDir,
    [switch] $InstallPrerequisites,
    [switch] $IncludeImages
)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'PowerShell 7 is required. Install it with: winget install --exact --id Microsoft.PowerShell'
}
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$operatorDir = Split-Path -Parent $scriptDir
$repoRoot = Split-Path -Parent $operatorDir
$composeFile = Join-Path $operatorDir 'compose.yml'
$labelsFile = Join-Path $operatorDir 'config/visiontrack-labels.json'
$manifestFile = Join-Path $operatorDir 'config/comparison-five-segments.json'
$workbenchHome = if ($env:VISIONTRACK_WORKBENCH_HOME) { $env:VISIONTRACK_WORKBENCH_HOME } else { Join-Path $env:LOCALAPPDATA 'VisionTrackWorkbench' }
$configDir = Join-Path $workbenchHome 'config'
$envFile = Join-Path $configDir 'workbench.env'
$pythonEnv = Join-Path $workbenchHome 'runtime/python'
$baseUrl = 'http://localhost:8787'

function Write-Info([string] $Message) { Write-Host "[VisionTrack Workbench] $Message" }
function Stop-WithError([string] $Message) { throw "[VisionTrack Workbench] $Message" }

function ConvertTo-ComposePath([string] $Path) {
    return ([System.IO.Path]::GetFullPath($Path)).Replace('\', '/')
}

function ConvertTo-EnvLiteral([string] $Value) {
    return "'" + $Value.Replace("'", "\'") + "'"
}

function New-RandomSecret {
    $bytes = [byte[]]::new(24)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return [Convert]::ToHexString($bytes).ToLowerInvariant()
}

function Set-PrivateFileAcl([string] $Path) {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    & icacls.exe $Path /inheritance:r /grant:r "${identity}:(F)" | Out-Null
    if ($LASTEXITCODE -ne 0) { Stop-WithError "Could not restrict permissions on $Path" }
}

function Initialize-Config {
    foreach ($directory in @(
        $configDir,
        (Join-Path $workbenchHome 'workspace/cvat-data'),
        (Join-Path $workbenchHome 'workspace/keys'),
        (Join-Path $workbenchHome 'workspace/postgres'),
        (Join-Path $workbenchHome 'workspace/redis'),
        (Join-Path $workbenchHome 'logs/cvat'),
        (Join-Path $workbenchHome 'exports'),
        (Join-Path $workbenchHome 'backups'),
        (Join-Path $workbenchHome 'runtime')
    )) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }

    if (Test-Path $envFile) { return }
    if (-not $InputDir) { $InputDir = Read-Host 'Full path to the folder containing source videos' }
    if (-not (Test-Path -LiteralPath $InputDir -PathType Container)) {
        Stop-WithError "Input directory does not exist: $InputDir"
    }
    if ($InputDir.Contains("'")) { Stop-WithError "Please choose an input folder path without apostrophes: $InputDir" }

    $homePath = ConvertTo-ComposePath $workbenchHome
    $inputPath = ConvertTo-ComposePath $InputDir
    $contents = @(
        'CVAT_VERSION=v2.76.0'
        "VTW_HOME=$(ConvertTo-EnvLiteral $homePath)"
        "VTW_INPUT_DIR=$(ConvertTo-EnvLiteral $inputPath)"
        'VTW_PORT=8787'
        "VTW_POSTGRES_PASSWORD=$(New-RandomSecret)"
        'VTW_ADMIN_USERNAME=operator'
        "VTW_ADMIN_PASSWORD=$(New-RandomSecret)"
        'VTW_MIN_FREE_GB=15'
    )
    Set-Content -LiteralPath $envFile -Value $contents -Encoding utf8NoBOM
    Set-PrivateFileAcl $envFile
    Write-Info "Created private local configuration at $envFile"
}

function Read-Config {
    if (-not (Test-Path $envFile)) { Initialize-Config }
    $settings = @{}
    foreach ($line in Get-Content -LiteralPath $envFile) {
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
            $value = $Matches[2]
            if ($value.Length -ge 2 -and $value.StartsWith("'") -and $value.EndsWith("'")) {
                $value = $value.Substring(1, $value.Length - 2).Replace("\'", "'")
            }
            $settings[$Matches[1]] = $value
        }
    }
    if (-not $settings.VTW_HOME -or -not $settings.VTW_INPUT_DIR -or -not $settings.VTW_ADMIN_PASSWORD) {
        Stop-WithError "Configuration is incomplete: $envFile. Preserve your workspace, then remove only this config file and run init again if it is a new installation."
    }
    if (-not (Test-Path -LiteralPath $settings.VTW_INPUT_DIR -PathType Container)) {
        Stop-WithError "Configured source-video folder is unavailable: $($settings.VTW_INPUT_DIR). Reconnect its drive or reinitialize configuration with the correct -InputDir."
    }
    $script:settings = $settings
    $script:baseUrl = "http://localhost:$($settings.VTW_PORT)"
}

function Invoke-Compose([string[]] $ComposeArgs) {
    & docker compose --env-file $envFile -f $composeFile --project-name visiontrack-workbench @ComposeArgs
    if ($LASTEXITCODE -ne 0) { Stop-WithError "Docker Compose failed (exit $LASTEXITCODE). Run 'logs' or 'diagnostics' for details." }
}

function Get-FreeSpaceGB {
    $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($workbenchHome))
    $drive = [System.IO.DriveInfo]::new($root)
    return [math]::Floor($drive.AvailableFreeSpace / 1GB)
}

function Test-Prerequisites {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Stop-WithError 'Docker Desktop is not installed. Install Docker Desktop for Windows with the WSL2 backend, then rerun this command.'
    }
    if (-not (Get-Command py -ErrorAction SilentlyContinue)) {
        Stop-WithError 'Python 3.12 is required for the Workbench utilities. Install it from python.org or winget install --exact --id Python.Python.3.12.'
    }
    & py -3.12 --version *> $null
    if ($LASTEXITCODE -ne 0) { Stop-WithError 'Python 3.12 is required. Install it with winget install --exact --id Python.Python.3.12.' }
    if (-not (Get-Command ffprobe -ErrorAction SilentlyContinue)) {
        Stop-WithError 'FFmpeg (ffprobe) is required for video inspection. Install it with `winget install --exact --id Gyan.FFmpeg.Shared`, then open a new terminal.'
    }
    & docker compose version *> $null
    if ($LASTEXITCODE -ne 0) { Stop-WithError 'Docker Compose v2 is not available. Update Docker Desktop.' }
    if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64') { Stop-WithError 'This initial Windows setup supports x64 Windows only; CVAT services are pinned to linux/amd64.' }
}

function Install-Prerequisites {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Stop-WithError 'winget is required for guided installation. Install App Installer from Microsoft Store, or install Docker Desktop, Python 3.12, and FFmpeg manually.'
    }
    $packages = @(
        @{ Command = 'docker'; Id = 'Docker.DockerDesktop' },
        @{ Command = 'py'; Id = 'Python.Python.3.12' },
        @{ Command = 'ffprobe'; Id = 'Gyan.FFmpeg.Shared' }
    )
    foreach ($package in $packages) {
        if (Get-Command $package.Command -ErrorAction SilentlyContinue) { continue }
        Write-Info "Installing $($package.Id) with winget. Docker Desktop may request administrator approval and a Windows restart."
        & winget install --exact --id $package.Id --accept-source-agreements --accept-package-agreements
        if ($LASTEXITCODE -ne 0) { Stop-WithError "winget could not install $($package.Id). Install it manually and rerun this setup." }
    }
    Write-Info 'Dependency installation finished. Restart Windows if Docker Desktop or WSL2 requested it, then rerun install_windows.ps1.'
}

function Start-DockerDesktop {
    & docker info *> $null
    if ($LASTEXITCODE -eq 0) { return }
    $desktop = Join-Path $env:ProgramFiles 'Docker/Docker/Docker Desktop.exe'
    if (Test-Path $desktop) {
        Write-Info 'Starting Docker Desktop; waiting for its Linux engine.'
        Start-Process -FilePath $desktop | Out-Null
    } else {
        Stop-WithError 'Docker Desktop was found but could not be started. Start it from the Start menu and retry.'
    }
    for ($attempt = 0; $attempt -lt 90; $attempt++) {
        Start-Sleep -Seconds 2
        & docker info *> $null
        if ($LASTEXITCODE -eq 0) { return }
    }
    Stop-WithError 'Docker Desktop did not become ready. Check that WSL2 is enabled and Docker Desktop is using Linux containers.'
}

function Check-Disk {
    $freeGB = Get-FreeSpaceGB
    $minimum = [int]$settings.VTW_MIN_FREE_GB
    if ($freeGB -lt $minimum) { Stop-WithError "Only $freeGB GB free on the workspace drive; at least $minimum GB is required before pulling images." }
}

function Ensure-PythonEnvironment {
    $python = Join-Path $pythonEnv 'Scripts/python.exe'
    if (-not (Test-Path $python)) {
        Write-Info 'Creating isolated Python 3.12 utility environment.'
        & py -3.12 -m venv $pythonEnv
        if ($LASTEXITCODE -ne 0) { Stop-WithError 'Failed to create the Python utility environment.' }
    }
    & $python -c 'import requests' *> $null
    if ($LASTEXITCODE -ne 0) {
        & $python -m pip install --disable-pip-version-check -r (Join-Path $operatorDir 'requirements.txt')
        if ($LASTEXITCODE -ne 0) { Stop-WithError 'Could not install Workbench utility dependencies.' }
    }
}

function Wait-ForApi {
    $healthUrl = "$baseUrl/api/server/health/"
    Write-Info "Waiting for CVAT health at $healthUrl"
    for ($attempt = 0; $attempt -lt 120; $attempt++) {
        try {
            $response = Invoke-WebRequest -Uri $healthUrl -TimeoutSec 4
            if ($response.StatusCode -eq 200) { return }
        } catch { Start-Sleep -Seconds 2 }
    }
    Invoke-Compose @('ps')
    & docker compose --env-file $envFile -f $composeFile --project-name visiontrack-workbench logs --tail=100 cvat_server
    Stop-WithError 'CVAT API did not become healthy. Review the service logs above.'
}

function Ensure-Admin {
    Write-Info 'Provisioning the local operator account.'
    $pythonCommand = 'import os; from django.contrib.auth import get_user_model; U=get_user_model(); u,_=U.objects.get_or_create(username=os.environ["VTW_ADMIN_USERNAME"], defaults={"email":"operator@localhost.invalid", "is_staff":True, "is_superuser":True}); u.is_staff=True; u.is_superuser=True; u.set_password(os.environ["VTW_ADMIN_PASSWORD"]); u.save()'
    & docker compose --env-file $envFile -f $composeFile --project-name visiontrack-workbench exec -T `
        -e "VTW_ADMIN_USERNAME=$($settings.VTW_ADMIN_USERNAME)" `
        -e "VTW_ADMIN_PASSWORD=$($settings.VTW_ADMIN_PASSWORD)" `
        cvat_server python manage.py shell -c $pythonCommand *> $null
    if ($LASTEXITCODE -ne 0) { Stop-WithError 'Could not provision the local operator account.' }
}

function Start-Workbench {
    Read-Config
    Test-Prerequisites
    Check-Disk
    Start-DockerDesktop
    Write-Info 'Starting local services.'
    Invoke-Compose @('up', '-d')
    Wait-ForApi
    Ensure-Admin
    Write-Info "Workbench is ready at $baseUrl"
}

function Open-Workbench {
    Read-Config
    Start-Process $baseUrl
}

function Import-Comparison {
    Read-Config
    Ensure-PythonEnvironment
    $python = Join-Path $pythonEnv 'Scripts/python.exe'
    & $python (Join-Path $scriptDir 'bootstrap_tasks.py') `
        --base-url $baseUrl `
        --username $settings.VTW_ADMIN_USERNAME `
        --password $settings.VTW_ADMIN_PASSWORD `
        --input-root $settings.VTW_INPUT_DIR `
        --manifest $manifestFile `
        --labels $labelsFile `
        --report (Join-Path $workbenchHome 'exports/comparison-import-report.json')
    if ($LASTEXITCODE -ne 0) { Stop-WithError 'Comparison import failed; see the report and service logs.' }
}

function Export-GroundTruth {
    Read-Config
    Ensure-PythonEnvironment
    $python = Join-Path $pythonEnv 'Scripts/python.exe'
    $arguments = @(
        (Join-Path $scriptDir 'export_ground_truth.py'),
        '--base-url', $baseUrl,
        '--username', $settings.VTW_ADMIN_USERNAME,
        '--password', $settings.VTW_ADMIN_PASSWORD,
        '--project-name', 'VisionTrack Comparison Ground Truth',
        '--output-dir', (Join-Path $workbenchHome 'exports')
    )
    if ($IncludeImages) { $arguments += '--include-images' }
    & $python @arguments
    if ($LASTEXITCODE -ne 0) { Stop-WithError 'Ground-truth export failed.' }
}

function Backup-Database {
    Read-Config
    Ensure-PythonEnvironment
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    $destination = Join-Path $workbenchHome "backups/cvat-database-$stamp.sql.gz"
    $composeArgs = @('compose', '--env-file', $envFile, '-f', $composeFile, '--project-name', 'visiontrack-workbench', 'exec', '-T', 'cvat_db', 'pg_dump', '-U', 'cvat', '-d', 'cvat')
    $code = @'
import gzip, subprocess, sys
command = sys.argv[1:-1]
with open(sys.argv[-1], "wb") as raw:
    with gzip.GzipFile(fileobj=raw, mode="wb") as compressed:
        process = subprocess.Popen(command, stdout=subprocess.PIPE)
        while chunk := process.stdout.read(1024 * 1024): compressed.write(chunk)
        if process.wait() != 0: raise SystemExit("pg_dump failed")
'@
    $python = Join-Path $pythonEnv 'Scripts/python.exe'
    $arguments = @('-c', $code) + @('docker') + $composeArgs + @($destination)
    & $python @arguments
    if ($LASTEXITCODE -ne 0) { Remove-Item -LiteralPath $destination -ErrorAction SilentlyContinue; Stop-WithError 'PostgreSQL backup failed.' }
    $hash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content -LiteralPath "$destination.sha256" -Value "$hash  $(Split-Path -Leaf $destination)" -Encoding ascii
    Write-Info "Database backup created: $destination"
}

function Write-Diagnostics {
    Read-Config
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    $destination = Join-Path $workbenchHome "logs/diagnostics-$stamp.txt"
    @(
        "generated_at=$stamp"
        "repository=$repoRoot"
        "free_disk_gb=$(Get-FreeSpaceGB)"
        (& docker version 2>&1 | Out-String)
        (& docker compose --env-file $envFile -f $composeFile --project-name visiontrack-workbench ps 2>&1 | Out-String)
        (& docker compose --env-file $envFile -f $composeFile --project-name visiontrack-workbench logs --tail=200 2>&1 | Out-String)
    ) | Set-Content -LiteralPath $destination -Encoding utf8
    Write-Info "Diagnostics written to $destination"
}

function Show-Help {
    @'
VisionTrack Workbench for Windows

Commands:
  init -InputDir <folder>  Create workspace and private configuration
  install-deps             Check prerequisites; add -InstallPrerequisites for winget setup
  pull                     Pull pinned CVAT images
  start                    Start services and wait for API health
  open                     Open the local Workbench in the default browser
  import-comparison        Create five comparison tasks idempotently
  export [-IncludeImages]  Export annotations
  status                   Show containers
  logs                     Follow all container logs
  credentials              Show local URL and operator credentials
  backup                   Write a compressed PostgreSQL backup and SHA-256
  diagnostics              Capture bounded logs and runtime information
  trim-disk                Explain Docker Desktop disk compaction guidance
  stop                     Stop containers; retain data
  shutdown                 Remove containers/network; retain bind-mounted data

Source videos are mounted read-only. Do not remove workspace/postgres or workspace/cvat-data
unless intentionally deleting all annotation data. Docker Desktop with its WSL2 backend is required.
'@ | Write-Host
}

try {
    switch ($Command) {
        'help' { Show-Help }
        'init' { Initialize-Config }
        'install-deps' {
            if ($InstallPrerequisites) { Install-Prerequisites }
            Test-Prerequisites
            Write-Info 'Required Windows dependencies are available.'
        }
        'pull' { Read-Config; Test-Prerequisites; Check-Disk; Start-DockerDesktop; Invoke-Compose @('pull') }
        'start' { Start-Workbench }
        'open' { Open-Workbench }
        'import-comparison' { Import-Comparison }
        'export' { Export-GroundTruth }
        'status' { Read-Config; Start-DockerDesktop; Invoke-Compose @('ps') }
        'logs' { Read-Config; Start-DockerDesktop; Invoke-Compose @('logs', '--follow', '--tail=100') }
        'credentials' { Read-Config; Write-Host "URL: $baseUrl`nUsername: $($settings.VTW_ADMIN_USERNAME)`nPassword: $($settings.VTW_ADMIN_PASSWORD)" }
        'backup' { Backup-Database }
        'diagnostics' { Write-Diagnostics }
        'trim-disk' { Write-Info 'Docker Desktop owns its WSL2 virtual disk. Use Docker Desktop > Settings > Resources > Advanced to inspect disk usage; do not compact or delete its VHDX while services are running.' }
        'stop' { Read-Config; Start-DockerDesktop; Invoke-Compose @('stop') }
        'shutdown' { Read-Config; Start-DockerDesktop; Invoke-Compose @('down') }
    }
} catch {
    Write-Error $_
    exit 1
}
