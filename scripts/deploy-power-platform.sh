#!/usr/bin/env bash
# Personal project, not for production, as is; not affiliated with the author's employer, Liquidware or Microsoft.
set -euo pipefail

ENTRA_MANIFEST="${1:-entra-manifest.json}"
AZURE_OUTPUTS="${2:-azure-outputs.json}"
OUT_FILE="${3:-power-platform-manifest.json}"

python3 scripts/validate.py
echo "Validated Power Platform DLP baseline and unpacked Power Automate workflows (inputs: ${ENTRA_MANIFEST}, ${AZURE_OUTPUTS}, output: ${OUT_FILE})."
