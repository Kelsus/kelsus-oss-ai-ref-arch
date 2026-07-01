#!/usr/bin/env python3
"""Render Synthea CSV claims into medical-invoice PDFs + matching gold labels.

Joins the Synthea export (claims, claims_transactions, patients, providers,
payers, procedures/conditions for code descriptions) into structured claim
records, then for each sampled claim writes:

  output/forms/<claim_id>.pdf     a realistic medical invoice (extraction input)
  ../gold/claims/<claim_id>.json  the ground-truth fields (App 1 scores against this)

Because the PDF and the gold JSON come from the SAME record, extraction
accuracy is measured against truth by construction (ADR-0004). No PHI/PII —
every record is synthetic.

Usage:  python3 render_forms.py [N]      # N invoices, default 50
Note:   Synthea procedure codes are SNOMED-CT; map to CPT/HCPCS and diagnoses
        to ICD-10 in a later pass for billing-authentic codes (documented TODO).
"""
import csv
import hashlib
import json
import random
import sys
from collections import defaultdict
from pathlib import Path

from reportlab.lib import colors
from reportlab.lib.pagesizes import letter
from reportlab.lib.units import inch
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.platypus import (SimpleDocTemplate, Table, TableStyle, Paragraph,
                                Spacer)

HERE = Path(__file__).parent
CSV = HERE / "output" / "csv"
FORMS = HERE / "output" / "forms"
GOLD = HERE.parent / "gold" / "claims"


def synth_npi(seed):
    """A standards-valid synthetic NPI, derived deterministically from a provider Id.

    Synthea emits no real NPIs, so earlier builds used the provider's UUID `Id` as a
    stand-in. That made provider_npi an unfair field: it measured "will you transcribe
    a UUID", which penalised reasoning models that correctly reject a UUID as an NPI
    (DeepSeek-V4-Pro nulled it 64% of the time). We instead synthesise a real-format
    NPI: a 9-digit base (NPIs lead with 1 or 2) plus a Luhn check digit computed over
    the CMS '80840' prefix + base. Deterministic in `seed` (same provider -> same NPI),
    so regeneration is stable and the PDF and gold always agree."""
    h = int(hashlib.sha256(str(seed).encode()).hexdigest(), 16)
    base = "1" + f"{h % 10**8:08d}"                 # 9 digits, NPI-style leading 1
    total = 0
    for i, ch in enumerate(reversed("80840" + base)):
        d = int(ch)
        if i % 2 == 0:                              # double the digit left of the (future) check digit
            d *= 2
            if d > 9:
                d -= 9
        total += d
    return base + str((10 - total % 10) % 10)       # 10-digit NPI with Luhn check

# Layout diversity: the SAME claim rendered as different real-world document
# styles, with synonym labels, varied field order, table headers, and accents.
# All 8 scored fields are always present (extraction stays fair) — what varies
# is how they're labeled/placed, which is the realistic robustness test.
VARIANTS = [
    {"id": "clinical-statement", "title": "Statement of Services", "accent": "#1F3A68",
     "letterhead_provider": True,
     "labels": {"claim": "Claim #", "dos": "Service date", "patient": "Patient",
                "dob": "DOB", "sex": "Sex", "member": "Member ID", "payer": "Payer",
                "npi": "Provider NPI", "provider": "Provider", "specialty": "Specialty",
                "dx": "Diagnoses", "ctype": "Claim type"},
     "th": ["Date", "Code", "Description", "Units", "Unit $", "Charge"]},
    {"id": "billing-statement", "title": "Patient Billing Statement", "accent": "#0B5D4E",
     "letterhead_provider": False,
     "labels": {"claim": "Account #", "dos": "Date of Service", "patient": "Member",
                "dob": "DOB", "sex": "Sex", "member": "Member ID", "payer": "Insurance Plan",
                "npi": "NPI #", "provider": "Rendering Provider", "specialty": "Specialty",
                "dx": "Diagnosis Codes", "ctype": "Form"},
     "th": ["DOS", "CPT/HCPCS", "Service", "Qty", "Rate", "Amount"]},
    {"id": "itemized-invoice", "title": "Itemized Invoice", "accent": "#6B2D5C",
     "letterhead_provider": True,
     "labels": {"claim": "Invoice #", "dos": "Svc Date", "patient": "Bill To",
                "dob": "DOB", "sex": "Sex", "member": "Subscriber ID", "payer": "Insurer",
                "npi": "Provider ID", "provider": "Physician", "specialty": "Dept",
                "dx": "Dx", "ctype": "Type"},
     "th": ["Date", "Code", "Item", "Units", "Price", "Line Total"]},
    {"id": "eob", "title": "Explanation of Benefits", "accent": "#7A3E12",
     "letterhead_provider": False,
     "labels": {"claim": "Claim ID", "dos": "Service Period", "patient": "Beneficiary",
                "dob": "Birth Date", "sex": "Sex", "member": "Member ID", "payer": "Payer",
                "npi": "NPI", "provider": "Servicing Provider", "specialty": "Specialty",
                "dx": "Diagnoses", "ctype": "Claim Type"},
     "th": ["Date", "Code", "Description", "Units", "Allowed", "Charge"]},
]


