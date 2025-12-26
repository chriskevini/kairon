#!/usr/bin/env python3
"""
Integration test for mode:list workflow references.

Tests that workflows using mode:list with cachedResultName work correctly
and can be deployed to dev/prod environments without modification.
"""

import json
import os
import subprocess
import sys


def check_mode_list_workflow(workflow_file):
    """Check if a workflow uses mode:list for Execute Workflow nodes."""
    with open(workflow_file, "r") as f:
        workflow = json.load(f)

    workflow_name = workflow.get("name", "Unknown")
    issues = []

    # Check all Execute Workflow nodes
    for node in workflow.get("nodes", []):
        if node.get("type") == "n8n-nodes-base.executeWorkflow":
            params = node.get("parameters", {})
            workflow_id = params.get("workflowId", {})

            mode = workflow_id.get("mode", "")
            cached_name = workflow_id.get("cachedResultName", "")

            # mode:list must have cachedResultName
            if mode == "list":
                if not cached_name:
                    issues.append(
                        f"Execute Workflow node '{node.get('name')}' uses mode:list "
                        f"but missing cachedResultName"
                    )
            # mode:id is discouraged for portability
            elif mode == "id":
                issues.append(
                    f"Execute Workflow node '{node.get('name')}' uses mode:id "
                    f"(portability issue - should use mode:list)"
                )

    return workflow_name, issues


def main():
    workflow_dir = sys.argv[1] if len(sys.argv) > 1 else "n8n-workflows"

    if not os.path.isdir(workflow_dir):
        print(f"Error: Directory '{workflow_dir}' not found")
        sys.exit(1)

    total_workflows = 0
    total_issues = 0
    workflows_with_issues = []

    print(f"Checking workflows in: {workflow_dir}")
    print("=" * 60)

    for filename in sorted(os.listdir(workflow_dir)):
        if not filename.endswith(".json"):
            continue

        workflow_file = os.path.join(workflow_dir, filename)
        workflow_name, issues = check_mode_list_workflow(workflow_file)

        total_workflows += 1

        if issues:
            total_issues += len(issues)
            workflows_with_issues.append(workflow_name)
            print(f"\n{workflow_name}:")
            for issue in issues:
                print(f"  ❌ {issue}")

    print("=" * 60)
    print(f"\nTotal workflows: {total_workflows}")
    print(f"Workflows with issues: {len(workflows_with_issues)}")
    print(f"Total issues: {total_issues}")

    if workflows_with_issues:
        print(f"\nWorkflows needing attention:")
        for w in sorted(workflows_with_issues):
            print(f"  - {w}")
        sys.exit(1)
    else:
        print("\n✅ All workflows use portable mode:list references")
        sys.exit(0)


if __name__ == "__main__":
    main()
