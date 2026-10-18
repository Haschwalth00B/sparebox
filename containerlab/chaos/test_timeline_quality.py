import unittest

from timeline_quality import build_quality_report


def samples(*timestamps):
    return [{"sample_timestamp": timestamp} for timestamp in timestamps]


class TimelineQualityTests(unittest.TestCase):
    def assess(self, data, start=100, end=160, max_gap=30):
        return build_quality_report(
            {"fabric": data},
            start,
            end,
            max_gap_seconds=max_gap,
        )

    def test_regular_samples_are_adequate(self):
        report = self.assess(samples(100, 115, 130, 145, 160))
        check = report["checks"]["fabric"]

        self.assertTrue(check["adequate_for_trend"])
        self.assertEqual(check["max_observed_gap_seconds"], 15)
        self.assertEqual(check["trailing_uncovered_seconds"], 0)
        self.assertEqual(report["warnings"], [])

    def test_no_samples_are_inadequate(self):
        report = self.assess([])
        check = report["checks"]["fabric"]

        self.assertFalse(check["adequate_for_trend"])
        self.assertEqual(check["sample_count"], 0)
        self.assertTrue(any("No samples" in w for w in check["warnings"]))

    def test_one_timestamp_is_inadequate(self):
        report = self.assess(samples(130))
        check = report["checks"]["fabric"]

        self.assertFalse(check["adequate_for_trend"])
        self.assertTrue(
            any("Fewer than two" in w for w in check["warnings"])
        )

    def test_internal_gap_over_threshold_is_inadequate(self):
        report = self.assess(samples(100, 115, 155, 160))
        check = report["checks"]["fabric"]

        self.assertFalse(check["adequate_for_trend"])
        self.assertEqual(check["max_observed_gap_seconds"], 40)
        self.assertTrue(any("Internal sampling gap" in w for w in check["warnings"]))

    def test_leading_gap_over_threshold_is_inadequate(self):
        report = self.assess(samples(135, 150, 160))
        check = report["checks"]["fabric"]

        self.assertFalse(check["adequate_for_trend"])
        self.assertEqual(check["leading_uncovered_seconds"], 35)
        self.assertTrue(any("leading coverage is incomplete" in w for w in check["warnings"]))

    def test_trailing_gap_over_threshold_is_inadequate(self):
        report = self.assess(samples(100, 115, 120))
        check = report["checks"]["fabric"]

        self.assertFalse(check["adequate_for_trend"])
        self.assertEqual(check["trailing_uncovered_seconds"], 40)
        self.assertTrue(any("trailing coverage is incomplete" in w for w in check["warnings"]))

    def test_exact_gap_threshold_is_allowed(self):
        report = self.assess(samples(100, 130, 160))
        self.assertTrue(report["checks"]["fabric"]["adequate_for_trend"])

    def test_each_peer_is_assessed_independently(self):
        report = build_quality_report(
            {
                "fabric": samples(100, 115, 130, 145, 160),
                "bgp_peer_a": samples(100, 115, 130, 145, 160),
                "bgp_peer_b": samples(100, 115, 155, 160),
            },
            100,
            160,
        )

        self.assertTrue(report["checks"]["fabric"]["adequate_for_trend"])
        self.assertFalse(
            report["checks"]["bgp_peer_b"]["adequate_for_trend"]
        )
        self.assertEqual(
            report["checks"]["bgp_peer_b"]["max_observed_gap_seconds"], 40
        )

    def test_expected_series_with_no_samples_is_reported(self):
        report = build_quality_report(
            {
                "fabric": samples(100, 115, 130, 145, 160),
                "bgp_peer_r2-1_10.12.0.1": [],
            },
            100,
            160,
        )

        check = report["checks"]["bgp_peer_r2-1_10.12.0.1"]
        self.assertFalse(check["adequate_for_trend"])
        self.assertEqual(check["sample_count"], 0)
        self.assertTrue(
            any("No samples" in warning for warning in check["warnings"])
        )

    def test_short_window_warns_without_changing_series_assessment(self):
        report = build_quality_report(
            {"fabric": samples(100, 110)},
            100,
            110,
        )

        self.assertTrue(report["checks"]["fabric"]["adequate_for_trend"])
        self.assertTrue(any("shorter than 30s" in w for w in report["warnings"]))


if __name__ == "__main__":
    unittest.main()
