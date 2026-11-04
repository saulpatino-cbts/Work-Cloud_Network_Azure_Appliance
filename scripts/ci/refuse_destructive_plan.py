"""
Refuse a Terraform plan that would destroy a resource holding irreplaceable data.

210-deploy runs this on each saved plan right before `terraform apply` (platform
and workload). A release must never delete or replace the log store or the
database: on Azure that is what a stale state layout would have done to the Log
Analytics workspace (TODO.md → T-103, "applying without migrating state first
makes workload destroy the workspace"), and no release has a reason to
destroy the database. If a plan does, the apply is refused and a human decides
— by fixing state (`terraform state rm` / `import`) or, knowingly, by removing
the type from the protected list for that one run.

Usage:
  terraform show -json tfplan | python3 refuse_destructive_plan.py
  python3 refuse_destructive_plan.py plan.json

Environment:
  PROTECTED_RESOURCE_TYPES  comma-separated Terraform resource types that must
                            never be deleted or replaced by this plan, e.g.
                            "azurerm_log_analytics_workspace,azurerm_postgresql_flexible_server"
                            or "aws_cloudwatch_log_group,aws_db_instance".
  PLAN_LABEL                optional name for messages (e.g. "dev/workload").
  PROTECTED_RESOURCE_ADDRESSES  optional comma-separated exact Terraform resource
                               addresses, independent of protected types.
                               Quoted instance keys are unsupported and refused.

Exit status is 0 when no protected resource is destroyed, 1 otherwise; output is
plain text so it reads well in a workflow log.
"""

from __future__ import annotations

import json
import os
import sys


def main() -> int:
    types = {t.strip() for t in os.environ.get("PROTECTED_RESOURCE_TYPES", "").split(",") if t.strip()}
    raw_addresses = os.environ.get("PROTECTED_RESOURCE_ADDRESSES", "")
    if '"' in raw_addresses:
        print("::error::PROTECTED_RESOURCE_ADDRESSES does not support quoted instance keys; use protected resource types.", file=sys.stderr)
        return 1
    addresses = {
        address.strip()
        for address in raw_addresses.split(",")
        if address.strip()
    }
    label = os.environ.get("PLAN_LABEL", "plan")
    if not types and not addresses:
        print(f"::error::No protected resource types or addresses configured for {label}.", file=sys.stderr)
        return 1

    if len(sys.argv) > 1:
        with open(sys.argv[1], encoding="utf-8") as f:
            plan = json.load(f)
    else:
        plan = json.load(sys.stdin)

    offending = []
    for change in plan.get("resource_changes") or []:
        actions = set((change.get("change") or {}).get("actions") or [])
        if "delete" in actions and (
            change.get("type") in types or change.get("address") in addresses
        ):
            kind = "replaced" if "create" in actions else "destroyed"
            offending.append((change.get("address", "?"), change.get("type"), kind))

    if offending:
        for address, rtype, kind in offending:
            print(
                f"::error::{label}: {address} ({rtype}) would be {kind}. "
                "This plan is refused — it would delete data a release must never delete. "
                "Fix the state (terraform state rm / import — see TODO.md) or knowingly lift the guard for one run.",
                file=sys.stderr,
            )
        return 1

    print(f"{label}: no protected resource ({', '.join(sorted(types | addresses))}) is destroyed or replaced.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
