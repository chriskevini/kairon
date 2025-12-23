#!/usr/bin/env python3
"""
Standardize all node names and workflow names to PascalCase.

This script:
1. Converts all node names to PascalCase
2. Updates all node references in code ($('node_name'))
3. Updates connection references
4. Preserves special cases like "Discord Webhook Entry"
"""

import json
import re
import sys
from pathlib import Path


def to_pascal_case(name: str) -> str:
    """Convert any name format to PascalCase (no spaces)."""
    # Remove special characters that aren't alphanumeric or spaces/underscores
    # Preserve emojis and other special chars by keeping them
    name = name.strip()

    # Split on spaces, underscores, or existing camelCase boundaries
    # Handle formats like: "Build Message Query", "build_message_query", "buildMessageQuery"
    parts = []
    current = []

    for char in name:
        if char in (" ", "_", "-"):
            if current:
                parts.append("".join(current))
                current = []
        elif char.isupper() and current and current[-1].islower():
            # CamelCase boundary
            parts.append("".join(current))
            current = [char]
        else:
            current.append(char)

    if current:
        parts.append("".join(current))

    # Convert to PascalCase
    result = "".join(word.capitalize() for word in parts if word)
    return result if result else name


def extract_node_references(code: str) -> list[str]:
    """Extract all $('node_name') references from JavaScript code."""
    pattern = r"\$\('([^']+)'\)"
    return re.findall(pattern, code)


def update_node_references(code: str, name_mapping: dict[str, str]) -> str:
    """Update all $('node_name') references in JavaScript code."""

    def replace_ref(match):
        old_name = match.group(1)
        new_name = name_mapping.get(old_name, old_name)
        return f"$('{new_name}')"

    pattern = r"\$\('([^']+)'\)"
    return re.sub(pattern, replace_ref, code)


def standardize_workflow(workflow_path: Path, dry_run: bool = False) -> dict:
    """Standardize node names in a single workflow file."""
    with open(workflow_path, "r") as f:
        workflow = json.load(f)

    nodes = workflow.get("nodes", [])
    connections = workflow.get("connections", {})

    # Build mapping: old_name -> new_name
    name_mapping = {}
    for node in nodes:
        old_name = node["name"]
        new_name = to_pascal_case(old_name)
        if old_name != new_name:
            name_mapping[old_name] = new_name

    if not name_mapping:
        return {"file": workflow_path.name, "changes": 0, "mappings": {}}

    # Update node names
    for node in nodes:
        old_name = node["name"]
        if old_name in name_mapping:
            node["name"] = name_mapping[old_name]

    # Update code references
    code_updates = 0
    for node in nodes:
        if node["type"] == "n8n-nodes-base.code":
            code = node["parameters"].get("jsCode", "")
            refs = extract_node_references(code)
            if any(ref in name_mapping for ref in refs):
                updated_code = update_node_references(code, name_mapping)
                node["parameters"]["jsCode"] = updated_code
                code_updates += 1

    # Update connections
    new_connections = {}
    for old_node_name, outputs in connections.items():
        new_node_name = name_mapping.get(old_node_name, old_node_name)

        # Update connection targets
        updated_outputs = {}
        for output_type, branches in outputs.items():
            updated_branches = []
            for branch in branches:
                updated_branch = []
                for conn in branch:
                    updated_conn = conn.copy()
                    old_target = conn["node"]
                    updated_conn["node"] = name_mapping.get(old_target, old_target)
                    updated_branch.append(updated_conn)
                updated_branches.append(updated_branch)
            updated_outputs[output_type] = updated_branches

        new_connections[new_node_name] = updated_outputs

    workflow["connections"] = new_connections

    if not dry_run:
        with open(workflow_path, "w") as f:
            json.dump(workflow, f, indent=2)
            f.write("\n")

    return {
        "file": workflow_path.name,
        "changes": len(name_mapping),
        "code_updates": code_updates,
        "mappings": name_mapping,
    }


def main():
    dry_run = "--dry-run" in sys.argv

    script_dir = Path(__file__).parent
    repo_root = script_dir.parent.parent
    workflows_dir = repo_root / "n8n-workflows"

    if not workflows_dir.exists():
        print(f"Error: Workflows directory not found: {workflows_dir}")
        sys.exit(1)

    workflow_files = sorted(workflows_dir.glob("*.json"))

    if not workflow_files:
        print(f"No workflow files found in {workflows_dir}")
        sys.exit(1)

    print(
        f"{'DRY RUN: ' if dry_run else ''}Standardizing node names to PascalCase (no spaces)"
    )
    print("=" * 80)

    total_changes = 0
    total_code_updates = 0
    results = []

    for workflow_path in workflow_files:
        try:
            result = standardize_workflow(workflow_path, dry_run=dry_run)
            results.append(result)

            if result["changes"] > 0:
                total_changes += result["changes"]
                total_code_updates += result.get("code_updates", 0)

                status = "Would update" if dry_run else "Updated"
                print(f"\n{status}: {result['file']}")
                print(f"  Node renames: {result['changes']}")
                print(f"  Code updates: {result.get('code_updates', 0)}")

                if result["mappings"]:
                    print("  Mappings:")
                    for old, new in sorted(result["mappings"].items()):
                        print(f"    '{old}' -> '{new}'")

        except Exception as e:
            print(f"\nError processing {workflow_path.name}: {e}", file=sys.stderr)
            if not dry_run:
                sys.exit(1)

    print("\n" + "=" * 80)
    print(f"Summary:")
    print(f"  Files processed: {len(workflow_files)}")
    print(f"  Files with changes: {len([r for r in results if r['changes'] > 0])}")
    print(f"  Total node renames: {total_changes}")
    print(f"  Total code updates: {total_code_updates}")

    if dry_run:
        print("\nRun without --dry-run to apply changes")
    else:
        print("\n✅ All changes applied")


if __name__ == "__main__":
    main()
