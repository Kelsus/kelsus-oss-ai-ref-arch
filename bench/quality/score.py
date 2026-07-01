#!/usr/bin/env python3
"""Quality scorer — extraction F1 + judge-scored RAG, with confidence intervals.

Talks to the gateway (uses whatever model vLLM currently serves):
  - extraction: POST invoice PDFs to /extract, score fields vs data/gold/claims
  - RAG: POST each QA question to /rag/query, then an LLM-as-judge compares the
         answer to the gold answer (replaces the saturated keyword proxy)

Concurrent (the gateway/vLLM batch fine). Every score carries a Wilson 95% CI.
Prints result JSON between ===QUALITY=== / ===END=== markers.

Env: GATEWAY (default http://127.0.0.1:8088), JUDGE_URL (default http://127.0.0.1:8000/v1),
     N (invoices; 0/unset = all), QN (RAG questions; 0/unset = all), WORKERS (default 16)
"""
import json
import os
import re
import sys
from concurrent.futures import ThreadPoolExecutor

import requests

sys.path.insert(0, os.path.dirname(__file__))                       # judge.py
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))   # stats.py
from judge import judge          # noqa: E402
from stats import wilson_ci      # noqa: E402

GW = os.environ.get("GATEWAY", "http://127.0.0.1:8088")
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
GOLD = os.path.join(ROOT, "data/gold/claims")
GOLD_RAG = os.path.join(os.path.dirname(__file__), "rag_gold.json")
N = int(os.environ.get("N", "0"))
QN = int(os.environ.get("QN", "0"))
WORKERS = int(os.environ.get("WORKERS", "16"))
EXTRACT_TIMEOUT = int(os.environ.get("EXTRACT_TIMEOUT", "300"))  # raise for reasoning models
RAG_TIMEOUT = int(os.environ.get("RAG_TIMEOUT", "180"))
RETRIES = int(os.environ.get("REQUEST_RETRIES", "4"))


def _post_json(url, *, timeout, **kw):
    """POST with retry+backoff. Treats empty body / 5xx as retryable — a busy
    single-replica gateway returns empty bodies under load (the n=4 DeepSeek
    failure, SE-14); without retry every transient empty was a dropped item."""
    import time
    last = None
    for attempt in range(RETRIES):
        try:
            r = requests.post(url, timeout=timeout, **kw)
            if r.status_code >= 500 or not r.text.strip():
                raise ValueError(f"transient: HTTP {r.status_code}, body[{len(r.text)}]")
            return r.json()
        except Exception as e:  # noqa: BLE001
            last = e
            time.sleep(min(2 ** attempt, 10))
    raise last
MIN_COMPLETE = float(os.environ.get("MIN_COMPLETE", "0.8"))  # below this fraction => run is INVALID

# attempted/completed + error tally per section, so a silent mass-drop can never
# masquerade as success again (the n=4 DeepSeek false-"OK"). GIL-safe appends.
STATS = {}
ERRORS = []
PERF = []   # per-request gateway _meta (token usage + latency) for managed_perf


def _err(tag, e):
    ERRORS.append(f"{tag}: {type(e).__name__}: {str(e)[:120]}")


def _perf(resp):
    """Stash the gateway's _meta (present only on managed providers). GIL-safe append."""
    if isinstance(resp, dict) and isinstance(resp.get("_meta"), dict):
        PERF.append(resp["_meta"])
FIELDS = ["patient_name", "payer_name", "provider_name", "provider_npi",
          "service_date", "total_billed", "balance_due", "num_line_items"]


