#!/usr/bin/env python3
"""Assemble a difficulty-TIERED extraction eval set — the representative test.

Takes the rendered invoice PDFs and produces, per claim, an input at an assigned
difficulty tier plus a manifest the scorer reads:

  clean-digital    : the PDF (text layer; the easy floor / sanity check)
  scanned-clean    : rasterized image, light degradation        (vision path)
  scanned-degraded : rasterized + heavy degradation              (vision path; HEADLINE tier)

(multi-template + FATURA layout diversity are layered in next.) Gold is unchanged;
the same claim is just presented at varying difficulty. GPU-free.

Writes  data/synthea/output/forms-scan/<claim>.png  and
        bench/quality/eval_manifest.jsonl  ({claim_id, tier, input} — repo-relative)
"""
import json
import sys
from collections import Counter
from pathlib import Path

from degrade import degrade, rasterize

HERE = Path(__file__).parent
ROOT = HERE.parent.parent
FORMS = HERE / "output" / "forms"
SCAN = HERE / "output" / "forms-scan"
GOLD = HERE.parent / "gold" / "claims"
MANIFEST = ROOT / "bench" / "quality" / "eval_manifest.jsonl"

TIERS = ["clean-digital", "scanned-clean", "scanned-degraded"]
LEVEL = {"scanned-clean": 0, "scanned-degraded": 2}


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    SCAN.mkdir(parents=True, exist_ok=True)
    ids = [p.stem for p in sorted(GOLD.glob("*.json")) if (FORMS / f"{p.stem}.pdf").exists()]
    if n:
        ids = ids[:n]
    rows = []
    for idx, cid in enumerate(ids):
        tier = TIERS[idx % len(TIERS)]
        pdf = FORMS / f"{cid}.pdf"
        if tier == "clean-digital":
            inp = pdf
        else:
            img = degrade(rasterize(pdf.read_bytes()), LEVEL[tier], seed=idx)
            inp = SCAN / f"{cid}.png"
            img.save(inp)
        rows.append({"claim_id": cid, "tier": tier,
                     "input": str(inp.relative_to(ROOT))})
    with open(MANIFEST, "w") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")
    print(f"wrote {len(rows)} eval items -> {MANIFEST.relative_to(ROOT)}")
    for t, c in sorted(Counter(r["tier"] for r in rows).items()):
        print(f"  {t}: {c}")


if __name__ == "__main__":
    main()
