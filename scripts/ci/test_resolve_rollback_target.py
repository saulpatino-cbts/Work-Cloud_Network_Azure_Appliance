"""Offline tests of resolve_rollback_target.py; no cloud, no workflow run."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


RESOLVER = Path(__file__).with_name("resolve_rollback_target.py")
CHECKS = (
    "terraform_apply",
    "post_deploy_probe",
    "independent_verification",
    "promotion_ready",
    "external_health_validation",
    "certificate_monitoring",
    "canary_telemetry",
    "staged_promotion",
    "certificate_rotation",
)


def ref(role, digit):
    return f"docker.io/example/cna:{role}-sha-{digit * 7}@sha256:{digit * 64}"


def record(run_id, digit, *, worker=False, approved=True):
    data = {
        "deploy_mode": "release",
        "approval_status": "approved" if approved else "pending",
        "health_status": "healthy",
        "workflow_run_id": str(run_id),
        "api_image": ref("api", digit),
        "web_image": ref("web", digit),
        "migrator_image": ref("migrator", digit),
        "validation_checks": {check: "passed" for check in CHECKS},
    }
    if worker:
        # A record written before the worker image was retired (core R-016).
        data["worker_image"] = ref("worker", digit)
    return data


class ResolveRollbackTargetTests(unittest.TestCase):
    def resolve(self, records):
        with tempfile.TemporaryDirectory() as directory:
            catalog = Path(directory) / "catalog"
            catalog.mkdir()
            for data in records:
                (catalog / f"{data['workflow_run_id']}.json").write_text(json.dumps(data), encoding="utf-8")
            env_file = Path(directory) / "github_env"
            env_file.write_text("", encoding="utf-8")
            result = subprocess.run(
                [sys.executable, str(RESOLVER)],
                capture_output=True,
                text=True,
                timeout=10,
                env={**os.environ, "CATALOG_DIR": str(catalog), "GITHUB_ENV": str(env_file)},
            )
            lines = env_file.read_text(encoding="utf-8").splitlines()
        return result, dict(line.split("=", 1) for line in lines)

    def test_newest_record_without_worker_is_resolved(self):
        result, env = self.resolve([record(100, "1", worker=True), record(200, "2")])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(
            env,
            {
                "EFFECTIVE_API_IMAGE": ref("api", "2"),
                "EFFECTIVE_WEB_IMAGE": ref("web", "2"),
                "EFFECTIVE_MIGRATOR_IMAGE": ref("migrator", "2"),
            },
        )

    def test_record_from_before_the_worker_retirement_is_still_a_target(self):
        result, env = self.resolve([record(300, "3", worker=True)])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(env["EFFECTIVE_API_IMAGE"], ref("api", "3"))
        self.assertEqual(env["EFFECTIVE_WEB_IMAGE"], ref("web", "3"))
        self.assertNotIn("EFFECTIVE_WORKER_IMAGE", env)
        self.assertNotIn("worker", result.stdout + result.stderr)

    def test_unapproved_records_are_skipped(self):
        result, env = self.resolve([record(400, "4"), record(500, "5", approved=False)])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(env["EFFECTIVE_API_IMAGE"], ref("api", "4"))

    def test_no_eligible_record_fails(self):
        result, env = self.resolve([record(600, "6", approved=False)])
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(env, {})


if __name__ == "__main__":
    unittest.main()
