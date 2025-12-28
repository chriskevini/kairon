#!/usr/bin/env python3
"""
workflow_integrity.py - Comprehensive workflow integrity validation

This script catches issues that were missed in PRs #118-122:
1. Dead code (nodes unreachable from triggers)
2. Misconfigured nodes (empty triggers, wrong modes)
3. Broken Execute Workflow references
4. Invalid node configurations

This is the DEFINITIVE validation gate to prevent broken workflows
from entering production.

Usage:
    ./workflow_integrity.py                    # Validate all workflows
    ./workflow_integrity.py workflow.json      # Validate specific workflow
    ./workflow_integrity.py --strict           # Fail on warnings too
    ./workflow_integrity.py --fix              # Auto-fix some issues (removes dead code)

Exit codes:
    0 - All checks passed
    1 - Errors found (blocks deployment)
    2 - Warnings only (deployment allowed but should be reviewed)
"""

import json
import sys
import os
import re
from pathlib import Path
from collections import deque
from typing import Dict, List, Set, Any, Optional, Tuple
from dataclasses import dataclass, field


# ANSI colors
RED = "\033[0;31m"
YELLOW = "\033[0;33m"
GREEN = "\033[0;32m"
BLUE = "\033[0;34m"
CYAN = "\033[0;36m"
NC = "\033[0m"  # No Color


@dataclass
class ValidationResult:
    """Result of validating a single workflow"""

    workflow_name: str
    filepath: str
    errors: List[str] = field(default_factory=list)
    warnings: List[str] = field(default_factory=list)
    info: List[str] = field(default_factory=list)
    dead_nodes: Set[str] = field(default_factory=set)

    @property
    def passed(self) -> bool:
        return len(self.errors) == 0

    @property
    def has_warnings(self) -> bool:
        return len(self.warnings) > 0


