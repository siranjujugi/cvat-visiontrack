# VisionTrack Workbench: Local Operator Mode

Local Operator Mode turns the CVAT Community annotation engine into a workstation-oriented
VisionTrack review tool. It is isolated from VisionTrack Runtime and Studio and is intended for
operators, investigators, ML engineers, and data analysts creating certified ground truth.

The macOS implementation uses pinned CVAT `v2.76.0` images inside a dedicated Colima VM with
Rosetta on Apple Silicon. A Windows x64 setup is also provided using Docker Desktop's WSL2 Linux
engine. CVAT services use pinned `linux/amd64` images; native Windows ARM is not in the supported
matrix. Docker and Compose remain implementation details for operators.

## Included

- One-command macOS dependency setup and application installation.
- Windows PowerShell setup, dependency checks, local lifecycle commands, and click-to-start wrapper.
- Dedicated local CVAT runtime bound only to `127.0.0.1`.
- Visible workspace under `~/VisionTrackWorkbench`.
- Read-only source-video mounting with `copy_data=false` and `use_cache=true`.
- VisionTrack vehicle and license-plate labels and review attributes.
- Idempotent creation of the five pretrained-comparison review segments.
- Annotation export, PostgreSQL backup, bounded logs, diagnostics, and lifecycle commands.
- Exact source-video hashes and source frame ranges in the import report.

The annotation surface is the proven CVAT video workspace. A reduced, branded VisionTrack UI
plugin is a later product increment; it is not required for producing certified annotations.

## Data Layout

```text
~/VisionTrackWorkbench/
  config/workbench.env
  runtime/python/
  workspace/{cvat-data,keys,postgres,redis}/
  exports/
  backups/
  logs/
```

The four original video files remain in the configured input directory and are never copied into
the workspace. The comparison manifest creates five tasks because the first source contributes two
independent six-minute windows. Kvrocks contains rebuildable media cache metadata and uses a
Docker-managed volume; certified annotations remain in PostgreSQL and the exported task archives.

## Install On This Mac

From the repository root:

```bash
./operator-mode/scripts/install_macos.sh \
  --input-dir /Users/siranjeevi/Fork/visiontrack/data/eval/offline-080126
```

The installer creates `~/Applications/VisionTrack Workbench.app` and the optional CLI symlink
`~/.local/bin/visiontrack-workbench`.

At least 15 GB of free space is required before images are downloaded. For sustained annotation
work, maintain at least 30 GB free.

## First Start And Comparison Import

```bash
./operator-mode/scripts/workbench pull
./operator-mode/scripts/workbench start
./operator-mode/scripts/workbench import-comparison
./operator-mode/scripts/workbench open
./operator-mode/scripts/workbench credentials
```

You can subsequently open **VisionTrack Workbench** from `~/Applications`. Startup is idempotent.
The importer is also idempotent: completed tasks are retained and incomplete failed tasks are safely
recreated.

## Install On Windows

Supported initial target: Windows 10/11 x64 with WSL2 and Docker Desktop configured to use Linux
containers. PowerShell 7, Python 3.12, FFmpeg (`ffprobe`), Docker Desktop, and Docker Compose v2 are
required. Docker Desktop may require administrator approval and a restart. Docker Desktop licensing
terms apply to the customer's organization.

Open PowerShell 7 in the repository root. The guided installer checks prerequisites and creates a
private workspace under `%LOCALAPPDATA%\VisionTrackWorkbench`:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
./operator-mode/scripts/install_windows.ps1 `
  -InputDir 'D:\VisionTrack\Videos' `
  -InstallPrerequisites
```

`-InstallPrerequisites` opts in to installing Docker Desktop, Python 3.12, and FFmpeg through
`winget`. Docker Desktop may prompt for administrator approval. Restart Windows if Docker Desktop
or WSL2 requests it, then rerun the installer. To install dependencies yourself, omit the switch,
follow the reported commands, and rerun after Docker Desktop/WSL2 are ready. Keep source videos on a
local NTFS drive for reliable bind mounts; network shares and removable drives are not supported in
this initial Windows setup.

Pull the pinned images once, then start the Workbench:

```powershell
./operator-mode/scripts/workbench.ps1 pull
./operator-mode/scripts/workbench.ps1 start
./operator-mode/scripts/workbench.ps1 credentials
./operator-mode/scripts/workbench.ps1 import-comparison
./operator-mode/scripts/workbench.ps1 open
```

For subsequent starts, use `operator-mode/scripts/start_workbench.cmd` or run
`workbench.ps1 start` and `workbench.ps1 open`. Windows workspace data, exports, backups, and logs
are stored under `%LOCALAPPDATA%\VisionTrackWorkbench`; the source folder is mounted read-only.
`stop` and `shutdown` retain PostgreSQL data and annotations. Do not delete the `workspace` directory
unless you intend to remove the local annotation database and state.

## Annotation Contract

- Create tracks for vehicles and plates rather than independent boxes on every frame.
- Use `vehicle_instance_id` to assign a stable identifier such as `V000123`.
- Use the same value in a plate track's `associated_vehicle_id`.
- Set `plate_readability` to `exact`, `partial`, `unreadable`, `no_plate`, or `not_applicable`.
- Enter uppercase alphanumeric text without spaces in `plate_text`; partial text is allowed when
  readability is `partial`.
- Leave `review_status=pending` during annotation. Use `certified` only after verification, and
  `rejected` for invalid/noise annotations.
- Use CVAT keyframes and interpolation to follow an object. Add keyframes when geometry or
  visibility changes materially.

## Export And Backup

```bash
./operator-mode/scripts/workbench export
./operator-mode/scripts/workbench backup
```

The default export produces one CVAT-for-video archive per task plus a checksum manifest. Source
images are not embedded. Use `export --include-images` only when a self-contained, much larger
package is required.

## Operations

```bash
./operator-mode/scripts/workbench status
./operator-mode/scripts/workbench logs
./operator-mode/scripts/workbench logs cvat_worker_import
./operator-mode/scripts/workbench diagnostics
./operator-mode/scripts/workbench trim-disk
./operator-mode/scripts/workbench stop
./operator-mode/scripts/workbench shutdown
```

`stop` preserves the Colima VM for faster restart. `shutdown` also stops the dedicated VM. Neither
command deletes annotations or source videos.

## Security And Privacy

- Only `127.0.0.1:8787` is exposed.
- PostgreSQL, Redis, Kvrocks, OPA, and worker ports are not exposed to the host network.
- Credentials are generated once in a file with user-only permissions.
- The source directory is mounted read-only.
- Diagnostics contain service logs and health metadata but do not package source videos.
- Registration, cloud collaboration, analytics, and telemetry are not part of this local profile.

## Validate The Implementation

```bash
python3 -m unittest discover -s operator-mode/tests -v
VTW_HOME="$HOME/VisionTrackWorkbench" \
VTW_INPUT_DIR=/Users/siranjeevi/Fork/visiontrack/data/eval/offline-080126 \
VTW_POSTGRES_PASSWORD=test-only \
docker-compose -f operator-mode/compose.yml config --quiet
```

On Windows, validate the host-side setup with:

```powershell
./operator-mode/scripts/workbench.ps1 install-deps
./operator-mode/scripts/workbench.ps1 status
```

The Windows launcher needs a Windows host to validate Docker Desktop, NTFS bind mounts, and
container health end-to-end; macOS unit tests do not certify Windows runtime compatibility.