def gold_view(g):
    return {"patient_name": g["patient"]["name"], "payer_name": g["payer"]["name"],
            "provider_name": g["provider"]["name"], "provider_npi": g["provider"]["npi"],
            "service_date": g["service_date"], "total_billed": g["totals"]["billed"],
            "balance_due": g["totals"]["balance"], "num_line_items": len(g["line_items"])}


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
    if field in ("provider_name", "patient_name"):
        # The invoice renders "Name · Specialty" (model often returns both), and
        # Synthea appends numeric suffixes to provider names ("Rhett676"). Neither
        # is an extraction error — compare on alpha-only name tokens.
        norm = lambda s: re.sub(r"[^a-z ]", " ", str(s).lower()).split()
        p, t = norm(pred), norm(truth)
        return bool(t) and all(tok in p for tok in t)
    return str(pred).strip().lower() == str(truth).strip().lower()


MANIFEST = os.path.join(os.path.dirname(__file__), "eval_manifest.jsonl")
TIER_ORDER = ["clean-digital", "scanned-clean", "scanned-degraded"]


def _extract_item(item):
    inp = os.path.join(ROOT, item["input"])
    cid = item["claim_id"]
    if not os.path.exists(inp):
        return None
    try:
        with open(inp, "rb") as fh:
            resp = _post_json(f"{GW}/extract", timeout=EXTRACT_TIMEOUT,
                              files={"file": (os.path.basename(inp), fh.read())})
        _perf(resp)
        pred = resp.get("fields", {})
    except Exception as e:  # noqa: BLE001
        print(f"  extract error {cid[-6:]}: {e}", file=sys.stderr)
        _err("extract", e)
        return None
    truth = gold_view(json.load(open(os.path.join(GOLD, f"{cid}.json"))))
    row = [match(f, pred.get(f), truth[f]) for f in FIELDS]
    # Diagnostic: keep what the model ACTUALLY returned for every MISSED field
    # (pred vs gold), so a low per-field score is auditable instead of a black box
    # — e.g. is provider_npi wrong because the model prefixed "NPI:", reformatted
    # the digits, or hallucinated? The eval data is fully synthetic (no real PII).
    misses = [{"claim_id": cid, "tier": item["tier"], "field": f,
               "pred": pred.get(f), "gold": truth[f]}
              for f, ok in zip(FIELDS, row) if not ok]
    return (item["tier"], row, misses)


def _agg(rows):
    nf = len(rows) * len(FIELDS)
    hits = sum(sum(r) for r in rows)
    lo, hi = wilson_ci(hits, nf)
    per_field = {f: round(sum(r[i] for r in rows) / len(rows) * 100, 1)
                 for i, f in enumerate(FIELDS)} if rows else {}
    return {"f1_pct": round(hits / nf * 100, 1) if nf else 0.0,
            "ci_pct": [round(lo * 100, 1), round(hi * 100, 1)],
            "n_invoices": len(rows), "per_field": per_field}


def score_extraction():
    if os.path.exists(MANIFEST):
        items = [json.loads(l) for l in open(MANIFEST) if l.strip()]
    else:  # fallback: clean PDFs only (legacy, no tiers)
        items = [{"claim_id": f[:-5], "tier": "clean-digital",
                  "input": f"data/synthea/output/forms/{f[:-5]}.pdf"}
                 for f in sorted(os.listdir(GOLD)) if f.endswith(".json")]
    tiers_allow = [t for t in os.environ.get("TIERS", "").split(",") if t]
    if tiers_allow:  # e.g. TIERS=clean-digital for text-only models
        items = [i for i in items if i["tier"] in tiers_allow]
    if N:
        items = items[:N]
    with ThreadPoolExecutor(WORKERS) as ex:
        res = [r for r in ex.map(_extract_item, items) if r is not None]
    STATS["extraction"] = {"attempted": len(items), "completed": len(res)}
    by_tier = {}
    mismatches = []
    for tier, row, miss in res:
        by_tier.setdefault(tier, []).append(row)
        mismatches.extend(miss)
    tiers = {t: _agg(by_tier[t]) for t in by_tier}
    headline = next((t for t in reversed(TIER_ORDER) if t in tiers), None)
    return {"tiers": tiers, "headline_tier": headline,
            "headline_f1_pct": tiers[headline]["f1_pct"] if headline else None,
            "mismatches": mismatches}


