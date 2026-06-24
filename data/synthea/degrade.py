#!/usr/bin/env python3
"""Turn a clean invoice PDF into a realistic 'scanned' image.

This is what makes the extraction benchmark representative instead of rigged:
a degraded image has NO text layer, so it forces the vision path (Qwen2.5-VL
reading pixels) under real-world wear — skew, low resolution, blur, sensor
noise, JPEG artifacts — rather than a pristine digital parse.

Levels: 0 = clean scan · 1 = moderate · 2 = heavy. Deterministic per seed.
CLI: python3 degrade.py <pdf> <level> <out.png> [seed]
"""
import io
import random
import sys

import fitz  # PyMuPDF
import numpy as np
from PIL import Image, ImageFilter


def rasterize(pdf_bytes, dpi=150, page=0):
    doc = fitz.open(stream=pdf_bytes, filetype="pdf")
    z = dpi / 72.0
    pix = doc[page].get_pixmap(matrix=fitz.Matrix(z, z))
    return Image.open(io.BytesIO(pix.tobytes("png"))).convert("RGB")


def _jpeg(img, q):
    b = io.BytesIO()
    img.save(b, "JPEG", quality=q)
    return Image.open(io.BytesIO(b.getvalue())).convert("RGB")


def degrade(img, level=1, seed=0):
    """Apply realistic scan degradation. level 0 = barely; 2 = rough."""
    if level <= 0:
        return _jpeg(img, 85)
    rng = random.Random(seed)
    # page skew / rotation
    img = img.rotate(rng.uniform(-2.0, 2.0) * level, expand=True,
                     fillcolor=(255, 255, 255), resample=Image.BICUBIC)
    # resolution loss: downscale then upscale
    f = {1: 0.75, 2: 0.55}.get(level, 0.7)
    w, h = img.size
    img = img.resize((max(1, int(w * f)), max(1, int(h * f)))).resize((w, h))
    # focus blur
    img = img.filter(ImageFilter.GaussianBlur(0.6 * level))
    # sensor noise
    arr = np.asarray(img).astype(np.int16)
    noise = np.random.RandomState(seed).normal(0, 6 * level, arr.shape)
    img = Image.fromarray(np.clip(arr + noise, 0, 255).astype(np.uint8))
    # compression artifacts
    return _jpeg(img, {1: 60, 2: 35}.get(level, 70))


if __name__ == "__main__":
    pdf = open(sys.argv[1], "rb").read()
    level = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    out = sys.argv[3] if len(sys.argv) > 3 else "degraded.png"
    seed = int(sys.argv[4]) if len(sys.argv) > 4 else 0
    degrade(rasterize(pdf), level, seed).save(out)
    print(f"wrote {out} (level={level})")
