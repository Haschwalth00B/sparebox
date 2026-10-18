"""Quality checks for sampled historical telemetry."""

def build_quality_report(
    series,
    start_epoch,
    end_epoch,
    max_gap_seconds=30,
):
    """Assess sample coverage without claiming continuous availability."""
    data_quality = {"warnings": [], "checks": {}}
    window_seconds = end_epoch - start_epoch

    for name, samples in series.items():
        timestamps = sorted({
            float(sample["sample_timestamp"])
            for sample in samples
        })
        gaps = [
            timestamps[i] - timestamps[i - 1]
            for i in range(1, len(timestamps))
        ]
        warnings = []

        leading_gap = timestamps[0] - start_epoch if timestamps else None
        trailing_gap = end_epoch - timestamps[-1] if timestamps else None
        max_internal_gap = max(gaps) if gaps else None

        if not samples:
            warnings.append("No samples found in the requested window.")
        elif len(timestamps) < 2:
            warnings.append(
                "Fewer than two distinct sample timestamps; trend is unverified."
            )

        if (
            max_internal_gap is not None
            and max_internal_gap > max_gap_seconds
        ):
            warnings.append(
                f"Internal sampling gap of {max_internal_gap:.1f}s exceeds "
                f"{max_gap_seconds}s."
            )

        if leading_gap is not None and leading_gap > max_gap_seconds:
            warnings.append(
                f"First sample is {leading_gap:.1f}s after the window starts; "
                "leading coverage is incomplete."
            )

        if trailing_gap is not None and trailing_gap > max_gap_seconds:
            warnings.append(
                f"Last sample is {trailing_gap:.1f}s before the window ends; "
                "trailing coverage is incomplete."
            )

        check = {
            "sample_count": len(samples),
            "distinct_sample_timestamps": len(timestamps),
            "max_observed_gap_seconds": max_internal_gap,
            "leading_uncovered_seconds": leading_gap,
            "trailing_uncovered_seconds": trailing_gap,
            "maximum_expected_gap_seconds": max_gap_seconds,
            "minimum_samples_for_trend": 2,
            "adequate_for_trend": len(timestamps) >= 2 and not warnings,
            "warnings": warnings,
        }
        data_quality["checks"][name] = check
        data_quality["warnings"].extend(
            f"{name}: {warning}" for warning in warnings
        )

    if window_seconds < 30:
        data_quality["warnings"].append(
            "Requested window is shorter than 30s; interpret trends cautiously."
        )

    return data_quality