class WorkflowIntegrityValidator:
    """
    Comprehensive workflow validator that catches:
    1. Dead code (unreachable nodes)
    2. Misconfigured nodes
    3. Broken references
    4. Invalid configurations
    """

    def __init__(self, workflow_dir: str = "n8n-workflows"):
        self.workflow_dir = Path(workflow_dir)
        # Cache workflow names for cross-workflow validation
        self._workflow_names: Set[str] = set()
        self._load_workflow_names()

    def _load_workflow_names(self):
        """Load all workflow names for reference validation"""
        for filepath in self.workflow_dir.glob("*.json"):
            try:
                with open(filepath) as f:
                    wf = json.load(f)
                    name = wf.get("name", filepath.stem)
                    self._workflow_names.add(name)
            except (json.JSONDecodeError, IOError):
                pass

    def get_node_type(self, node: dict) -> str:
        """Extract simplified node type"""
        full_type = node.get("type", "")
        return full_type.split(".")[-1] if "." in full_type else full_type

    def find_dead_code(self, workflow: dict) -> Tuple[Set[str], List[str]]:
        """
        Find nodes unreachable from any trigger node.

        Returns:
            (dead_nodes, trigger_names)
        """
        nodes = {n["name"]: n for n in workflow.get("nodes", [])}
        connections = workflow.get("connections", {})

        # Build forward adjacency list
        graph: Dict[str, List[str]] = {name: [] for name in nodes}
        for src, outputs in connections.items():
            for output_type, output_list in outputs.items():
                for output in output_list:
                    for conn in output:
                        target = conn.get("node")
                        if target and src in graph:
                            graph[src].append(target)

        # Find all trigger nodes (includes webhooks, manual triggers, crons, etc.)
        # Note: executeWorkflowTrigger means this workflow is called by another workflow
        trigger_keywords = ["Trigger", "webhook"]
        triggers = [
            name
            for name, node in nodes.items()
            if any(kw in node.get("type", "") for kw in trigger_keywords)
        ]

        # BFS from all triggers to find reachable nodes
        reachable: Set[str] = set()
        queue = deque(triggers)
        while queue:
            node = queue.popleft()
            if node in reachable:
                continue
            reachable.add(node)
            for neighbor in graph.get(node, []):
                if neighbor not in reachable:
                    queue.append(neighbor)

        # Dead code = nodes not reachable from any trigger
        dead = set(nodes.keys()) - reachable

        # SPECIAL CASE: AI model subnodes
        # AI chain nodes (chainLlm, agentExecutor, etc.) require AI model subnodes
        # (lmChatOpenRouter, lmChatOpenAi, etc.) but these connections aren't in the
        # connections object. Mark AI model nodes as reachable if ANY AI chain is reachable.
        ai_chain_types = ["chainLlm", "agentExecutor", "chainRetrievalQa"]
        ai_model_types = [
            "lmChatOpenRouter",
            "lmChatOpenAi",
            "lmChatAnthropic",
            "lmChatMistral",
        ]

        # Check if any reachable node is an AI chain
        has_reachable_ai_chain = any(
            any(
                chain_type in nodes[name].get("type", "")
                for chain_type in ai_chain_types
            )
            for name in reachable
        )

        if has_reachable_ai_chain:
            # Mark all AI model nodes as reachable (they're subnodes of chains)
            ai_models = {
                name
                for name, node in nodes.items()
                if any(
                    model_type in node.get("type", "") for model_type in ai_model_types
                )
            }
            dead = dead - ai_models

        return dead, triggers

    def check_empty_trigger(self, node: dict) -> Optional[str]:
        """Check for empty executeWorkflowTrigger nodes"""
        node_type = node.get("type", "")
        if "executeWorkflowTrigger" in node_type:
            params = node.get("parameters", {})
            if not params:
                return f"executeWorkflowTrigger '{node.get('name')}' has empty parameters (n8n will show validation error)"
        return None

    def check_execute_workflow_config(self, node: dict, workflow: dict) -> List[str]:
        """Check Execute Workflow node configuration"""
        issues = []
        node_name = node.get("name", "Unknown")
        params = node.get("parameters", {})

        workflow_id = params.get("workflowId", {})

        if not workflow_id:
            issues.append(
                f"'{node_name}': Execute Workflow missing workflowId configuration"
            )
            return issues

        mode = workflow_id.get("mode")
        if mode != "list":
            issues.append(
                f"'{node_name}': Execute Workflow using mode '{mode}' instead of 'list' (not portable)"
            )

        # Check if referenced workflow exists
        cached_name = workflow_id.get("cachedResultName")
        if cached_name and cached_name not in self._workflow_names:
            issues.append(
                f"'{node_name}': References workflow '{cached_name}' which does not exist"
            )

        return issues

    def check_switch_node_config(self, node: dict) -> List[str]:
        """Check Switch node configuration for n8n v3 compatibility"""
        issues = []
        node_name = node.get("name", "Unknown")
        type_version = node.get("typeVersion", 1)
        params = node.get("parameters", {})
        options = params.get("options", {})
        fallback = options.get("fallbackOutput")

        # n8n v3 Switch nodes require specific fallback values
        if type_version >= 3 and fallback is not None:
            if not isinstance(fallback, str):
                issues.append(
                    f"'{node_name}': Switch node fallbackOutput must be string ('extra' or 'none'), got: {type(fallback).__name__}"
                )
            elif fallback not in ["extra", "none"]:
                issues.append(
                    f"'{node_name}': Switch node fallbackOutput invalid value: '{fallback}'"
                )

        return issues

    def check_code_node_return(self, node: dict) -> List[str]:
        """Check Code node return statements for common issues"""
        issues = []
        node_name = node.get("name", "Unknown")
        params = node.get("parameters", {})
        mode = params.get("mode", "runOnceForAllItems")
        code = params.get("jsCode", "")

        if not code:
            return issues

        # Check for array returns in runOnceForEachItem mode
        if mode == "runOnceForEachItem":
            # Look for return [{...}] which should be return {...}
            if re.search(r"return\s+\[\s*\{", code) and "return [{json:" not in code:
                # But allow return [...items] for legitimate cases
                if not re.search(r"return\s+\[\s*\.\.\.|\.\.\.\$input", code):
                    issues.append(
                        f"'{node_name}': Code in runOnceForEachItem mode returns array - should return single object"
                    )

        return issues

    def check_postgres_query_params(self, node: dict) -> List[str]:
        """Check Postgres node query parameter alignment"""
        # This check is disabled for now - many workflows use Execute_Queries pattern
        # where parameters are passed via the data flow, not via queryReplacement
        # TODO: Enable when we can detect if node is part of Execute_Queries pattern
        return []

    def check_merge_node_config(self, node: dict) -> List[str]:
        """Check Merge node has required parameters"""
        issues = []
        node_name = node.get("name", "Unknown")
        params = node.get("parameters", {})

        if not params:
            issues.append(
                f"'{node_name}': Merge node has empty parameters (needs mode configuration)"
            )
        elif "mode" not in params:
            issues.append(f"'{node_name}': Merge node missing 'mode' parameter")

        return issues

    def validate_workflow(self, filepath: str) -> ValidationResult:
        """Validate a single workflow file"""
        result = ValidationResult(workflow_name="Unknown", filepath=filepath)

        try:
            with open(filepath) as f:
                workflow = json.load(f)
        except json.JSONDecodeError as e:
            result.errors.append(f"Invalid JSON: {e}")
            return result
        except IOError as e:
            result.errors.append(f"Cannot read file: {e}")
            return result

        result.workflow_name = workflow.get("name", Path(filepath).stem)

        # Skip archived workflows
        if workflow.get("isArchived", False):
            result.info.append("Workflow is archived - skipping validation")
            return result

        nodes = workflow.get("nodes", [])

        # === Check 1: Dead Code Detection ===
        dead_nodes, triggers = self.find_dead_code(workflow)
        if dead_nodes:
            result.dead_nodes = dead_nodes
            result.errors.append(
                f"DEAD CODE: {len(dead_nodes)} node(s) unreachable from triggers: {', '.join(sorted(dead_nodes))}"
            )

        if not triggers:
            result.warnings.append("No trigger nodes found in workflow")

        # === Check 2: Per-Node Validation ===
        for node in nodes:
            node_type = self.get_node_type(node)

            # Check empty executeWorkflowTrigger
            empty_trigger_issue = self.check_empty_trigger(node)
            if empty_trigger_issue:
                result.warnings.append(empty_trigger_issue)

            # Check Execute Workflow configuration
            if node_type == "executeWorkflow":
                issues = self.check_execute_workflow_config(node, workflow)
                result.errors.extend(issues)

            # Check Switch node configuration
            if node_type == "switch":
                issues = self.check_switch_node_config(node)
                result.errors.extend(issues)

            # Check Code node return format
            if node_type == "code":
                issues = self.check_code_node_return(node)
                result.warnings.extend(issues)

            # Check Postgres query parameters
            if node_type == "postgres":
                issues = self.check_postgres_query_params(node)
                result.warnings.extend(issues)

            # Check Merge node configuration
            if node_type == "merge":
                issues = self.check_merge_node_config(node)
                result.warnings.extend(issues)

        # === Check 3: Connection Integrity ===
        connections = workflow.get("connections", {})
        node_names = {n["name"] for n in nodes}

        for src, outputs in connections.items():
            if src not in node_names:
                result.errors.append(f"Connection from non-existent node: '{src}'")

            for output_type, output_list in outputs.items():
                for output in output_list:
                    for conn in output:
                        target = conn.get("node")
                        if target and target not in node_names:
                            result.errors.append(
                                f"Connection to non-existent node: '{src}' -> '{target}'"
                            )

        # Add success message if no issues
        if result.passed and not result.has_warnings:
            result.info.append(f"All {len(nodes)} nodes validated successfully")

        return result

    def fix_workflow(self, filepath: str, result: ValidationResult) -> bool:
        """
        Auto-fix workflow issues by removing dead code.

        Returns True if changes were made.
        """
        if not result.dead_nodes:
            return False

        try:
            with open(filepath) as f:
                workflow = json.load(f)
        except (json.JSONDecodeError, IOError):
            return False

        # Remove dead nodes
        original_count = len(workflow.get("nodes", []))
        workflow["nodes"] = [
            n
            for n in workflow.get("nodes", [])
            if n.get("name") not in result.dead_nodes
        ]

        # Remove connections from/to dead nodes
        new_connections = {}
        for src, outputs in workflow.get("connections", {}).items():
            if src in result.dead_nodes:
                continue

            new_outputs = {}
            for output_type, output_list in outputs.items():
                new_output_list = []
                for output in output_list:
                    new_output = [
                        conn
                        for conn in output
                        if conn.get("node") not in result.dead_nodes
                    ]
                    new_output_list.append(new_output)
                new_outputs[output_type] = new_output_list
            new_connections[src] = new_outputs

        workflow["connections"] = new_connections

        # Write back
        with open(filepath, "w") as f:
            json.dump(workflow, f, indent=2)

        return True

    def validate_all(
        self, strict: bool = False, fix: bool = False
    ) -> Tuple[int, int, int]:
        """
        Validate all workflows in the workflow directory.

        Returns:
            (total_workflows, errors, warnings)
        """
        workflow_files = list(self.workflow_dir.glob("*.json"))

        # Exclude test files
        workflow_files = [f for f in workflow_files if "/tests/" not in str(f)]

        total_errors = 0
        total_warnings = 0
        results = []

        for filepath in sorted(workflow_files):
            result = self.validate_workflow(str(filepath))
            results.append(result)

            if result.errors:
                total_errors += len(result.errors)
            if result.warnings:
                total_warnings += len(result.warnings)

            # Auto-fix if requested
            if fix and result.dead_nodes:
                if self.fix_workflow(str(filepath), result):
                    print(
                        f"{YELLOW}Fixed:{NC} {filepath.name} - Removed {len(result.dead_nodes)} dead nodes"
                    )

        # Print results
        print(f"\n{CYAN}{'=' * 60}{NC}")
        print(f"Workflow Integrity Validation")
        print(f"{CYAN}{'=' * 60}{NC}\n")

        for result in results:
            if result.errors:
                status = f"{RED}FAIL{NC}"
            elif result.warnings:
                status = f"{YELLOW}WARN{NC}"
            else:
                status = f"{GREEN}PASS{NC}"

            print(f"[{status}] {result.workflow_name}")

            for error in result.errors:
                print(f"      {RED}ERROR:{NC} {error}")

            for warning in result.warnings:
                print(f"      {YELLOW}WARN:{NC} {warning}")

        # Summary
        print(f"\n{CYAN}{'=' * 60}{NC}")
        print(f"Summary: {len(workflow_files)} workflows")
        print(f"  Errors: {RED if total_errors else GREEN}{total_errors}{NC}")
        print(f"  Warnings: {YELLOW if total_warnings else GREEN}{total_warnings}{NC}")
        print(f"{CYAN}{'=' * 60}{NC}\n")

        return len(workflow_files), total_errors, total_warnings


