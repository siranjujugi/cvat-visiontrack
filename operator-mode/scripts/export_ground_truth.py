#!/usr/bin/env python3
"""Export all tasks in a VisionTrack project and write a verified package manifest."""

from __future__ import annotations

import argparse
import re
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from workbench_api import CvatClient, WorkbenchError, sha256_file, write_json


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default="http://localhost:8787")
    parser.add_argument("--username", required=True)
    parser.add_argument("--password", required=True)
    parser.add_argument("--project-name", required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--include-images", action="store_true")
    return parser.parse_args()


def safe_name(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-") or "task"


def exact_resource(resources: list[dict[str, Any]], name: str) -> dict[str, Any] | None:
    return next((resource for resource in resources if resource.get("name") == name), None)


def export_task(
    client: CvatClient, task: dict[str, Any], output_dir: Path, include_images: bool
) -> dict[str, Any]:
    response = client.session.post(
        client.url(f"api/tasks/{task['id']}/dataset/export"),
        params={
            "format": "CVAT for video 1.1",
            "save_images": str(include_images).lower(),
            "location": "local",
        },
        timeout=client.timeout,
    )
    client._expect(response, {202, 409})
    request_id = response.json().get("rq_id")
    if not request_id:
        raise WorkbenchError(f"Export for task {task['id']} did not return rq_id")
    request = client.wait_for_request(request_id)
    result_url = request.get("result_url")
    if not result_url:
        raise WorkbenchError(f"Export for task {task['id']} did not return a download URL")

    filename = f"task-{task['id']:04d}-{safe_name(task['name'])}-cvat-video-1.1.zip"
    destination = output_dir / filename
    with client.session.get(client.url(result_url), stream=True, timeout=300) as download:
        client._expect(download, {200})
        with destination.open("wb") as target:
            for chunk in download.iter_content(1024 * 1024):
                if chunk:
                    target.write(chunk)
    return {
        "task_id": task["id"],
        "task_name": task["name"],
        "task_size": task.get("size"),
        "archive": filename,
        "archive_size_bytes": destination.stat().st_size,
        "archive_sha256": sha256_file(destination),
    }


def main() -> int:
    args = parse_args()
    client = CvatClient(args.base_url, args.username, args.password)
    projects = list(client.paginated("api/projects", {"search": args.project_name}))
    project = exact_resource(projects, args.project_name)
    if not project:
        raise WorkbenchError(f"Project not found: {args.project_name}")
    tasks = list(client.paginated("api/tasks", {"project_id": project["id"]}))
    if not tasks:
        raise WorkbenchError(f"Project {args.project_name!r} has no tasks")

    timestamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
    package_dir = args.output_dir.expanduser().resolve() / f"ground-truth-{timestamp}"
    package_dir.mkdir(parents=True, exist_ok=False)
    exports = []
    for index, task in enumerate(sorted(tasks, key=lambda item: item["id"]), start=1):
        print(f"[{index}/{len(tasks)}] Exporting {task['name']}", flush=True)
        exports.append(export_task(client, task, package_dir, args.include_images))

    manifest = {
        "schema_version": "visiontrack.ground-truth-export.v1",
        "generated_at": datetime.now(UTC).isoformat(),
        "project_id": project["id"],
        "project_name": project["name"],
        "format": "CVAT for video 1.1",
        "includes_images": args.include_images,
        "task_count": len(exports),
        "exports": exports,
    }
    write_json(package_dir / "manifest.json", manifest)
    print(f"Export complete: {package_dir}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except WorkbenchError as exc:
        raise SystemExit(f"error: {exc}") from exc
