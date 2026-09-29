#!/usr/bin/env python3
"""Create an idempotent VisionTrack project and video review tasks in CVAT."""

from __future__ import annotations

import argparse
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from workbench_api import (
    CvatClient,
    WorkbenchError,
    compute_frame_range,
    probe_video,
    read_json,
    sha256_file,
    write_json,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default="http://localhost:8787")
    parser.add_argument("--username", required=True)
    parser.add_argument("--password", required=True)
    parser.add_argument("--input-root", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--labels", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    return parser.parse_args()


def exact_resource(resources: list[dict[str, Any]], name: str) -> dict[str, Any] | None:
    return next((resource for resource in resources if resource.get("name") == name), None)


def ensure_project(client: CvatClient, name: str, labels: list[dict[str, Any]]) -> dict[str, Any]:
    projects = list(client.paginated("api/projects", {"search": name}))
    project = exact_resource(projects, name)
    if project:
        existing_labels = list(client.paginated("api/labels", {"project_id": project["id"]}))
        existing_names = {label["name"] for label in existing_labels}
        required_names = {label["name"] for label in labels}
        missing = required_names - existing_names
        if missing:
            raise WorkbenchError(
                f"Existing project {name!r} is missing labels: {', '.join(sorted(missing))}"
            )
        return project
    return client.post_json("api/projects", {"name": name, "labels": labels}).json()


def ensure_task(
    client: CvatClient,
    project_id: int,
    task_name: str,
    source_file: str,
    start_frame: int,
    stop_frame: int,
) -> tuple[dict[str, Any], str]:
    tasks = list(client.paginated("api/tasks", {"project_id": project_id, "search": task_name}))
    existing = exact_resource(tasks, task_name)
    if existing and int(existing.get("size") or 0) > 0:
        return existing, "existing"
    if existing:
        print(f"Removing incomplete task {existing['id']} before retry", flush=True)
        client.delete(f"api/tasks/{existing['id']}")

    task = client.post_json(
        "api/tasks",
        {
            "name": task_name,
            "project_id": project_id,
            "segment_size": 0,
            "overlap": 0,
        },
    ).json()
    response = client.post_form(
        f"api/tasks/{task['id']}/data",
        {
            "server_files[0]": source_file,
            "image_quality": 90,
            "use_cache": "true",
            "copy_data": "false",
            "use_zip_chunks": "false",
            "start_frame": start_frame,
            "stop_frame": stop_frame,
        },
    ).json()
    request_id = response.get("rq_id")
    if not request_id:
        raise WorkbenchError(f"Task {task['id']} data request did not return rq_id")
    client.wait_for_request(request_id)
    return client.get(f"api/tasks/{task['id']}").json(), "created"


def main() -> int:
    args = parse_args()
    manifest = read_json(args.manifest)
    labels = read_json(args.labels)
    if manifest.get("schema_version") != "visiontrack.workbench-import.v1":
        raise WorkbenchError("Unsupported import manifest schema")
    segments = manifest.get("segments") or []
    if not segments:
        raise WorkbenchError("Import manifest contains no segments")

    input_root = args.input_root.expanduser().resolve()
    source_info: dict[str, dict[str, Any]] = {}
    for segment in segments:
        source_file = segment["source_file"]
        source_path = (input_root / source_file).resolve()
        if input_root not in source_path.parents:
            raise WorkbenchError(f"Source escapes input root: {source_file}")
        if not source_path.is_file():
            raise WorkbenchError(f"Missing source video: {source_path}")
        if source_file not in source_info:
            info = probe_video(source_path)
            print(f"Probed {source_file}: {info.fps:.3f} FPS, {info.duration_seconds:.1f}s", flush=True)
            source_info[source_file] = {
                "path": source_path,
                "video": info,
                "sha256": sha256_file(source_path),
            }

    client = CvatClient(args.base_url, args.username, args.password)
    project = ensure_project(client, manifest["project_name"], labels)
    report_segments = []
    for index, segment in enumerate(segments, start=1):
        details = source_info[segment["source_file"]]
        start_frame, stop_frame = compute_frame_range(
            details["video"],
            float(segment["start_offset_seconds"]),
            float(segment["end_offset_seconds"]),
        )
        print(
            f"[{index}/{len(segments)}] {segment['name']} frames={start_frame}-{stop_frame}",
            flush=True,
        )
        task, action = ensure_task(
            client,
            project["id"],
            segment["name"],
            segment["source_file"],
            start_frame,
            stop_frame,
        )
        report_segments.append(
            {
                **segment,
                "task_id": task["id"],
                "task_size": task.get("size"),
                "start_frame": start_frame,
                "stop_frame": stop_frame,
                "source_fps": details["video"].fps,
                "source_duration_seconds": details["video"].duration_seconds,
                "source_sha256": details["sha256"],
                "action": action,
            }
        )

    report = {
        "schema_version": "visiontrack.workbench-import-report.v1",
        "generated_at": datetime.now(UTC).isoformat(),
        "base_url": args.base_url,
        "project_id": project["id"],
        "project_name": project["name"],
        "segment_count": len(report_segments),
        "segments": report_segments,
    }
    write_json(args.report, report)
    print(f"Ready: project={project['id']} tasks={len(report_segments)} report={args.report}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except WorkbenchError as exc:
        raise SystemExit(f"error: {exc}") from exc
