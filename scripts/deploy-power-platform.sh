#!/usr/bin/env bash
# Personal project, not for production, as is; not affiliated with the author's employer, Liquidware or Microsoft.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ENTRA_MANIFEST="${1:-entra-manifest.json}"
AZURE_OUTPUTS="${2:-azure-outputs.json}"
OUT_FILE="${3:-power-platform-manifest.json}"

PYTHON_BIN="python3"
if ! "${PYTHON_BIN}" --version >/dev/null 2>&1; then
    if command -v py >/dev/null 2>&1; then
        PYTHON_BIN="py"
    else
        PYTHON_BIN="python"
    fi
fi

"${PYTHON_BIN}" "${REPO_ROOT}/scripts/validate.py"

if [[ -f "${ENTRA_MANIFEST}" && -f "${AZURE_OUTPUTS}" ]]; then
    pwsh -NoProfile -File "${SCRIPT_DIR}/Deploy-AvdPowerPlatform.ps1" \
        -EntraManifestPath "${ENTRA_MANIFEST}" \
        -AzureOutputsPath "${AZURE_OUTPUTS}" \
        -OutputPath "${OUT_FILE}"
    "${PYTHON_BIN}" "${REPO_ROOT}/scripts/validate.py" --manifest "${OUT_FILE}"
fi

echo "Validated Power Platform DLP baseline and unpacked Power Automate workflows (inputs: ${ENTRA_MANIFEST}, ${AZURE_OUTPUTS}, output: ${OUT_FILE})."