def main():
    import argparse

    parser = argparse.ArgumentParser(
        description="Workflow integrity validation - prevents dead code and misconfigured nodes"
    )
    parser.add_argument(
        "workflow", nargs="?", help="Specific workflow file to validate"
    )
    parser.add_argument("--strict", action="store_true", help="Fail on warnings too")
    parser.add_argument(
        "--fix", action="store_true", help="Auto-fix by removing dead code"
    )
    parser.add_argument(
        "--workflow-dir", default="n8n-workflows", help="Workflow directory"
    )
    parser.add_argument("--quiet", "-q", action="store_true", help="Only show errors")

    args = parser.parse_args()

    validator = WorkflowIntegrityValidator(args.workflow_dir)

    if args.workflow:
        # Validate single workflow
        result = validator.validate_workflow(args.workflow)

        if not args.quiet:
            print(f"\n{CYAN}Validating: {result.workflow_name}{NC}\n")

        if result.errors:
            for error in result.errors:
                print(f"{RED}ERROR:{NC} {error}")

        if result.warnings and not args.quiet:
            for warning in result.warnings:
                print(f"{YELLOW}WARN:{NC} {warning}")

        if result.passed and not args.quiet:
            print(f"{GREEN}PASS:{NC} All checks passed")

        # Auto-fix if requested
        if args.fix and result.dead_nodes:
            if validator.fix_workflow(args.workflow, result):
                print(
                    f"\n{YELLOW}Fixed:{NC} Removed {len(result.dead_nodes)} dead nodes"
                )

        if result.errors:
            sys.exit(1)
        elif args.strict and result.warnings:
            sys.exit(2)
        else:
            sys.exit(0)
    else:
        # Validate all workflows
        total, errors, warnings = validator.validate_all(
            strict=args.strict, fix=args.fix
        )

        if errors > 0:
            sys.exit(1)
        elif args.strict and warnings > 0:
            sys.exit(2)
        else:
            sys.exit(0)


if __name__ == "__main__":
    main()
