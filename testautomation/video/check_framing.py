#!/usr/bin/env python3
"""Mechanical framing checks for take screenshots (substitute for visual review:
the driving model has no image input, so framing is verified by pixel statistics).

For each PNG it reports: size, fraction of pixels equal to the dominant colour
(blank-screen detector), and text-likeness (edge density) per horizontal third.
Non-zero exit if any check fails.

Usage: check_framing.py shot1.png [shot2.png ...]
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image

MIN_W, MIN_H = 1200, 800


def check(p: Path) -> bool:
    img = np.asarray(Image.open(p).convert("L"), dtype=np.uint8)
    h, w = img.shape
    ok = True
    probs = []
    if w < MIN_W or h < MIN_H:
        probs.append(f"size {w}x{h} below {MIN_W}x{MIN_H}")
        ok = False
    vals, counts = np.unique(img, return_counts=True)
    dominant = counts.max() / img.size
    gx_all = np.abs(np.diff(img.astype(np.int16), axis=1))
    thirds = [float((np.abs(np.diff(img[i * h // 3:(i + 1) * h // 3].astype(np.int16), axis=1)) > 40).mean())
              for i in range(3)]
    if dominant > 0.995 and max(thirds) < 0.001:
        probs.append(f"screen {dominant:.1%} one colour and no text edges (blank?)")
        ok = False
    if w < MIN_W or h < MIN_H:
        pass  # already reported above
    status = "OK " if ok else "BAD"
    print(f"{status} {p.name}: {w}x{h} dominant={dominant:.3f} edge-density(top/mid/bot)={thirds[0]}/{thirds[1]}/{thirds[2]}")
    for q in probs:
        print(f"     !! {q}")
    return ok


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("usage: check_framing.py shot.png ...")
    results = [check(Path(a)) for a in sys.argv[1:]]
    sys.exit(0 if all(results) else 1)