# --- commercial invoices (FATURA, real layouts) -----------------------------
COMMERCIAL_MANIFEST = os.path.join(os.path.dirname(__file__), "eval_manifest_commercial.jsonl")
COMMERCIAL_GOLD = os.path.join(ROOT, "data/fatura/gold")
COMMERCIAL_FIELDS = ["invoice_number", "invoice_date", "due_date", "total", "buyer_name"]


def cmatch(field, pred, truth):
    if pred is None or truth is None:
        return pred == truth                       # both null = correct
    if field == "total":
        gp = re.findall(r"\d[\d.]*", str(pred).replace(",", ""))
        gt = re.findall(r"\d[\d.]*", str(truth).replace(",", ""))
        try:
            return bool(gp and gt) and abs(float(gp[-1]) - float(gt[-1])) < 0.01
        except ValueError:
            return False
    if field == "buyer_name":
        norm = lambda s: re.sub(r"[^a-z ]", " ", str(s).lower()).split()
        p, t = norm(pred), norm(truth)
        return bool(t) and all(tok in p for tok in t)
    np_ = re.sub(r"[^a-z0-9]", "", str(pred).lower())     # number / dates: normalized contains
    nt = re.sub(r"[^a-z0-9]", "", str(truth).lower())
    return bool(nt) and (nt in np_ or np_ in nt)


def _commercial_item(item):
    inp = os.path.join(ROOT, item["input"])
    if not os.path.exists(inp):
        return None
    try:
        with open(inp, "rb") as fh:
            resp = _post_json(f"{GW}/extract", timeout=EXTRACT_TIMEOUT,
                              data={"domain": "commercial"},
                              files={"file": (os.path.basename(inp), fh.read())})
        _perf(resp)
        pred = resp.get("fields", {})
    except Exception as e:  # noqa: BLE001
        print(f"  commercial error {item['id']}: {e}", file=sys.stderr)
        _err("commercial", e)
        return None
    truth = json.load(open(os.path.join(COMMERCIAL_GOLD, f"{item['id']}.json")))
    return (item["tier"], [cmatch(f, pred.get(f), truth.get(f)) for f in COMMERCIAL_FIELDS])


COMMERCIAL_TIER_ORDER = ["scanned-clean", "scanned-degraded"]


def _cagg(rows):
    nf = len(rows) * len(COMMERCIAL_FIELDS)
    hits = sum(sum(r) for r in rows)
    lo, hi = wilson_ci(hits, nf)
    per_field = {f: round(sum(r[i] for r in rows) / len(rows) * 100, 1)
                 for i, f in enumerate(COMMERCIAL_FIELDS)} if rows else {}
    return {"f1_pct": round(hits / nf * 100, 1) if nf else 0.0,
            "ci_pct": [round(lo * 100, 1), round(hi * 100, 1)],
            "n_invoices": len(rows), "per_field": per_field}


def score_commercial():
    items = [json.loads(l) for l in open(COMMERCIAL_MANIFEST) if l.strip()]
    if N:
        items = items[:N]
    with ThreadPoolExecutor(WORKERS) as ex:
        res = [r for r in ex.map(_commercial_item, items) if r is not None]
    STATS["commercial"] = {"attempted": len(items), "completed": len(res)}
    by_tier = {}
    for tier, row in res:
        by_tier.setdefault(tier, []).append(row)
    tiers = {t: _cagg(by_tier[t]) for t in by_tier}
    headline = next((t for t in reversed(COMMERCIAL_TIER_ORDER) if t in tiers), None)
    return {"tiers": tiers, "headline_tier": headline,
            "headline_f1_pct": tiers[headline]["f1_pct"] if headline else None}


RAG_COLLECT = bool(os.environ.get("RAG_COLLECT"))


