#!/usr/bin/env python3
"""Small CVAT REST client shared by Local Operator utilities."""

from __future__ import annotations

import hashlib
import json
import subprocess
import time
from dataclasses import dataclass
from fractions import Fraction
from pathlib import Path
from typing import Any, Iterator
from urllib.parse import urljoin

import requests


class WorkbenchError(RuntimeError):
    """Raised when a Workbench operation cannot complete safely."""


@dataclass(frozen=True)
class VideoInfo:
    fps: float
    frame_count: int
    duration_seconds: float


class CvatClient:
    def __init__(self, base_url: str, username: str, password: str, timeout: int = 60) -> None:
        self.base_url = base_url.rstrip("/") + "/"
        self.timeout = timeout
        self.session = requests.Session()
        response = self.session.post(
            self.url("api/auth/login"),
            json={"username": username, "password": password},
            timeout=timeout,
        )
        self._expect(response, {200})
        key = response.json().get("key")
        if not key:
            raise WorkbenchError("CVAT login response did not contain an API token")
        self.session.headers.update({"Authorization": f"Token {key}"})

    def url(self, path_or_url: str) -> str:
        if path_or_url.startswith(("http://", "https://")):
            return path_or_url
        return urljoin(self.base_url, path_or_url.lstrip("/"))

    @staticmethod
    def _expect(response: requests.Response, statuses: set[int]) -> requests.Response:
        if response.status_code not in statuses:
            detail = response.text[:2000]
            raise WorkbenchError(
                f"CVAT request failed: {response.request.method} {response.url} "
                f"returned {response.status_code}: {detail}"
            )
        return response

    def get(self, path: str, **kwargs: Any) -> requests.Response:
        response = self.session.get(self.url(path), timeout=self.timeout, **kwargs)
        return self._expect(response, {200})

    def post_json(self, path: str, payload: dict[str, Any]) -> requests.Response:
        response = self.session.post(self.url(path), json=payload, timeout=self.timeout)
        return self._expect(response, {200, 201, 202})

    def post_form(self, path: str, payload: dict[str, Any]) -> requests.Response:
        # CVAT's task data endpoint requires multipart/form-data even when every
        # resource is already mounted on the server and no binary file is sent.
        multipart_fields = {
            key: (None, str(value).lower() if isinstance(value, bool) else str(value))
            for key, value in payload.items()
        }
        response = self.session.post(
            self.url(path), files=multipart_fields, timeout=self.timeout
        )
        return self._expect(response, {200, 201, 202})

    def delete(self, path: str) -> None:
        response = self.session.delete(self.url(path), timeout=self.timeout)
        self._expect(response, {204})

    def paginated(self, path: str, params: dict[str, Any] | None = None) -> Iterator[dict[str, Any]]:
        next_url: str | None = self.url(path)
        query = {"page_size": 100, **(params or {})}
        while next_url:
            response = self.session.get(next_url, params=query, timeout=self.timeout)
            self._expect(response, {200})
            payload = response.json()
            yield from payload.get("results", [])
            next_url = payload.get("next")
            query = {}

    def wait_for_request(self, request_id: str, timeout_seconds: int = 1800) -> dict[str, Any]:
        deadline = time.monotonic() + timeout_seconds
        last_progress: int | None = None
        while time.monotonic() < deadline:
            request = self.get(f"api/requests/{request_id}").json()
            status = request.get("status")
            progress_value = request.get("progress")
            progress = int(float(progress_value or 0) * 100)
            if progress != last_progress:
                print(f"  request={request_id} status={status} progress={progress}%", flush=True)
                last_progress = progress
            if status == "finished":
                return request
            if status in {"failed", "canceled"}:
                raise WorkbenchError(
                    f"CVAT request {request_id} ended with status={status}: "
                    f"{request.get('message', '')}"
                )
            time.sleep(2)
        raise WorkbenchError(f"Timed out waiting for CVAT request {request_id}")


def probe_video(path: Path) -> VideoInfo:
    try:
        completed = subprocess.run(
            [
                "ffprobe",
                "-v",
                "error",
                "-select_streams",
                "v:0",
                "-show_entries",
                "stream=avg_frame_rate,r_frame_rate,nb_frames,duration:format=duration",
                "-of",
                "json",
                str(path),
            ],
            check=True,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError as exc:
        raise WorkbenchError("ffprobe is required; install FFmpeg before importing videos") from exc
    except subprocess.CalledProcessError as exc:
        raise WorkbenchError(f"ffprobe failed for {path}: {exc.stderr.strip()}") from exc

    payload = json.loads(completed.stdout)
    streams = payload.get("streams") or []
    if not streams:
        raise WorkbenchError(f"No video stream found in {path}")
    stream = streams[0]
    rate = stream.get("avg_frame_rate") or stream.get("r_frame_rate")
    try:
        fps = float(Fraction(rate))
    except (ValueError, ZeroDivisionError) as exc:
        raise WorkbenchError(f"Invalid frame rate {rate!r} in {path}") from exc
    if fps <= 0:
        raise WorkbenchError(f"Non-positive frame rate in {path}")

    duration = float(stream.get("duration") or payload.get("format", {}).get("duration") or 0)
    frame_count_text = stream.get("nb_frames")
    frame_count = int(frame_count_text) if frame_count_text not in {None, "N/A"} else round(duration * fps)
    if duration <= 0 or frame_count <= 0:
        raise WorkbenchError(f"Could not determine duration/frame count for {path}")
    return VideoInfo(fps=fps, frame_count=frame_count, duration_seconds=duration)


def compute_frame_range(
    info: VideoInfo, start_offset_seconds: float, end_offset_seconds: float
) -> tuple[int, int]:
    if start_offset_seconds < 0 or end_offset_seconds <= start_offset_seconds:
        raise WorkbenchError("Segment offsets must satisfy 0 <= start < end")
    if start_offset_seconds >= info.duration_seconds:
        raise WorkbenchError(
            f"Segment starts at {start_offset_seconds}s after video ends at {info.duration_seconds:.3f}s"
        )
    bounded_end = min(end_offset_seconds, info.duration_seconds)
    start_frame = max(0, int(start_offset_seconds * info.fps))
    stop_frame = min(info.frame_count - 1, max(start_frame, int(bounded_end * info.fps) - 1))
    return start_frame, stop_frame


def sha256_file(path: Path, block_size: int = 4 * 1024 * 1024) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while block := source.read(block_size):
            digest.update(block)
    return digest.hexdigest()


def read_json(path: Path) -> Any:
    with path.open(encoding="utf-8") as source:
        return json.load(source)


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    with temporary.open("w", encoding="utf-8") as target:
        json.dump(payload, target, indent=2, sort_keys=True)
        target.write("\n")
    temporary.replace(path)
