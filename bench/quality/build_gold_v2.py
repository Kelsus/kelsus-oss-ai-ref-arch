#!/usr/bin/env python3
"""Build rag_gold_v2.json from the frozen v1 set — deterministic, no LLM.

WHY (2026-07-01 review + EXP-002/PR#65): v1's 250 items contain only 207 unique
questions; 26 question texts repeat (up to x8) and 19 of them carry DIFFERENT
gold answers ("What is the purpose of the notice?" x5, each meaning a different
notice). A deterministic candidate answers a repeated question the same way
every time, so it is structurally wrong on all-but-one copy; and an entity-free
question is unanswerable-as-posed against the 2,686-doc corpus. Both defects
compress every model into the same band and cap retrieval recall.

THE TRANSFORM (all deterministic — the fix reuses the per-item `title` v1
already carries):
  1. ANCHOR ambiguous questions with their document identity:
     'Regarding "{title}": {question}' — applied when the question text is
     duplicated in v1, or matches a generic-referent pattern (asks about "the
     notice/rule/proposal/..." without naming a specific act, agency document,
     year, or section). A real analyst names the document they are asking about.
  2. DEDUPE: identical (question, title, answer) triples keep one copy.
  3. DROP irreconcilable items: same post-anchor question with different gold
     answers (same doc, conflicting golds) — cannot be scored deterministically.
  4. ASSERT: every remaining question is unique, and unique per gold answer.

Output: rag_gold_v2.json = {"_meta": {...provenance+counts...}, "answerable": [...]}
(score.py reads both the list and the dict shape). v1 stays frozen in-tree for
reproduction of published numbers.

Usage:  python3 build_gold_v2.py [--report]     # --report prints per-item actions
"""
import json
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

HERE = Path(__file__).parent
V1 = HERE / "rag_gold.json"
V2 = HERE / "rag_gold_v2.json"

# ANCHOR BY DEFAULT. A first cut used selective heuristics ("anchor only what
# looks generic") and the audit found 33 residual ambiguous questions ("the
# Board's invitation", "mentioned in the passage"). Selective rules leak; the
# safe bias is inverted: a question escapes anchoring only when it is provably
# specific AND its text is unique in v1. Over-anchoring is semantically free —
# an already-specific question with its title prefixed is still answerable —
# while under-anchoring reproduces the v1 defect.

# Generic-referent phrases force anchoring even when an acronym is present
# ("What is the CFPB seeking information for?" names an agency, not a document —
# the CFPB has many RFIs). Allows up to two words between "the" and the noun
# ("the final regulations", "the new regulation").
_GENERIC = re.compile(
    r"\b(?:the|its|their|of) (?:[\w'().-]+ ){0,3}(notice|rules?|proposal|reports?|"
    r"requests?|collections?|amendments?|circular|statements?|regulations?|"
    r"announcement|update|guidance|advisory|opinion|rulemaking|framework|agencies|"
    r"invitation|submissions?|solicitation|revisions?|extension|passage|document|"
    r"councils?|OMB)\b", re.I)

# Strong identifiers: a quoted phrase, a year, a numbered cite, a multi-word
# named instrument, or an acronym (FCRA, EGRRCPA, NCUA...).
_STRONG = re.compile(
    r"(\"[^\"]{6,}\""                                             # quoted phrase
    r"|\b(19|20)\d{2}\b"                                          # year
    r"|§|\bsection\s+\d+|\b\d+\s+CFR\b|\bCircular\s+\d{4}-\d+"    # cites
    r"|\b(?:[A-Z][a-z]+\s+){2,}(?:Act|Report|Rule|Program|Survey|Study)\b"  # named instrument
    r"|\b[A-Z]{3,}\b)")                                           # acronym


def needs_anchor(q, dup):
    if dup:                                    # repeated text is ambiguous by construction
        return True
    if _GENERIC.search(q):                     # points at "the <document>" without naming it
        return True
    return not _STRONG.search(q)               # default: anchor unless provably specific


def main():
    report = "--report" in sys.argv
    items = json.load(open(V1))
    assert isinstance(items, list), "v1 shape changed; expected a list"

    qcount = Counter(i["question"] for i in items)
    anchored, kept, actions = 0, [], []
    for it in items:
        q = it["question"].strip()
        if needs_anchor(q, qcount[q] > 1):
            title = (it.get("title") or "").strip()
            assert title, f"cannot anchor without a title: {q!r}"
            q2 = f'Regarding "{title}": {q[0].lower() + q[1:]}'
            anchored += 1
            actions.append(("ANCHOR", q, q2))
        else:
            q2 = q
            actions.append(("KEEP", q, q2))
        kept.append({"question": q2, "answer": it["answer"],
                     "source": it["source"], "title": it.get("title", "")})

    # 2. dedupe exact (question, answer) pairs post-anchor
    seen, deduped = set(), []
    for it in kept:
        key = (it["question"], it["answer"])
        if key in seen:
            actions.append(("DEDUPE", it["question"], ""))
            continue
        seen.add(key)
        deduped.append(it)

    # 3. drop post-anchor questions that STILL carry conflicting golds
    golds = defaultdict(set)
    for it in deduped:
        golds[it["question"]].add(it["answer"])
    conflicted = {q for q, g in golds.items() if len(g) > 1}
    final = [it for it in deduped if it["question"] not in conflicted]
    for q in sorted(conflicted):
        actions.append(("DROP-CONFLICT", q, ""))

    # 4. hard assertions — the properties v1 lacked
    qs = [it["question"] for it in final]
    assert len(qs) == len(set(qs)), "duplicate questions survived"
    assert all(len(g) == 1 for q, g in
               ((q, {it["answer"] for it in final if it["question"] == q}) for q in set(qs))), \
        "conflicting golds survived"

    meta = {"built_from": "rag_gold.json (v1, frozen)",
            "builder": "build_gold_v2.py (deterministic; no LLM)",
            "v1_items": len(items), "v1_unique_questions": len(qcount),
            "anchored": anchored, "deduped": len(kept) - len(deduped),
            "dropped_conflicting": len(deduped) - len(final),
            "v2_items": len(final),
            "note": ("Questions carrying a generic referent or duplicated text are "
                     "anchored with the source document title; deterministic "
                     "duplicates removed; irreconcilable golds dropped. See the "
                     "2026-07-01 review + EXP-002 (PR#65) for why v1 RAG numbers "
                     "are not comparable to v2 runs.")}
    json.dump({"_meta": meta, "answerable": final}, open(V2, "w"), indent=1)
    print(json.dumps(meta, indent=2))
    if report:
        for act, q, q2 in actions:
            print(f"  {act:14} {q[:90]}" + (f"\n  {'->':>14} {q2[:90]}" if act == "ANCHOR" else ""))


if __name__ == "__main__":
    main()
