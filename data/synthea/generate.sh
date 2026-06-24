#!/usr/bin/env bash
# Generate a synthetic patient/claims population with Synthea (MITRE), then
# (Sprint 1) render claims into CMS-1500 / EOB / medical-invoice PDFs.
# No PHI/PII — every record is synthetic (ADR-0004).
set -euo pipefail

POP="${1:-200}"                      # number of synthetic patients
STATE="${2:-Massachusetts}"
SEED="${3:-1337}"   # pinned: eval data must be byte-reproducible          # Synthea models US state demographics
HERE="$(cd "$(dirname "$0")" && pwd)"
JAR="$HERE/synthea-with-dependencies.jar"
OUT="$HERE/output"
SYNTHEA_VERSION="v4.0.0"   # pinned release, NOT master-branch-latest — a rolling tag would change the eval set over time

command -v java >/dev/null 2>&1 || { echo "ERROR: Java 11+ required (brew install temurin)"; exit 1; }

if [[ ! -f "$JAR" ]]; then
  echo "==> Downloading Synthea $SYNTHEA_VERSION (one-time, build-time only)"
  curl -fsSL -o "$JAR" \
    "https://github.com/synthetichealth/synthea/releases/download/${SYNTHEA_VERSION}/synthea-with-dependencies.jar"
fi

echo "==> Generating $POP synthetic patients ($STATE) with costs + claim transactions"
java -jar "$JAR" \
  -p "$POP" \
  -s "$SEED" \
  --exporter.baseDirectory "$OUT" \
  --exporter.csv.export true \
  --exporter.fhir.export false \
  --generate.append_numbers_to_person_names false \
  "$STATE"

echo "==> CSV written to $OUT/csv (claims.csv, claims_transactions.csv, encounters.csv, ...)"
echo "==> Next (Sprint 1): python3 $HERE/render_forms.py  # CSV -> CMS-1500/EOB PDFs + gold labels"
