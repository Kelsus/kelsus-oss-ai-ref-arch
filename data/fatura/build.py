#!/usr/bin/env python3
"""Build a commercial-invoice extraction eval from FATURA (50 real layouts).

FATURA is a LayoutLM-style dataset (image + tokens + per-token ner_tags). We
group tokens by tag and reconstruct gold for the canonical AP fields by anchoring
on the LABEL KEYWORDS present in each group (robust to the raw tag ids, which the
dataset doesn't name): invoice_number, invoice_date, due_date, total.

The image is the extraction input (real, varied layouts → vision path). Writes
data/fatura/output/<id>.png + data/fatura/gold/<id>.json and
bench/quality/eval_manifest_commercial.jsonl. Deterministic + GPU-free.

  python3 build.py [N]   # default 120
"""
import json
import os
import re
import sys
from pathlib import Path

HERE = Path(__file__).parent
ROOT = HERE.parent.parent
IMG = HERE / "output"
GOLD = HERE / "gold"
MANIFEST = ROOT / "bench" / "quality" / "eval_manifest_commercial.jsonl"

sys.path.insert(0, str(HERE.parent / "synthea"))
from degrade import degrade  # noqa: E402  (same scan-wear pipeline as the medical invoices)

# FATURA is image-native (no digital text layer), so no clean-digital tier — but
# we apply the SAME degradation tiers as the medical invoices for parity.
TIERS = ["scanned-clean", "scanned-degraded"]

NUM = re.compile(r"\d[\d,]*\.\d{2}|\d[\d,]*")
DATE = re.compile(r"\d{1,2}[-/][A-Za-z0-9]{2,4}[-/]\d{2,4}|\d{4}-\d{2}-\d{2}")


# FATURA uses fixed, dataset-wide tag ids (confirmed by inspecting the stream).
# Anchoring on ids is far more robust than keyword matching (which matched
# "...the invoice no later than..." in the Terms block).
TAG = {"total": 1, "invoice_date": 3, "due_date": 4, "buyer": 5,
       "seller": 6, "invoice_number": 12}


def grouped(ex):
    g = {}
    for tok, tag in zip(ex["tokens"], ex["ner_tags"]):
        g.setdefault(tag, []).append(tok)
    return {t: " ".join(toks) for t, toks in g.items()}


def _date(s):
    m = DATE.search(s)
    return m.group(0) if m else None


def _after(text, keyword):
    """Token following `keyword` (e.g. 'number 2970-559' -> '2970-559')."""
    toks = text.split()
    low = [t.lower() for t in toks]
    if keyword in low and low.index(keyword) + 1 < len(toks):
        return toks[low.index(keyword) + 1]
    return toks[-1] if toks else None


# The buyer tag group is "<label> <name...>" where the label varies by template
# ("Buyer", "Bill To", "Sold To", "Customer", ...). The old code only stripped a
# literal "Buyer", so ~45% of invoices kept the label "Bill to" AS the name. Strip
# ANY leading label tokens, then take the first two tokens as the buyer name.
_BUYER_LABEL = {"buyer", "bill", "sold", "ship", "to", "customer", "client",
                "invoice", "name", "account", "attention", "attn", "payer"}


def _buyer_name(text):
    toks = text.split()
    while toks and re.sub(r"[^a-z]", "", toks[0].lower()) in _BUYER_LABEL:
        toks.pop(0)
    return " ".join(toks[:2]) or None


def gold_from(g):
    total = g.get(TAG["total"], "")
    nums = NUM.findall(total.replace(",", ""))
    return {
        "invoice_number": _after(g.get(TAG["invoice_number"], ""), "number"),
        "invoice_date": _date(g.get(TAG["invoice_date"], "")),
        "due_date": _date(g.get(TAG["due_date"], "")),
        "total": nums[-1] if nums else None,
        "seller": g.get(TAG["seller"], "").strip() or None,
        "buyer_name": _buyer_name(g.get(TAG["buyer"], "")),
    }


def main():
    from datasets import load_dataset
    # GOLD_ONLY: rewrite only the gold JSONs (e.g. to fix a gold bug) without touching
    # the locked eval images or manifest — keeps the eval input set byte-identical.
    gold_only = bool(os.environ.get("GOLD_ONLY"))
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 120
    IMG.mkdir(parents=True, exist_ok=True)
    GOLD.mkdir(parents=True, exist_ok=True)
    # Pinned to a fixed dataset revision so the eval set is reproducible (HF main can move).
    ds = load_dataset("mathieu1256/FATURA2-invoices", split="train", streaming=True,
                      revision="bcbb2fbb3c4701b87f5659ecbfbc55ad695aac21")
    rows = []
    for i, ex in enumerate(ds):
        if len(rows) >= n:
            break
        gold = gold_from(grouped(ex))
        if not gold["total"] or not gold["invoice_number"]:
            continue  # only keep invoices where we could anchor the key fields
        fid = f"fatura-{ex.get('id', i)}"
        tier = TIERS[len(rows) % len(TIERS)]
        if not gold_only:                        # skip image work when only fixing gold
            img = ex["image"].convert("RGB")
            if tier == "scanned-degraded":
                img = degrade(img, 2, seed=i)    # same wear as the medical degraded tier
            img.save(IMG / f"{fid}.png")
        json.dump(gold, open(GOLD / f"{fid}.json", "w"), indent=2)
        rows.append({"id": fid, "domain": "commercial", "tier": tier,
                     "input": str((IMG / f"{fid}.png").relative_to(ROOT))})
    if not gold_only:
        with open(MANIFEST, "w") as f:
            for r in rows:
                f.write(json.dumps(r) + "\n")
    print(f"{'rewrote gold for' if gold_only else 'wrote'} {len(rows)} commercial invoices"
          + ("" if gold_only else f" -> {MANIFEST.relative_to(ROOT)}"))
    if rows:
        print("sample gold:", json.load(open(GOLD / f"{rows[0]['id']}.json")))


if __name__ == "__main__":
    main()
