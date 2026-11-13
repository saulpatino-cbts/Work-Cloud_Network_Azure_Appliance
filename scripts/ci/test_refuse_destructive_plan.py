"""Offline synthetic-plan regression tests; no Terraform or cloud execution."""

import json
import os
from pathlib import Path
import subprocess
import sys
import unittest


GUARD = Path(__file__).with_name("refuse_destructive_plan.py")
PROJECTS = (
    "module.ai[0].azapi_resource.foundry_project",
    "module.ai.azapi_resource.foundry_project",
)


class DestructivePlanTests(unittest.TestCase):
    def run_guard(self, address, resource_type, actions, *, types="azurerm_storage_account", addresses=PROJECTS):
        plan = {
            "resource_changes": [
                {"address": address, "type": resource_type, "change": {"actions": actions}}
            ]
        }
        return subprocess.run(
            [sys.executable, str(GUARD)],
            input=json.dumps(plan),
            text=True,
            capture_output=True,
            timeout=10,
            env={
                **os.environ,
                "PROTECTED_RESOURCE_TYPES": types,
                "PROTECTED_RESOURCE_ADDRESSES": ",".join(addresses),
            },
        )

    def test_project_delete_and_replacement_refused(self):
        for address in PROJECTS:
            for actions in (["delete"], ["delete", "create"], ["create", "delete"]):
                with self.subTest(address=address, actions=actions):
                    result = self.run_guard(address, "azapi_resource", actions)
                    self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                    self.assertIn(address, result.stderr)

    def test_project_update_allowed(self):
        self.assertEqual(self.run_guard(PROJECTS[0], "azapi_resource", ["update"]).returncode, 0)

    def test_flow_log_delete_allowed(self):
        result = self.run_guard("module.observability.azapi_resource.flow_log[0]", "azapi_resource", ["delete"])
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_type_protection_preserved(self):
        self.assertEqual(self.run_guard("module.storage.azurerm_storage_account.this", "azurerm_storage_account", ["delete"]).returncode, 1)

    def test_protected_type_forget_allowed(self):
        # A `removed { lifecycle { destroy = false } }` block plans as "forget": the
        # object leaves state and survives, so the guard must let it through.
        for address, resource_type in (
            ("module.storage.azurerm_storage_account.this", "azurerm_storage_account"),
            (PROJECTS[0], "azapi_resource"),
        ):
            with self.subTest(address=address):
                result = self.run_guard(address, resource_type, ["forget"])
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_retired_worker_destroys_allowed(self):
        # Core R-016: the plan that retires cna-worker destroys its Container App
        # and role assignments; none is a protected type, so the apply proceeds.
        types = "azurerm_log_analytics_workspace,azurerm_postgresql_flexible_server,azurerm_storage_account,azurerm_cognitive_account,azurerm_cognitive_deployment"
        for address, resource_type in (
            ("module.compute.azurerm_container_app.worker", "azurerm_container_app"),
            ("azurerm_role_assignment.worker_storage_blob_data_contributor", "azurerm_role_assignment"),
            ("azurerm_role_assignment.worker_foundry_user[0]", "azurerm_role_assignment"),
        ):
            with self.subTest(address=address):
                result = self.run_guard(address, resource_type, ["delete"], types=types)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_empty_configuration_refused(self):
        self.assertEqual(self.run_guard("anything", "anything", ["delete"], types="", addresses=()).returncode, 1)

    def test_address_only_configuration(self):
        self.assertEqual(self.run_guard(PROJECTS[0], "azapi_resource", ["delete"], types="").returncode, 1)

    def test_quoted_instance_keys_fail_closed(self):
        for address in ('module.data.azapi_resource.this["east,west"]', 'module.data.azapi_resource.this["east"]'):
            with self.subTest(address=address):
                result = self.run_guard(address, "azapi_resource", ["delete"], addresses=(address,))
                self.assertEqual(result.returncode, 1)
                self.assertIn("does not support quoted instance keys", result.stderr)


if __name__ == "__main__":
    unittest.main()
