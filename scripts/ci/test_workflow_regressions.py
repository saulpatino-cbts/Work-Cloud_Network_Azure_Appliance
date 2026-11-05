"""Offline tests of the workflow shell bodies and their safety assertions."""

import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import textwrap
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github" / "workflows"


class _NoDuplicateKeysLoader(yaml.SafeLoader):
    """SafeLoader that records a repeated mapping key instead of silently keeping the last."""

    duplicates: list

    def construct_mapping(self, node, deep=False):
        seen = set()
        for key_node, _ in node.value:
            key = self.construct_object(key_node, deep=True)
            if key in seen:
                self.duplicates.append((key, key_node.start_mark.line + 1))
            seen.add(key)
        return super().construct_mapping(node, deep)


def duplicate_keys(text):
    loader = _NoDuplicateKeysLoader(text)
    loader.duplicates = []
    try:
        loader.get_single_data()
    finally:
        loader.dispose()
    return loader.duplicates


class WorkflowRegressionTests(unittest.TestCase):
    def run_purge(self, *, status=0, accounts=""):
        workflow = (WORKFLOWS / "330-teardown.yml").read_text(encoding="utf-8")
        block = workflow.split("      - name: Wait for RG deletion, then purge\n        run: |\n", 1)[1]
        script = textwrap.dedent(block.split("\n  #", 1)[0]).replace(
            "${{ needs.terraform-destroy.outputs.workload_rg }}", "rg-synthetic"
        )
        self.assertNotIn("${{", script)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            az = path / "az"
            az.write_text(
                '#!/usr/bin/env bash\nset -euo pipefail\n'
                'case "$1 $2 $3" in\n'
                '  "group exists --name") printf false ;;\n'
                '  "cognitiveservices account list-deleted") printf "%s" "$MOCK_ACCOUNTS"; exit "$MOCK_STATUS" ;;\n'
                '  "cognitiveservices account purge") printf purge >> "$MOCK_CALLS" ;;\n'
                '  *) exit 99 ;;\nesac\n',
                encoding="utf-8",
            )
            az.chmod(0o755)
            calls = path / "calls"
            result = subprocess.run(
                ["bash", "-e", "-o", "pipefail", "-c", script],
                capture_output=True,
                text=True,
                timeout=10,
                env={
                    **os.environ,
                    "PATH": f"{path}{os.pathsep}{os.environ['PATH']}",
                    "MOCK_STATUS": str(status),
                    "MOCK_ACCOUNTS": accounts,
                    "MOCK_CALLS": str(calls),
                },
            )
            return result, calls.read_text() if calls.exists() else ""

    def test_purge_listing_failure_is_not_success(self):
        result, calls = self.run_purge(status=23)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unable to list", result.stdout)
        self.assertNotIn("No soft-deleted", result.stdout)
        self.assertEqual(calls, "")

    def test_purge_empty_listing_is_success(self):
        result, calls = self.run_purge()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("No soft-deleted", result.stdout)
        self.assertEqual(calls, "")

    def test_purge_successful_listing_is_processed(self):
        result, calls = self.run_purge(accounts="synthetic-account\twesteurope\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, "purge")

    def test_preflight_secret_punctuation_and_placeholder_rejection(self):
        workflow = (WORKFLOWS / "100-validate-prereqs.yml").read_text(encoding="utf-8")
        body = workflow.split("          check_secret() {", 1)[1].split("\n          }", 1)[0]
        function = "check_secret() {" + body + "\n}\n"
        with tempfile.TemporaryDirectory() as directory:
            for value, expected in (("synthetic<test>only", 0), ("PLACEHOLDER", 1), ("", 1)):
                with self.subTest(value=value):
                    result = subprocess.run(
                        ["bash", "-e", "-c", function + 'FAILED=0; check_secret fixture "$FIXTURE"; exit "$FAILED"'],
                        capture_output=True,
                        text=True,
                        timeout=10,
                        env={**os.environ, "FIXTURE": value, "GITHUB_STEP_SUMMARY": str(Path(directory) / "summary")},
                    )
                    self.assertEqual(result.returncode, expected, result.stderr)

    def test_workflow_files_have_no_duplicate_keys(self):
        # GitHub rejects a workflow whose mapping repeats a key: the whole file is
        # invalid, every push fails and the workflow cannot be dispatched.
        files = sorted(WORKFLOWS.glob("*.yml"))
        self.assertTrue(files)
        for path in files:
            with self.subTest(workflow=path.name):
                self.assertEqual(duplicate_keys(path.read_text(encoding="utf-8")), [])

    def test_duplicate_key_detector_catches_a_repeat(self):
        self.assertEqual(duplicate_keys("env:\n  A: 1\n  B: 2\n  A: 3\n"), [("A", 4)])
        self.assertEqual(duplicate_keys("env:\n  A: 1\n  B: 2\n"), [])

    def test_app_tokens_are_scoped_to_one_repository(self):
        # An unscoped App token spans every repository the App is installed on.
        # 230 deliberately targets the upstream core repository; every other
        # token must name its repository. Checked per step on the parsed `with:`.
        found = 0
        for path in sorted(WORKFLOWS.glob("*.yml")):
            workflow = yaml.safe_load(path.read_text(encoding="utf-8"))
            for job_name, job in (workflow.get("jobs") or {}).items():
                for step in job.get("steps") or []:
                    if not str(step.get("uses", "")).startswith("actions/create-github-app-token@"):
                        continue
                    found += 1
                    with self.subTest(workflow=path.name, job=job_name):
                        self.assertTrue(str((step.get("with") or {}).get("repositories", "")).strip())
        self.assertGreaterEqual(found, 3)

    def test_firewall_negative_assertion_detects_mutation(self):
        source = (ROOT / "scripts" / "ci" / "test_runner_firewall_window.sh").read_text(encoding="utf-8")
        source = source.replace(
            'ROOT="$(cd "$(dirname "$0")/../.." && pwd)"',
            f"ROOT={shlex.quote(str(ROOT))}",
            1,
        ).replace("absent 'operation Delete'", "absent ''", 1)
        with tempfile.TemporaryDirectory() as directory:
            script = Path(directory) / "mutation.sh"
            script.write_text(source, encoding="utf-8")
            result = subprocess.run(["bash", str(script)], capture_output=True, text=True, timeout=30)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Unexpected mocked operation matched", result.stderr)


if __name__ == "__main__":
    unittest.main()
