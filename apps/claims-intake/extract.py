#!/usr/bin/env python3
"""Claims/Invoice Intake (App 1) — structured extraction, scored vs gold.

For each synthetic invoice PDF: read its text, ask vLLM to extract structured
fields as JSON (json-object mode), then score against the matching gold label
(data/gold/claims/<id>.json). Reports per-field accuracy across the batch —
the honest, per-field number the Benchmark Index methodology calls for.

  VLLM_URL  OpenAI-compatible LLM   (default http://127.0.0.1:8000/v1)
  FORMS     invoice PDFs            (default data/synthea/output/forms)
  GOLD      gold labels             (default data/gold/claims)

Usage:  python3 extract.py [N]      # score N invoices (default 20)

Note: our synthetic PDFs carry a text layer, so we read text directly. Scanned
real-world invoices need an OCR/vision stage ahead of this (production variant).
"""
import json
import os
import re
import sys
import urllib.request

from pypdf import PdfReader

VLLM_URL = os.environ.get("VLLM_URL", "http://127.0.0.1:8000/v1")
MODEL = os.environ.get("MODEL", "local")
FORMS = os.environ.get("FORMS", "data/synthea/output/forms")
GOLD = os.environ.get("GOLD", "data/gold/claims")

FIELDS = ["patient_name", "payer_name", "provider_name", "provider_npi",
          "service_date", "total_billed", "balance_due", "num_line_items"]

SYSTEM = (
    "You extract structured data from a medical claim/invoice. Return ONLY a "
    "JSON object with exactly these keys: patient_name, payer_name, "
    "provider_name, provider_npi, service_date (YYYY-MM-DD), total_billed "
    "(number), balance_due (number), num_line_items (integer). "
    "Use null for any field not present.")


def pdf_text(path):
    return "\n".join((p.extract_text() or "") for p in PdfReader(path).pages)


def extract(text):
    req = urllib.request.Request(
        f"{VLLM_URL}/chat/completions",
        data=json.dumps({
            "model": MODEL,
            "messages": [{"role": "system", "content": SYSTEM},
                         {"role": "user", "content": "INVOICE:\n" + text}],
            "temperature": 0, "max_tokens": 400,
            "response_format": {"type": "json_object"},
        }).encode(),
        headers={"content-type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as r:
        content = json.loads(r.read())["choices"][0]["message"]["content"]
    m = re.search(r"\{.*\}", content, re.S)
    return json.loads(m.group(0)) if m else {}


def gold_view(g):
    return {
        "patient_name": g["patient"]["name"],
        "payer_name": g["payer"]["name"],
        "provider_name": g["provider"]["name"],
        "provider_npi": g["provider"]["npi"],
        "service_date": g["service_date"],
        "total_billed": g["totals"]["billed"],
        "balance_due": g["totals"]["balance"],
        "num_line_items": len(g["line_items"]),
    }


def match(field, pred, truth):
    if pred is None:
        return False
    if field in ("total_billed", "balance_due"):
        try:
            return abs(float(pred) - float(truth)) < 0.01
        except (TypeError, ValueError):
            return False
    if field == "num_line_items":
        try:
            return int(pred) == int(truth)
        except (TypeError, ValueError):
            return False
    return str(pred).strip().lower() == str(truth).strip().lower()


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 20
    ids = [f[:-5] for f in os.listdir(GOLD) if f.endswith(".json")][:n]
    hits = {f: 0 for f in FIELDS}
    scored = 0
    for cid in ids:
        pdf = os.path.join(FORMS, f"{cid}.pdf")
        if not os.path.exists(pdf):
            continue
        try:
            pred = extract(pdf_text(pdf))
        except Exception as e:  # noqa: BLE001
            print(f"  {cid}: extract failed ({e})"); continue
        truth = gold_view(json.load(open(os.path.join(GOLD, f"{cid}.json"))))
        scored += 1
        ok = sum(match(f, pred.get(f), truth[f]) for f in FIELDS)
        for f in FIELDS:
            hits[f] += match(f, pred.get(f), truth[f])
        # (Synthea gives same-patient claims shared UUID prefixes, so label by
        # index + the distinguishing tail rather than the prefix.)
        print(f"  #{scored:02d} …{cid[-6:]}: {ok}/{len(FIELDS)} fields")
    print(f"\n=== Field accuracy over {scored} invoices ===")
    for f in FIELDS:
        print(f"  {f:16s} {hits[f]/scored*100:5.1f}%" if scored else f"  {f}: n/a")
    if scored:
        overall = sum(hits.values()) / (scored * len(FIELDS)) * 100
        print(f"  {'OVERALL':16s} {overall:5.1f}%")


if __name__ == "__main__":
    main()
