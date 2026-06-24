#!/usr/bin/env python3
"""Build the App 2 (sovereign RAG) corpus from PUBLIC regulated-finance text.

Sprint 2 source: the Federal Register API (public, JSON, no auth) — recent rules
and notices about consumer lending/credit. Each document's abstract + real
source URL becomes a corpus doc, so retrieved answers cite a verifiable link.
Sprint 3 expands this to full SEC EDGAR (EX-10 agreements, 10-Ks) + NIST.

Writes data/corpus/seed/docs.jsonl  ({title, source, date, text} per line).
"""
import json
import os
import urllib.parse
import urllib.request

OUT = os.path.join(os.path.dirname(__file__), "seed")
UA = "Kelsus Capabilities research@kelsus.com"
TERMS = [
    "consumer credit", "fair lending", "mortgage disclosure", "overdraft fees",
    "truth in lending", "debt collection", "credit reporting", "payday lending",
    "small business lending", "auto finance", "deposit accounts", "student loans",
    "equal credit opportunity", "home mortgage disclosure", "loan servicing",
    "anti-money laundering", "appraisal", "prepaid accounts",
]


def fetch_term(term, per_page=250):
    params = [
        ("conditions[term]", term),
        ("per_page", str(per_page)),
        ("order", "relevance"),
        ("fields[]", "title"), ("fields[]", "abstract"),
        ("fields[]", "html_url"), ("fields[]", "publication_date"),
    ]
    url = "https://www.federalregister.gov/api/v1/documents.json?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read()).get("results", [])


def main():
    os.makedirs(OUT, exist_ok=True)
    seen, docs = set(), []
    for term in TERMS:
        try:
            results = fetch_term(term)
        except Exception as e:  # noqa: BLE001
            print(f"  warn: '{term}' fetch failed: {e}")
            continue
        for r in results:
            url = r.get("html_url", "")
            text = (r.get("abstract") or "").strip()
            if not text or url in seen:
                continue
            seen.add(url)
            docs.append({"title": r.get("title", ""), "source": url,
                         "date": r.get("publication_date", ""), "text": text})
    path = os.path.join(OUT, "docs.jsonl")
    with open(path, "w") as f:
        for d in docs:
            f.write(json.dumps(d) + "\n")
    print(f"wrote {len(docs)} docs -> {path}")


if __name__ == "__main__":
    main()
