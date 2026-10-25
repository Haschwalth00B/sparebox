#!/usr/bin/env python3
"""Regression tests for the chaos route normalizer and analyzer."""

import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent
NORMALIZER = ROOT / "route-normalize.awk"
ANALYZER = ROOT / "analyze.sh"
CSV_HEADER = (
    "run,scenario,target,probe_src,probe_dst,trial,route_before,route_after,"
    "route_change,route_change_s,packet_loss_s,loss_lag_s,heal_route_change_s,"
    "ttl_before,ttl_after,samples,interval_s,note,fault_epoch,heal_epoch,"
    "route_before_raw,route_log,route_raw_log"
)


def normalize(route_output: str) -> str:
    result = subprocess.run(
        ["awk", "-f", str(NORMALIZER)],
        input=route_output,
        text=True,
        capture_output=True,
        check=True,
    )
    return result.stdout.strip()


class RouteNormalizerTests(unittest.TestCase):
    def test_accepts_primary_fabric_route(self):
        self.assertEqual(
            normalize("10.0.2.1 via 10.12.0.2 dev eth2 src 10.12.0.1"),
            "via 10.12.0.2 dev eth2",
        )

    def test_accepts_redundant_fabric_route(self):
        self.assertEqual(
            normalize("10.0.2.1 via 10.35.0.1 dev eth3 src 10.35.0.2"),
            "via 10.35.0.1 dev eth3",
        )

    def test_rejects_management_eth0_route(self):
        self.assertEqual(
            normalize("10.0.2.1 via 172.20.20.1 dev eth0 src 172.20.20.2"),
            "",
        )

    def test_rejects_unknown_interface(self):
        self.assertEqual(
            normalize("10.0.2.1 via 10.12.0.2 dev eth4"),
            "",
        )

    def test_rejects_route_without_gateway(self):
        self.assertEqual(normalize("10.0.2.1 dev eth2 src 10.12.0.1"), "")

    def test_analyzer_excludes_eth0_route_claims(self):
        invalid = [
            "20261025T000000Z", "link-down", "link12", "r1-2", "r2-1", "1",
            "via 10.12.0.2 dev eth2", "via 172.20.20.1 dev eth0", "1",
            "0.090000", "0.000000", "0.000000", "1.300000", "-", "-",
            "150", "0.02", "test", "1780000000.000000", "1780000001.000000",
            "10.0.2.1 via 10.12.0.2 dev eth2", "raw/invalid_route.txt",
            "raw/invalid_route-raw.txt",
        ]
        valid = invalid.copy()
        valid[5] = "2"
        valid[7] = "via 10.35.0.1 dev eth3"
        valid[9] = "0.200000"
        with tempfile.TemporaryDirectory() as tmp:
            csv_path = Path(tmp) / "sample.csv"
            csv_path.write_text(
                CSV_HEADER + "\n" + ",".join(invalid) + "\n" +
                ",".join(valid) + "\n",
                encoding="utf-8",
            )
            result = subprocess.run(
                ["bash", str(ANALYZER), str(csv_path)],
                text=True,
                capture_output=True,
                check=True,
            )
        self.assertIn("WARNING: ignoring 1 route-change row", result.stderr)
        self.assertIn("path changes: 1/2", result.stdout)
        self.assertIn("rejected route claims: 1", result.stdout)
        self.assertIn("route_change_s", result.stdout)
        self.assertRegex(result.stdout, r"route_change_s\s+1\s+0\.2\s+0\.200")


if __name__ == "__main__":
    unittest.main()
