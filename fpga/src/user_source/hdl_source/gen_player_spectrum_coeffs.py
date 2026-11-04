#!/usr/bin/env python3
"""Generate Q1.15 Hann and forward-FFT twiddle ROM files."""
from math import cos, pi, sin
from pathlib import Path

OUT = Path(__file__).resolve().parent

def q15(x: float) -> int:
    # Q1.15 positive unity is represented by 0x7fff.
    return max(-32768, min(32767, round(x * 32767)))

with (OUT / "spectrum_hann.mem").open("w", newline="\n") as f:
    for n in range(1024):
        w = 0.5 - 0.5 * cos(2.0 * pi * n / 1023.0)
        f.write(f"{q15(w) & 0xffff:04x}\n")

# Packed {cos(-2*pi*k/1024), sin(-2*pi*k/1024)}.
with (OUT / "spectrum_twiddle.mem").open("w", newline="\n") as f:
    for k in range(512):
        re = q15(cos(2.0 * pi * k / 1024.0))
        im = q15(-sin(2.0 * pi * k / 1024.0))
        f.write(f"{re & 0xffff:04x}{im & 0xffff:04x}\n")
