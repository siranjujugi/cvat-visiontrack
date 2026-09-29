from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path
from unittest.mock import Mock

OPERATOR_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OPERATOR_DIR / "scripts"))

from workbench_api import CvatClient, VideoInfo, WorkbenchError, compute_frame_range  # noqa: E402


class FrameRangeTests(unittest.TestCase):
    def test_computes_inclusive_frame_range(self) -> None:
        info = VideoInfo(fps=25.0, frame_count=25_000, duration_seconds=1_000.0)
        self.assertEqual(compute_frame_range(info, 10.0, 20.0), (250, 499))

    def test_clamps_segment_to_video_end(self) -> None:
        info = VideoInfo(fps=10.0, frame_count=100, duration_seconds=10.0)
        self.assertEqual(compute_frame_range(info, 8.0, 20.0), (80, 99))

    def test_rejects_invalid_offsets(self) -> None:
        info = VideoInfo(fps=25.0, frame_count=250, duration_seconds=10.0)
        with self.assertRaises(WorkbenchError):
            compute_frame_range(info, 5.0, 5.0)


class CvatClientTests(unittest.TestCase):
    def test_server_files_are_sent_as_multipart_form_fields(self) -> None:
        client = object.__new__(CvatClient)
        client.base_url = "http://localhost:8787/"
        client.timeout = 60
        client.session = Mock()
        client.session.post.return_value = Mock(status_code=202)

        client.post_form(
            "api/tasks/1/data",
            {"server_files[0]": "camera.mp4", "copy_data": False},
        )

        _, kwargs = client.session.post.call_args
        self.assertNotIn("data", kwargs)
        self.assertEqual(kwargs["files"]["server_files[0]"], (None, "camera.mp4"))
        self.assertEqual(kwargs["files"]["copy_data"], (None, "false"))


class ProductConfigurationTests(unittest.TestCase):
    def test_comparison_manifest_has_five_segments_and_four_sources(self) -> None:
        manifest = json.loads(
            (OPERATOR_DIR / "config" / "comparison-five-segments.json").read_text()
        )
        self.assertEqual(manifest["schema_version"], "visiontrack.workbench-import.v1")
        self.assertEqual(len(manifest["segments"]), 5)
        self.assertEqual(len({item["source_file"] for item in manifest["segments"]}), 4)
        self.assertEqual(len({item["id"] for item in manifest["segments"]}), 5)

    def test_labels_cover_vehicle_plate_and_certification(self) -> None:
        labels = json.loads((OPERATOR_DIR / "config" / "visiontrack-labels.json").read_text())
        by_name = {label["name"]: label for label in labels}
        self.assertEqual(set(by_name), {"vehicle", "license_plate"})
        for label in labels:
            attributes = {attribute["name"]: attribute for attribute in label["attributes"]}
            self.assertIn("review_status", attributes)
            self.assertEqual(
                attributes["review_status"]["values"], ["pending", "certified", "rejected"]
            )
        plate_attributes = {
            attribute["name"] for attribute in by_name["license_plate"]["attributes"]
        }
        self.assertTrue({"plate_text", "plate_readability", "associated_vehicle_id"} <= plate_attributes)


if __name__ == "__main__":
    unittest.main()