def _rag_one(item):
    q, gold = item.get("question") or item.get("q"), item.get("answer", "")
    try:
        resp = _post_json(f"{GW}/rag/query", timeout=RAG_TIMEOUT, json={"q": q})
        _perf(resp)
        ans = resp["answer"]
        if RAG_COLLECT:  # store now, judge later with one fixed judge (no confound)
            return {"question": q, "gold": gold, "answer": ans}
        return 1 if judge(q, gold, ans)["correct"] else 0
    except Exception as e:  # noqa: BLE001
        print(f"  rag error: {e}", file=sys.stderr)
        _err("rag", e)
        return None


def score_rag():
    data = json.load(open(GOLD_RAG))
    items = data if isinstance(data, list) else data.get("answerable", [])
    if QN:
        items = items[:QN]
    with ThreadPoolExecutor(WORKERS) as ex:
        v = [x for x in ex.map(_rag_one, items) if x is not None]
    STATS["rag"] = {"attempted": len(items), "completed": len(v)}
    if RAG_COLLECT:
        return {"collected": v, "n": len(v), "judged": False}
    n, correct = len(v), sum(v)
    lo, hi = wilson_ci(correct, n)
    return {"accuracy_pct": round(correct / n * 100, 1) if n else 0.0,
            "ci_pct": [round(lo * 100, 1), round(hi * 100, 1)], "n": n}


def _pct(xs, p):
    if not xs:
        return None
    xs = sorted(xs)
    return round(xs[min(len(xs) - 1, int(round(p / 100 * (len(xs) - 1))))], 1)


def _managed_perf():
    """Aggregate per-request token usage + latency for managed providers (bedrock/
    anthropic). Absent for local runs, so the open-model result schema is unchanged."""
    metas = [m for m in PERF if m.get("provider") in ("bedrock", "anthropic")]
    if not metas:
        return None
    lat = [m["latency_ms"] for m in metas if m.get("latency_ms") is not None]
    return {"provider": metas[0].get("provider"), "model": metas[0].get("model"),
            "n": len(metas),
            "in_tokens_sum": sum(m["in_tokens"] for m in metas if m.get("in_tokens")),
            "out_tokens_sum": sum(m["out_tokens"] for m in metas if m.get("out_tokens")),
            "latency_p50_ms": _pct(lat, 50), "latency_p95_ms": _pct(lat, 95)}


def main():
    out = {}
    if not os.environ.get("SKIP_EXTRACTION"):
        out["extraction"] = score_extraction()
    if os.path.exists(COMMERCIAL_MANIFEST) and not os.environ.get("SKIP_COMMERCIAL"):
        out["commercial"] = score_commercial()
    if not os.environ.get("SKIP_RAG"):
        out["rag"] = score_rag()

    # Completeness verdict — a section that mostly failed must NOT pass as success
    # (the n=4 DeepSeek false-"OK"). Record it in the result and flag the run.
    incomplete = []
    for sec, s in STATS.items():
        att, comp = s["attempted"], s["completed"]
        if att >= 10 and comp < MIN_COMPLETE * att:
            incomplete.append(f"{sec} {comp}/{att}")
    out["_stats"] = STATS
    out["_incomplete"] = incomplete
    mp = _managed_perf()
    if mp:
        out["managed_perf"] = mp

    if ERRORS:  # survives in stdout even if the Job pod is later TTL-deleted
        from collections import Counter
        print("===ERRORSUMMARY===", file=sys.stderr)
        for msg, c in Counter(ERRORS).most_common(8):
            print(f"  {c:>4}x {msg}", file=sys.stderr)

    print("===QUALITY===")
    print(json.dumps(out))
    print("===END===")

    if incomplete:
        print(f"INCOMPLETE RUN — sections below {MIN_COMPLETE:.0%}: {incomplete}", file=sys.stderr)
        sys.exit(3)  # driver/job treat non-zero as FAIL, not "quality done"


if __name__ == "__main__":
    main()