def load(name):
    with open(CSV / f"{name}.csv", newline="") as f:
        return list(csv.DictReader(f))


def fnum(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return 0.0


def build_code_descriptions():
    """code -> human-readable description, from procedures + conditions."""
    desc = {}
    for name in ("procedures", "conditions"):
        path = CSV / f"{name}.csv"
        if not path.exists():
            continue
        with open(path, newline="") as f:
            for r in csv.DictReader(f):
                if r.get("CODE") and r.get("DESCRIPTION"):
                    desc.setdefault(r["CODE"], r["DESCRIPTION"])
    return desc


def build_patient_payer():
    """patient_id -> (payer_name, member_id) from the latest payer transition."""
    payers = {p["Id"]: p["NAME"] for p in load("payers")}
    out = {}
    path = CSV / "payer_transitions.csv"
    if not path.exists():
        return out
    with open(path, newline="") as f:
        for r in csv.DictReader(f):
            pid = r.get("PATIENT")
            payer_id = r.get("PAYER")
            member = r.get("MEMBERID") or r.get("MEMBER_ID") or ""
            if pid and payer_id in payers:
                out[pid] = (payers[payer_id], member)  # last wins ~ most recent
    return out


def charges_for(claim_ids):
    """Stream the big transactions file once; collect CHARGE/PAYMENT rows."""
    wanted = set(claim_ids)
    charges = defaultdict(list)
    paid = defaultdict(float)
    with open(CSV / "claims_transactions.csv", newline="") as f:
        for r in csv.DictReader(f):
            cid = r.get("CLAIMID")
            if cid not in wanted:
                continue
            if r.get("TYPE") == "CHARGE":
                charges[cid].append({
                    "date": (r.get("FROMDATE") or "")[:10],
                    "procedure_code": r.get("PROCEDURECODE", ""),
                    "place_of_service": r.get("PLACEOFSERVICE", ""),
                    "units": int(fnum(r.get("UNITS")) or 1),
                    "unit_charge": round(fnum(r.get("UNITAMOUNT")), 2),
                    "charge": round(fnum(r.get("AMOUNT")), 2),
                })
            elif r.get("TYPE") in ("PAYMENT", "TRANSFERIN"):
                paid[cid] += fnum(r.get("PAYMENTS")) or 0.0
    return charges, paid


def assemble(n):
    patients = {p["Id"]: p for p in load("patients")}
    providers = {p["Id"]: p for p in load("providers")}
    desc = build_code_descriptions()
    pat_payer = build_patient_payer()

    claims = load("claims")
    # Oversample claim ids, then keep the first n that actually have charges.
    candidates = [c for c in claims if c.get("PATIENTID") in patients][: n * 8]
    charges, paid = charges_for([c["Id"] for c in candidates])

    records = []
    for c in candidates:
        cid = c["Id"]
        lines = charges.get(cid)
        if not lines:
            continue
        pat = patients[c["PATIENTID"]]
        prov = providers.get(c.get("PROVIDERID"), {})
        payer_name, member = pat_payer.get(c["PATIENTID"], ("Self-Pay", ""))
        diagnoses = [c[f"DIAGNOSIS{i}"] for i in range(1, 9)
                     if c.get(f"DIAGNOSIS{i}")]
        for ln in lines:
            ln["description"] = desc.get(ln["procedure_code"], "Medical service")
        billed = round(sum(l["charge"] for l in lines), 2)
        amt_paid = round(min(paid.get(cid, 0.0), billed), 2)
        rec = {
            "claim_id": cid,
            "claim_type": "CMS-1500 (professional)",
            "patient": {
                "name": f'{pat.get("FIRST","")} {pat.get("LAST","")}'.strip(),
                "dob": pat.get("BIRTHDATE", ""),
                "sex": pat.get("GENDER", ""),
                "member_id": member or pat.get("Id", "")[:13],
            },
            "payer": {"name": payer_name},
            "provider": {
                "name": prov.get("NAME", ""),
                "npi": synth_npi(prov.get("Id", "")),  # standards-valid synthetic NPI (was: raw UUID Id)
                "specialty": prov.get("SPECIALITY", ""),
                "address": ", ".join(x for x in [prov.get("ADDRESS", ""),
                           prov.get("CITY", ""), prov.get("STATE", ""),
                           prov.get("ZIP", "")] if x),
            },
            "service_date": lines[0]["date"],
            "diagnoses": diagnoses,
            "line_items": lines,
            "totals": {"billed": billed, "paid": amt_paid,
                       "balance": round(billed - amt_paid, 2)},
        }
        records.append(rec)
        if len(records) >= n:
            break
    return records


def render_pdf(rec, path, idx=0):
    V = VARIANTS[idx % len(VARIANTS)]
    L = V["labels"]
    accent = colors.HexColor(V["accent"])
    rng = random.Random(idx)            # deterministic field order per invoice
    prov, pat, tot = rec["provider"], rec["patient"], rec["totals"]

    styles = getSampleStyleSheet()
    h = ParagraphStyle("h", parent=styles["Title"], textColor=accent, fontSize=18)
    small = ParagraphStyle("s", parent=styles["Normal"], fontSize=8, textColor=colors.grey)
    doc = SimpleDocTemplate(str(path), pagesize=letter,
                            topMargin=0.6 * inch, bottomMargin=0.6 * inch)
    el = [Paragraph(V["title"], h)]
    # Some templates put the provider in an unlabeled letterhead (distractor);
    # all templates also carry a labeled provider field below.
    el.append(Paragraph(
        (f'{prov["name"]} &nbsp;·&nbsp; {prov["specialty"]}<br/>{prov["address"]}'
         if V["letterhead_provider"] else prov["address"]), styles["Normal"]))
    el.append(Spacer(1, 10))

    pairs = [
        (L["claim"], rec["claim_id"]), (L["dos"], rec["service_date"]),
        (L["patient"], pat["name"]), (L["dob"], pat["dob"]), (L["sex"], pat["sex"]),
        (L["member"], pat["member_id"]), (L["payer"], rec["payer"]["name"]),
        (L["npi"], prov["npi"]), (L["provider"], prov["name"]),
        (L["specialty"], prov["specialty"]),
        (L["dx"], ", ".join(rec["diagnoses"]) or "—"), (L["ctype"], rec["claim_type"]),
    ]
    rng.shuffle(pairs)                  # vary field order across invoices
    meta = []
    for i in range(0, len(pairs), 2):
        row = []
        for j in (i, i + 1):
            row += [pairs[j][0], str(pairs[j][1])] if j < len(pairs) else ["", ""]
        meta.append(row)
    mt = Table(meta, colWidths=[1.25 * inch, 2.35 * inch, 1.25 * inch, 1.9 * inch])
    mt.setStyle(TableStyle([
        ("FONTSIZE", (0, 0), (-1, -1), 8.5),
        ("TEXTCOLOR", (0, 0), (0, -1), accent), ("TEXTCOLOR", (2, 0), (2, -1), accent),
        ("FONTNAME", (0, 0), (0, -1), "Helvetica-Bold"),
        ("FONTNAME", (2, 0), (2, -1), "Helvetica-Bold"),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
    ]))
    el += [mt, Spacer(1, 12)]

    rows = [V["th"]]
    for ln in rec["line_items"]:
        rows.append([ln["date"], ln["procedure_code"], ln["description"][:46],
                     str(ln["units"]), f'{ln["unit_charge"]:.2f}', f'{ln["charge"]:.2f}'])
    t = Table(rows, colWidths=[0.8 * inch, 0.9 * inch, 2.9 * inch, 0.5 * inch,
                               0.8 * inch, 0.9 * inch])
    t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, 0), accent),
        ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
        ("FONTSIZE", (0, 0), (-1, -1), 8.5),
        ("ALIGN", (3, 0), (-1, -1), "RIGHT"),
        ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, colors.HexColor("#F2F5FA")]),
        ("LINEBELOW", (0, 0), (-1, -1), 0.25, colors.lightgrey),
    ]))
    el += [t, Spacer(1, 8)]

    tt = Table([["", "Billed", f'${tot["billed"]:.2f}'],
                ["", "Paid", f'${tot["paid"]:.2f}'],
                ["", "Balance due", f'${tot["balance"]:.2f}']],
               colWidths=[4.3 * inch, 1.4 * inch, 1.2 * inch])
    tt.setStyle(TableStyle([
        ("FONTSIZE", (0, 0), (-1, -1), 9), ("ALIGN", (1, 0), (-1, -1), "RIGHT"),
        ("FONTNAME", (1, 2), (-1, 2), "Helvetica-Bold"),
        ("TEXTCOLOR", (1, 2), (-1, 2), accent), ("LINEABOVE", (1, 2), (-1, 2), 0.5, accent),
    ]))
    el += [tt, Spacer(1, 16),
           Paragraph("SYNTHETIC DOCUMENT — generated from Synthea. "
                     "No real patient data. For benchmarking only.", small)]
    doc.build(el)
    return V["id"]


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 50
    FORMS.mkdir(parents=True, exist_ok=True)
    GOLD.mkdir(parents=True, exist_ok=True)
    print(f"==> Assembling up to {n} claims from {CSV}")
    records = assemble(n)
    print(f"==> Rendering {len(records)} invoices + gold labels")
    for i, rec in enumerate(records):
        rec["template_variant"] = render_pdf(rec, FORMS / f'{rec["claim_id"]}.pdf', i)
        with open(GOLD / f'{rec["claim_id"]}.json', "w") as f:
            json.dump(rec, f, indent=2)
    print(f"==> PDFs -> {FORMS}")
    print(f"==> Gold labels -> {GOLD}")
    if records:
        ex = records[0]
        print(f"==> Example: {ex['claim_id']} | {ex['payer']['name']} | "
              f"{len(ex['line_items'])} line(s) | billed ${ex['totals']['billed']:.2f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
