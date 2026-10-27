#!/usr/bin/env python3
# Personal project, not for production, as is; not affiliated with the author's employer, Liquidware or Microsoft.
"""Validate all JSON templates, unpacked solution files, contract schemas, and no-leak guardrails."""

from __future__ import annotations

import argparse
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EMAIL = re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b")
ALLOWED_DOMAINS = ("example.com", "contoso.com", "users.noreply.github.com")
SKIP_DIRS = {".git", "__pycache__", ".pytest_cache", "dist"}


def validate_manifest_against_schema(manifest_path: Path, schema_path: Path) -> list[str]:
    errs: list[str] = []
    if not manifest_path.is_file():
        return [f"{manifest_path}: manifest file does not exist"]
    try:
        data = json.loads(manifest_path.read_text(encoding="utf-8-sig"))
    except Exception as exc:
        return [f"{manifest_path}: invalid JSON: {exc}"]

    schema = json.loads(schema_path.read_text(encoding="utf-8-sig"))
    if not isinstance(data, dict):
        return [f"{manifest_path}: root must be an object"]

    required = schema.get("required", [])
    for req in required:
        if req not in data:
            errs.append(f"{manifest_path}: missing required property '{req}'")

    props = schema.get("properties", {})
    if schema.get("additionalProperties") is False:
        extra = set(data.keys()) - set(props.keys())
        if extra:
            errs.append(f"{manifest_path}: unexpected properties {sorted(extra)}")

    if "schema" in data:
        expected_const = props.get("schema", {}).get("const")
        if data["schema"] != expected_const:
            errs.append(f"{manifest_path}: schema must be '{expected_const}', got '{data['schema']}'")

    if "environment" in data:
        allowed_envs = props.get("environment", {}).get("enum", ["dev", "test", "prod"])
        if data["environment"] not in allowed_envs:
            errs.append(f"{manifest_path}: environment must be one of {allowed_envs}, got '{data['environment']}'")

    for str_field in ("powerPlatformEnvironmentName", "dlpPolicyName"):
        if str_field in data and (not isinstance(data[str_field], str) or not data[str_field].strip()):
            errs.append(f"{manifest_path}: '{str_field}' must be a non-empty string")

    if "activeWorkflows" in data:
        wf = data["activeWorkflows"]
        if not isinstance(wf, list) or not all(isinstance(item, str) and item.strip() for item in wf):
            errs.append(f"{manifest_path}: 'activeWorkflows' must be an array of non-empty strings")

    return errs


def validate_repo(manifest_arg: str | None = None) -> list[str]:
    errors: list[str] = []
    schema_path = ROOT / "contracts" / "power-platform-manifest.schema.json"
    if not schema_path.is_file():
        errors.append("contracts/power-platform-manifest.schema.json: missing schema file")

    for jf in ROOT.rglob("*.json"):
        if any(part in SKIP_DIRS for part in jf.parts):
            continue
        try:
            data = json.loads(jf.read_text(encoding="utf-8-sig"))
        except Exception as exc:
            errors.append(f"{jf.relative_to(ROOT)}: invalid JSON: {exc}")
            continue
        if not isinstance(data, (dict, list)):
            errors.append(f"{jf.relative_to(ROOT)}: root must be object or array")

    # Validate DLP baseline
    dlp_path = ROOT / "dlp" / "avd-dlp-baseline.json"
    if dlp_path.is_file():
        dlp_data = json.loads(dlp_path.read_text(encoding="utf-8-sig"))
        if dlp_data.get("defaultConnectorsClassification") != "Blocked":
            errors.append("dlp/avd-dlp-baseline.json: defaultConnectorsClassification must be 'Blocked'")
        expected_connectors = {
            "/providers/Microsoft.PowerApps/apis/shared_teams",
            "/providers/Microsoft.PowerApps/apis/shared_approvals",
            "/providers/Microsoft.PowerApps/apis/shared_azuread",
            "/providers/Microsoft.PowerApps/apis/shared_arm",
        }
        actual_connectors = set(dlp_data.get("businessConnectors", []))
        if not expected_connectors.issubset(actual_connectors):
            errors.append("dlp/avd-dlp-baseline.json: missing required business connectors")

    # Validate unpacked solution XML and environment variable definitions
    sol_root = ROOT / "solutions" / "AvdDay2Automation"
    required_xmls = [
        sol_root / "[Content_Types].xml",
        sol_root / "customizations.xml",
        sol_root / "Other" / "Solution.xml",
        sol_root / "environmentvariabledefinitions" / "avd_UsersGroupId" / "environmentvariabledefinition.xml",
        sol_root / "environmentvariabledefinitions" / "avd_HostPoolArmId" / "environmentvariabledefinition.xml",
    ]
    for xml_file in required_xmls:
        if not xml_file.is_file():
            errors.append(f"{xml_file.relative_to(ROOT)}: missing unpacked solution XML file")
        else:
            try:
                ET.fromstring(xml_file.read_text(encoding="utf-8-sig"))
            except Exception as exc:
                errors.append(f"{xml_file.relative_to(ROOT)}: invalid XML: {exc}")

    # Validate shell scripts use LF line endings (guard against ShellCheck SC1017)
    for sh_file in (ROOT / "scripts").glob("*.sh"):
        if b"\r" in sh_file.read_bytes():
            errors.append(f"{sh_file.relative_to(ROOT)}: contains CRLF line endings; must use LF")

    # Validate leak rules
    for tf in ROOT.rglob("*"):
        if any(part in SKIP_DIRS for part in tf.parts) or not tf.is_file():
            continue
        if tf.suffix.lower() == ".zip":
            continue
        try:
            text = tf.read_text(encoding="utf-8-sig")
        except Exception:
            continue
        for m in EMAIL.finditer(text):
            addr = m.group(0)
            if not any(addr.endswith("@" + d) for d in ALLOWED_DOMAINS):
                errors.append(f"{tf.relative_to(ROOT)}: disallowed email address {addr}")

    if manifest_arg and schema_path.is_file():
        errors.extend(validate_manifest_against_schema(Path(manifest_arg), schema_path))

    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", help="Path to generated power-platform-manifest.json to validate against schema")
    args = parser.parse_args(argv)

    errors = validate_repo(args.manifest)
    if errors:
        for e in errors:
            print(f"::error::{e}")
        return 1

    print("All JSON templates, schemas, and leak checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
