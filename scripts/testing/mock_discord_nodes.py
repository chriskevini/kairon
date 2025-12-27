#!/usr/bin/env python3
"""
Replace Discord nodes in workflows with comment nodes for testing.
This allows testing workflows without valid Discord credentials.
"""

import json
import sys
from pathlib import Path


def main():
    if len(sys.argv) < 2:
        print("Usage: mock_discord_nodes.py <workflow.json>", file=sys.stderr)
        print(
            "Removes Discord nodes to enable testing without credentials.",
            file=sys.stderr,
        )
        sys.exit(1)

    input_file = Path(sys.argv[1])
    output_file = input_file.parent / f"{input_file.stem}.mock{input_file.suffix}"

    with open(input_file) as f:
        workflow = json.load(f)

    # Remove Discord nodes (they block execution)
    original_nodes = []
    removed_count = 0
    for node in workflow["nodes"]:
        node_type = node.get("type", "")
        node_name = node.get("name", "")

        if "discord" in node_type.lower():
            # Remove Discord node entirely
            print(f"  Removed Discord node: {node_name}")
            removed_count += 1
        else:
            # Keep non-Discord nodes
            original_nodes.append(node)

    if removed_count == 0:
        print("  No Discord nodes found")
        sys.exit(0)

    # Create new workflow with Discord nodes removed
    workflow["nodes"] = original_nodes

    with open(output_file, "w") as f:
        json.dump(workflow, f, indent=2)

    print(f"✓ Created workflow: {output_file}")
    print(f"  Removed {removed_count} Discord nodes")


if __name__ == "__main__":
    main()
