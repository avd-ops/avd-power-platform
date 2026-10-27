#!/usr/bin/env python3
# Personal project, not for production, as is; not affiliated with the author's employer, Liquidware or Microsoft.
"""Offline unit and integration tests for avd-power-platform CRUD, packing, idempotency, and teardown."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import validate  # noqa: E402


class PowerPlatformControlPlaneTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.work_dir = Path(self.temp_dir.name)
        self.entra_manifest_path = self.work_dir / "entra-manifest.json"
        self.azure_outputs_path = self.work_dir / "azure-outputs.json"
        self.output_manifest_path = self.work_dir / "power-platform-manifest.json"
        self.run_manifest_path = self.work_dir / "power-platform-run-manifest.json"
        self.packed_zip_path = self.work_dir / "AvdDay2Automation.zip"

        self.entra_manifest = {
            "schema": "avd-ops-entra-manifest/v1",
            "environment": "dev",
            "prefix": "avd",
            "groups": {
                "avdUsersGroupId": "00000000-0000-0000-0000-000000001111",
                "avdAdminsGroupId": "00000000-0000-0000-0000-000000002222",
                "sessionHostsDynamicGroupId": "00000000-0000-0000-0000-000000003333",
                "breakGlassExcludeGroupId": "00000000-0000-0000-0000-000000004444",
            },
            "conditionalAccess": [],
            "entraKerberosReady": True,
        }
        self.entra_manifest_path.write_text(json.dumps(self.entra_manifest, indent=2), encoding="utf-8")

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def _run_deploy(self) -> subprocess.CompletedProcess[str]:
        cmd = [
            "pwsh",
            "-NoProfile",
            "-File",
            str(ROOT / "scripts" / "Deploy-AvdPowerPlatform.ps1"),
            "-EntraManifestPath",
            str(self.entra_manifest_path),
            "-AzureOutputsPath",
            str(self.azure_outputs_path),
            "-OutputPath",
            str(self.output_manifest_path),
            "-RunManifestPath",
            str(self.run_manifest_path),
            "-PackedSolutionZipPath",
            str(self.packed_zip_path),
            "-DryRun",
            "-Confirm:$false",
        ]
        return subprocess.run(cmd, cwd=str(ROOT), capture_output=True, text=True, check=False)

    def _run_teardown(self, discard_last_copy: bool = False) -> subprocess.CompletedProcess[str]:
        cmd = [
            "pwsh",
            "-NoProfile",
            "-File",
            str(ROOT / "scripts" / "Remove-AvdPowerPlatform.ps1"),
            "-RunManifestPath",
            str(self.run_manifest_path),
            "-DryRun",
            "-Confirm:$false",
        ]
        if discard_last_copy:
            cmd.append("-DiscardLastCopy")
        return subprocess.run(cmd, cwd=str(ROOT), capture_output=True, text=True, check=False)

    def test_repo_validation_and_schema_guard(self) -> None:
        errors = validate.validate_repo()
        self.assertEqual(errors, [])

        bad_manifest = self.work_dir / "bad-manifest.json"
        bad_manifest.write_text(
            json.dumps(
                {
                    "schema": "wrong-schema",
                    "environment": "staging",
                    "powerPlatformEnvironmentName": "",
                    "extraField": True,
                }
            ),
            encoding="utf-8",
        )
        schema_errors = validate.validate_manifest_against_schema(
            bad_manifest, ROOT / "contracts" / "power-platform-manifest.schema.json"
        )
        self.assertGreaterEqual(len(schema_errors), 4)

    def test_solution_packing_and_env_var_injection_without_vnet(self) -> None:
        host_pool_arm_id = (
            "/subscriptions/00000000-0000-0000-0000-000000000000"
            "/resourceGroups/rg-avd-cp-dev/providers/Microsoft.DesktopVirtualization/hostPools/hp-avd-dev"
        )
        azure_outputs = {
            "schema": "avd-ops-azure-outputs/v1",
            "environment": "dev",
            "location": "eastus2",
            "resourceGroups": {
                "controlPlane": "rg-avd-cp-dev",
                "sessionHosts": "rg-avd-sh-dev",
                "network": "rg-avd-net-dev",
                "storage": "rg-avd-sto-dev",
            },
            "hostPoolArmId": host_pool_arm_id,
            "hostPools": [
                {
                    "name": "hp-avd-dev",
                    "type": "Pooled",
                    "workspace": "ws-avd-dev",
                    "appGroupIds": [],
                }
            ],
            "network": {
                "vnetName": "vnet-avd-dev",
                "privateLinkEnabled": True,
            },
        }
        self.azure_outputs_path.write_text(json.dumps(azure_outputs, indent=2), encoding="utf-8")

        res = self._run_deploy()
        self.assertEqual(res.returncode, 0, msg=f"Deploy failed: {res.stderr}\n{res.stdout}")

        self.assertTrue(self.output_manifest_path.is_file())
        self.assertTrue(self.run_manifest_path.is_file())
        self.assertTrue(self.packed_zip_path.is_file())

        manifest = json.loads(self.output_manifest_path.read_text(encoding="utf-8-sig"))
        self.assertEqual(manifest["schema"], "avd-ops-power-platform-manifest/v1")
        self.assertEqual(manifest["environment"], "dev")
        self.assertEqual(manifest["powerPlatformEnvironmentName"], "[avd-ops-avd-dev] AVD Day-2 Automation")
        self.assertEqual(manifest["dlpPolicyName"], "[avd-ops-avd-dev] AVD Day-2 Automation Strict DLP Policy")
        self.assertEqual(
            manifest["activeWorkflows"],
            [
                "[avd-ops] Self-Service AVD Pool Access Request (Teams Approval)",
                "[avd-ops] Approval-Gated Session Host Drain Mode and Restart",
            ],
        )

        run_manifest = json.loads(self.run_manifest_path.read_text(encoding="utf-8-sig"))
        self.assertFalse(run_manifest["enterprisePolicy"]["deployed"])
        self.assertFalse(run_manifest["enterprisePolicy"]["created"])
        self.assertTrue(run_manifest["powerPlatformEnvironment"]["created"])
        self.assertTrue(run_manifest["dlpPolicy"]["created"])
        self.assertTrue(run_manifest["solution"]["created"])

        # Inspect packed .zip for injected environment variables and metadata files
        with zipfile.ZipFile(self.packed_zip_path, "r") as zf:
            names = set(zf.namelist())
            self.assertIn("[Content_Types].xml", names)
            self.assertIn("customizations.xml", names)
            self.assertIn("Other/Solution.xml", names)
            self.assertIn("Workflows/RequestPoolAccess.json", names)
            self.assertIn("Workflows/SessionHostDrainAndRestart.json", names)

            users_xml = ET.fromstring(
                zf.read("environmentvariabledefinitions/avd_UsersGroupId/environmentvariabledefinition.xml")
            )
            self.assertEqual(
                users_xml.findtext("defaultvalue"),
                "00000000-0000-0000-0000-000000001111",
            )
            users_json = json.loads(
                zf.read("environmentvariabledefinitions/avd_UsersGroupId/environmentvariablevalues.json").decode(
                    "utf-8-sig"
                )
            )
            self.assertEqual(
                users_json["environmentvariablevalues"]["environmentvariablevalue"]["value"],
                "00000000-0000-0000-0000-000000001111",
            )

            hp_xml = ET.fromstring(
                zf.read("environmentvariabledefinitions/avd_HostPoolArmId/environmentvariabledefinition.xml")
            )
            self.assertEqual(hp_xml.findtext("defaultvalue"), host_pool_arm_id)
            hp_json = json.loads(
                zf.read("environmentvariabledefinitions/avd_HostPoolArmId/environmentvariablevalues.json").decode(
                    "utf-8-sig"
                )
            )
            self.assertEqual(
                hp_json["environmentvariablevalues"]["environmentvariablevalue"]["value"],
                host_pool_arm_id,
            )

        settings_path = self.work_dir / "deploymentSettings.json"
        self.assertTrue(settings_path.is_file())
        settings = json.loads(settings_path.read_text(encoding="utf-8-sig"))
        env_vars = {item["SchemaName"]: item["Value"] for item in settings["EnvironmentVariables"]}
        self.assertEqual(env_vars["avd_UsersGroupId"], "00000000-0000-0000-0000-000000001111")
        self.assertEqual(env_vars["avd_HostPoolArmId"], host_pool_arm_id)

    def test_vnet_injection_idempotency_and_teardown_discard_last_copy(self) -> None:
        subnet_id = (
            "/subscriptions/00000000-0000-0000-0000-000000000000"
            "/resourceGroups/rg-avd-net-dev/providers/Microsoft.Network/virtualNetworks/vnet-avd-dev"
            "/subnets/snet-powerplatform"
        )
        azure_outputs = {
            "outputs": {
                "location": {"value": "eastus"},
                "resourceGroupName": {"value": "rg-avd-cp-dev"},
                "hostPoolArmId": {
                    "value": (
                        "/subscriptions/00000000-0000-0000-0000-000000000000"
                        "/resourceGroups/rg-avd-cp-dev/providers/Microsoft.DesktopVirtualization/hostPools/hp-avd-dev"
                    )
                },
                "powerPlatformDelegatedSubnetId": {"value": subnet_id},
            }
        }
        self.azure_outputs_path.write_text(json.dumps(azure_outputs, indent=2), encoding="utf-8")

        # First run: all resources created = True
        res1 = self._run_deploy()
        self.assertEqual(res1.returncode, 0, msg=res1.stderr)
        run1 = json.loads(self.run_manifest_path.read_text(encoding="utf-8-sig"))
        self.assertTrue(run1["enterprisePolicy"]["deployed"])
        self.assertTrue(run1["enterprisePolicy"]["created"])
        self.assertEqual(run1["enterprisePolicy"]["name"], "ep-avd-avd-dev")
        self.assertEqual(run1["enterprisePolicy"]["delegatedSubnetId"], subnet_id)
        self.assertTrue(run1["powerPlatformEnvironment"]["created"])
        self.assertTrue(run1["dlpPolicy"]["created"])

        # Second run: idempotent reuse -> created = False
        res2 = self._run_deploy()
        self.assertEqual(res2.returncode, 0, msg=res2.stderr)
        run2 = json.loads(self.run_manifest_path.read_text(encoding="utf-8-sig"))
        self.assertTrue(run2["enterprisePolicy"]["deployed"])
        self.assertFalse(run2["enterprisePolicy"]["created"])
        self.assertFalse(run2["powerPlatformEnvironment"]["created"])
        self.assertFalse(run2["dlpPolicy"]["created"])
        self.assertFalse(run2["solution"]["created"])

        # Teardown without -DiscardLastCopy must fail
        fail_teardown = self._run_teardown(discard_last_copy=False)
        self.assertNotEqual(fail_teardown.returncode, 0)
        self.assertIn("DiscardLastCopy", fail_teardown.stderr + fail_teardown.stdout)
        self.assertTrue(self.run_manifest_path.is_file())

        # Teardown when created = False should not delete pre-existing tenant objects
        ok_teardown_noop = self._run_teardown(discard_last_copy=True)
        self.assertEqual(ok_teardown_noop.returncode, 0, msg=ok_teardown_noop.stderr)
        self.assertEqual(ok_teardown_noop.stdout.strip(), "")
        self.assertFalse(self.run_manifest_path.is_file())

        # Fresh run (created = True) followed by teardown with -DiscardLastCopy removes all 3 created resources
        res3 = self._run_deploy()
        self.assertEqual(res3.returncode, 0, msg=res3.stderr)
        ok_teardown_created = self._run_teardown(discard_last_copy=True)
        self.assertEqual(ok_teardown_created.returncode, 0, msg=ok_teardown_created.stderr)
        removed = ok_teardown_created.stdout.strip().split(",")
        self.assertIn("dlpPolicy:[avd-ops-avd-dev] AVD Day-2 Automation Strict DLP Policy", removed)
        self.assertIn("powerPlatformEnvironment:[avd-ops-avd-dev] AVD Day-2 Automation", removed)
        self.assertIn("enterprisePolicy:ep-avd-avd-dev", removed)


if __name__ == "__main__":
    unittest.main()
