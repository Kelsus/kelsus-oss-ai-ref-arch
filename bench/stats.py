#!/usr/bin/env python3
"""Confidence intervals for benchmark scores — so every published number carries
its uncertainty (the rigor the Index methodology demands).

Wilson 95% CI for a proportion (accuracy / F1 / pass-rate). Better than the
normal approximation at the extremes and for small n.
"""
import math


def wilson_ci(successes, n, z=1.96):
    """Return (low, high) 95% CI for successes/n, as fractions 0-1."""
    if n == 0:
        return (0.0, 1.0)
    p = successes / n
    denom = 1 + z * z / n
    center = (p + z * z / (2 * n)) / denom
    half = (z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n))) / denom
    return (max(0.0, center - half), min(1.0, center + half))


def fmt_pct_ci(successes, n):
    """'92.7% (±5.1, n=400)' — for tables/reports."""
    lo, hi = wilson_ci(successes, n)
    p = successes / n if n else 0
    half = (hi - lo) / 2 * 100
    return f"{p*100:.1f}% (±{half:.1f}, n={n})"


if __name__ == "__main__":
    for n in (12, 40, 100, 400, 1000):
        print(f"n={n:>4}  acc=0.90 -> {fmt_pct_ci(int(0.9*n), n)}")
