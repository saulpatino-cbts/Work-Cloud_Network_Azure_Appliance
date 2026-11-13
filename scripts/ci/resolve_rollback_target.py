"""
Resolve the most recent promotion-ready release catalog entry for rollback.

Reads:
  CATALOG_DIR  — path to the deployment catalog directory
  GITHUB_ENV   — path to the GitHub Actions environment file (auto-set by runner)

Writes EFFECTIVE_API_IMAGE, EFFECTIVE_WEB_IMAGE and EFFECTIVE_MIGRATOR_IMAGE to
GITHUB_ENV. The values are whatever the catalog recorded (pinned references);
the workflow validates them before use.

Records written before the worker image was retired (core REVIEW.md R-016) also
carry a `worker_image` key. They stay valid rollback targets: the key is read
past and never emitted, because no deployment has a worker any more.
"""

import json
import os
import sys
from pathlib import Path

catalog_dir = Path(os.environ["CATALOG_DIR"])
github_env = Path(os.environ["GITHUB_ENV"])

records = []
for file in catalog_dir.glob("*.json"):
    if file.name in {"latest.json", "deployment-manifest.json"}:
        continue
    try:
        with file.open() as f:
            data = json.load(f)
        checks = data.get("validation_checks", {})
        if (
            data.get("deploy_mode") == "release"
            and data.get("approval_status") == "approved"
            and data.get("health_status") == "healthy"
            and checks.get("terraform_apply") == "passed"
            and checks.get("post_deploy_probe") == "passed"
            and checks.get("independent_verification") == "passed"
            and checks.get("promotion_ready") == "passed"
            and checks.get("external_health_validation") == "passed"
            and checks.get("certificate_monitoring") == "passed"
            and checks.get("canary_telemetry") == "passed"
            and checks.get("staged_promotion") == "passed"
            and checks.get("certificate_rotation") == "passed"
        ):
            records.append(data)
    except Exception:  # noqa: S112
        continue

records.sort(key=lambda r: int(r.get("workflow_run_id", 0)), reverse=True)

if not records:
    print(
        "::error::No monitored and promotion-ready release catalog entries found for rollback resolution",
        file=sys.stderr,
    )
    sys.exit(1)

selected = records[0]
print(f"Resolved rollback target: run_id={selected.get('workflow_run_id')}")
print(f"  api_image={selected['api_image']}")
print(f"  web_image={selected['web_image']}")
print(f"  migrator_image={selected.get('migrator_image', '')}")

with github_env.open("a") as env:
    env.write(f"EFFECTIVE_API_IMAGE={selected['api_image']}\n")
    env.write(f"EFFECTIVE_WEB_IMAGE={selected['web_image']}\n")
    env.write(f"EFFECTIVE_MIGRATOR_IMAGE={selected.get('migrator_image', '')}\n")
