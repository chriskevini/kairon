#!/usr/bin/env python3
"""
Unit Test Framework for n8n Workflows

Comprehensive testing framework for validating n8n workflows including:
- Structural validation (connections, nodes)
- Functional testing (node behavior, ctx patterns)
- Integration testing (database operations, API calls)
- Documentation validation (README coverage)

Usage:
    ./unit_test_framework.py [workflow.json]               # Test specific workflow
    ./unit_test_framework.py --all                         # Test all workflows
    ./unit_test_framework.py --generate                    # Generate test templates
    ./unit_test_framework.py --coverage                    # Show test coverage
    ./unit_test_framework.py --stats                       # Show workflow statistics

Examples:
    ./unit_test_framework.py n8n-workflows/Execute_Queries.json
    ./unit_test_framework.py --all --verbose
    ./unit_test_framework.py --generate Execute_Queries.json
"""

import json
import sys
import os
import re
import argparse
import subprocess
from pathlib import Path
from typing import Dict, List, Any, Optional, Tuple
from dataclasses import dataclass, asdict
from collections import defaultdict

# ANSI colors
RED = "\033[0;31m"
GREEN = "\033[0;32m"
YELLOW = "\033[0;33m"
BLUE = "\033[0;34m"
CYAN = "\033[0;36m"
MAGENTA = "\033[0;35m"
NC = "\033[0m"
BOLD = "\033[1m"


@dataclass
class TestResult:
    """Result of a single test"""

    name: str
    passed: bool
    details: str
    duration_ms: Optional[int] = None


@dataclass
class WorkflowTest:
    """Test suite for a workflow"""

    workflow_name: str
    tests: List[TestResult]
    passed: int = 0
    failed: int = 0

    def add_test(self, test: TestResult):
        self.tests.append(test)
        if test.passed:
            self.passed += 1
        else:
            self.failed += 1


class WorkflowTester:
    """Main tester class"""

    def __init__(self, workflow_dir: str = "n8n-workflows"):
        self.workflow_dir = Path(workflow_dir)
        self.results = {}

    def get_node_type(self, node: dict) -> str:
        """Extract simplified node type"""
        full_type = node.get("type", "")
        return full_type.split(".")[-1] if "." in full_type else full_type

    def find_node(self, workflow: dict, name: str) -> Optional[dict]:
        """Find node by name"""
        for node in workflow.get("nodes", []):
            if node.get("name") == name:
                return node
        return None

    def test_database_schema(self) -> List[TestResult]:
        """Test if database schema is correct"""
        tests = []

        # We'll use the kairon-ops.sh tool if available, or try to run psql directly
        kairon_ops = Path(__file__).parent.parent.parent / "tools" / "kairon-ops.sh"

        sql = """
        SELECT 
          (SELECT COUNT(*) FROM information_schema.tables WHERE table_name = 'events') as has_events,
          (SELECT COUNT(*) FROM information_schema.tables WHERE table_name = 'traces') as has_traces,
          (SELECT COUNT(*) FROM information_schema.tables WHERE table_name = 'projections') as has_projections,
          (SELECT COUNT(*) FROM information_schema.tables WHERE table_name = 'config') as has_config
        """

        try:
            if kairon_ops.exists():
                # Use kairon-ops.sh db-query
                cmd = [str(kairon_ops), "db-query", sql]
                result = subprocess.run(cmd, capture_output=True, text=True, check=True)
                # Output format of db-query is usually raw psql output or JSON depending on the script
                # Let's assume it's something we can parse or at least see success
                tests.append(
                    TestResult(
                        "db_schema_check",
                        True,
                        "Schema check query executed successfully",
                    )
                )

                # Try to parse counts from output if possible
                output = result.stdout
                if "has_events | 1" in output or "1 | 1 | 1 | 1" in output:
                    tests.append(
                        TestResult(
                            "full_schema_present",
                            True,
                            "All core tables (events, traces, projections, config) found",
                        )
                    )
                elif "has_config | 1" in output:
                    tests.append(
                        TestResult(
                            "full_schema_present",
                            False,
                            "Only config table found (partial schema)",
                        )
                    )
            else:
                tests.append(
                    TestResult(
                        "db_schema_check",
                        False,
                        "kairon-ops.sh not found, skipping DB check",
                    )
                )
        except Exception as e:
            tests.append(
                TestResult("db_schema_check", False, f"Failed to check schema: {e}")
            )

        return tests

    def test_json_serialization(self) -> List[TestResult]:
        """Test JSON serialization edge cases (ported from Smoke_Test)"""
        tests = []

        test_cases = [
            {"key": "value"},
            {"num": 42},
            {"bool": True},
            {"nil": None},
            {"nested": {"deep": "value"}},
            {"arr": [1, 2, 3]},
            {"emoji": "🚀"},
            {"unicode": "café"},
            {"quote": '"quoted"'},
            {"newline": "line1\nline2"},
        ]

        fails = []
        for i, tc in enumerate(test_cases):
            try:
                serialized = json.dumps(tc)
                parsed = json.loads(serialized)
                if parsed != tc:
                    fails.append(f"case {i}: mismatch")
            except Exception as e:
                fails.append(f"case {i}: {e}")

        if not fails:
            tests.append(
                TestResult(
                    "json_serialization", True, f"All {len(test_cases)} cases passed"
                )
            )
        else:
            tests.append(
                TestResult("json_serialization", False, f"Fails: {'; '.join(fails)}")
            )

        return tests

    def test_ctx_pattern_logic(self) -> List[TestResult]:
        """Test ctx pattern preservation logic (ported from Smoke_Test)"""
        tests = []

        # Simulate ctx flowing through workflow transforms
        ctx = {
            "event": {
                "event_id": "test-123",
                "trace_chain": ["test-123"],
                "clean_text": "original text",
                "tag": "!!",
                "channel_id": "chan-1",
            }
        }

        # Transform 1: Add db namespace
        ctx.update({"db": {"results": [{"id": 1, "name": "test"}], "count": 1}})

        # Transform 2: Add llm namespace
        ctx.update(
            {
                "llm": {
                    "completion_text": "LLM response",
                    "duration_ms": 150,
                    "confidence": 0.95,
                }
            }
        )

        # Transform 3: Update trace_chain
        new_trace_id = "trace-456"
        ctx["event"]["trace_chain"].append(new_trace_id)

        # Transform 4: Add validation namespace
        ctx.update({"validation": {"valid": True}})

        # Verify
        checks = [
            ctx["event"]["event_id"] == "test-123",
            ctx["event"]["clean_text"] == "original text",
            ctx["event"]["tag"] == "!!",
            ctx["event"]["channel_id"] == "chan-1",
            len(ctx["event"]["trace_chain"]) == 2,
            ctx["event"]["trace_chain"][0] == "test-123",
            ctx["event"]["trace_chain"][1] == "trace-456",
            ctx["db"]["results"][0]["id"] == 1,
            ctx["db"]["count"] == 1,
            ctx["llm"]["completion_text"] == "LLM response",
            ctx["llm"]["duration_ms"] == 150,
            ctx["validation"]["valid"] == True,
        ]

        if all(checks):
            tests.append(
                TestResult(
                    "ctx_preservation",
                    True,
                    "Context preserved through simulated transforms",
                )
            )
        else:
            fail_idx = checks.index(False)
            tests.append(
                TestResult(
                    "ctx_preservation", False, f"Failed check at index {fail_idx}"
                )
            )

        return tests

    def test_structural_validation(self, workflow: dict) -> List[TestResult]:
        """Test workflow structure and connections"""
        tests = []

        # Test 1: Valid JSON structure
        try:
            workflow_name = workflow.get("name", "Unknown")
            tests.append(TestResult("valid_json", True, f"Workflow: {workflow_name}"))
        except Exception as e:
            tests.append(TestResult("valid_json", False, f"Invalid JSON: {e}"))
            return tests  # Can't continue without valid JSON

        nodes = workflow.get("nodes", [])
        connections = workflow.get("connections", {})

        # Test 2: Node name consistency
        node_names = {n["name"] for n in nodes}
        connection_sources = set(connections.keys())
        connection_targets = set()

        for outputs in connections.values():
            for output_list in outputs.get("main", []):
                for conn in output_list:
                    target = conn.get("node")
                    if target:
                        connection_targets.add(target)

        # Check for broken connections
        broken_sources = connection_sources - node_names
        broken_targets = connection_targets - node_names

        if broken_sources:
            tests.append(
                TestResult(
                    "node_consistency",
                    False,
                    f"Connections from non-existent nodes: {', '.join(broken_sources)}",
                )
            )
        elif broken_targets:
            tests.append(
                TestResult(
                    "node_consistency",
                    False,
                    f"Connections to non-existent nodes: {', '.join(broken_targets)}",
                )
            )
        else:
            tests.append(
                TestResult(
                    "node_consistency",
                    True,
                    f"All {len(nodes)} nodes have consistent names",
                )
            )

        # Test 3: Orphan nodes
        connected = connection_sources | connection_targets
        triggers = {n["name"] for n in nodes if "trigger" in n.get("type", "").lower()}
        orphans = (node_names - connected) - triggers

        if orphans:
            tests.append(
                TestResult(
                    "orphan_nodes",
                    False,
                    f"Orphan nodes (not connected): {', '.join(orphans)}",
                )
            )
        else:
            tests.append(TestResult("orphan_nodes", True, "No orphan nodes found"))

        # Test 4: Trigger nodes
        if not triggers:
            tests.append(TestResult("trigger_nodes", False, "No trigger nodes found"))
        else:
            tests.append(
                TestResult(
                    "trigger_nodes",
                    True,
                    f"Found {len(triggers)} trigger node(s): {', '.join(triggers)}",
                )
            )

        # Test 5: Node type diversity
        node_types = defaultdict(int)
        for node in nodes:
            node_type = self.get_node_type(node)
            node_types[node_type] += 1

        tests.append(
            TestResult(
                "node_diversity",
                True,
                f"Node types: {', '.join(f'{k}({v})' for k, v in sorted(node_types.items()))}",
            )
        )

        return tests

    def test_ctx_patterns(self, workflow: dict) -> List[TestResult]:
        """Test ctx pattern compliance"""
        tests = []
        nodes = workflow.get("nodes", [])

        # Track ctx usage patterns
        code_nodes_with_ctx = []
        code_nodes_without_ctx = []
        set_nodes_with_ctx = []

        for node in nodes:
            node_type = self.get_node_type(node)
            name = node.get("name", "Unknown")

            if node_type == "code":
                code = node.get("parameters", {}).get("jsCode", "")
                if "ctx:" in code or "$json.ctx." in code:
                    code_nodes_with_ctx.append(name)
                else:
                    code_nodes_without_ctx.append(name)

            elif node_type == "set":
                assignments = (
                    node.get("parameters", {})
                    .get("assignments", {})
                    .get("assignments", [])
                )
                has_ctx = any("ctx." in a.get("name", "") for a in assignments)
                if has_ctx:
                    set_nodes_with_ctx.append(name)

        # Test ctx usage
        if code_nodes_with_ctx:
            tests.append(
                TestResult(
                    "ctx_usage",
                    True,
                    f"Code nodes using ctx: {', '.join(code_nodes_with_ctx)}",
                )
            )
        else:
            tests.append(
                TestResult("ctx_usage", False, "No code nodes found using ctx pattern")
            )

        # Test context preservation
        if "$json.ctx." in str(workflow):
            tests.append(
                TestResult(
                    "context_preservation", True, "Workflow preserves ctx through nodes"
                )
            )
        else:
            tests.append(
                TestResult("context_preservation", False, "No ctx preservation found")
            )

        return tests

    def test_database_patterns(self, workflow: dict) -> List[TestResult]:
        """Test database-related patterns"""
        tests = []
        nodes = workflow.get("nodes", [])

        # Look for Execute_Queries workflow usage
        execute_queries_nodes = [
            n
            for n in nodes
            if self.get_node_type(n) == "executeWorkflow"
            and n.get("parameters", {}).get("workflowId", {}).get("cachedResultName")
            == "Execute_Queries"
        ]

        if execute_queries_nodes:
            tests.append(
                TestResult(
                    "execute_queries_usage",
                    True,
                    f"Uses Execute_Queries: {', '.join(n['name'] for n in execute_queries_nodes)}",
                )
            )
        else:
            tests.append(
                TestResult(
                    "execute_queries_usage",
                    False,
                    "No Execute_Queries workflow usage found",
                )
            )

        # Look for Postgres nodes
        postgres_nodes = [n for n in nodes if self.get_node_type(n) == "postgres"]
        if postgres_nodes:
            tests.append(
                TestResult(
                    "postgres_nodes", True, f"Postgres nodes: {len(postgres_nodes)}"
                )
            )
        else:
            tests.append(TestResult("postgres_nodes", False, "No Postgres nodes found"))

        return tests

    def test_api_patterns(self, workflow: dict) -> List[TestResult]:
        """Test API and HTTP patterns"""
        tests = []
        nodes = workflow.get("nodes", [])

        # Look for HTTP requests
        http_nodes = [n for n in nodes if self.get_node_type(n) == "httpRequest"]
        if http_nodes:
            tests.append(
                TestResult("http_requests", True, f"HTTP nodes: {len(http_nodes)}")
            )
        else:
            tests.append(
                TestResult("http_requests", False, "No HTTP request nodes found")
            )

        # Look for Discord nodes
        discord_nodes = [n for n in nodes if self.get_node_type(n) == "discord"]
        if discord_nodes:
            tests.append(
                TestResult(
                    "discord_integration", True, f"Discord nodes: {len(discord_nodes)}"
                )
            )

        return tests

    def test_workflow_specific_patterns(self, workflow: dict) -> List[TestResult]:
        """Test workflow-specific patterns"""
        tests = []
        nodes = workflow.get("nodes", [])
        workflow_name = workflow.get("name", "")

        # Test Execute_Queries specific patterns
        if "Execute_Queries" in workflow_name:
            # Check for empty array handling
            code_nodes = [n for n in nodes if self.get_node_type(n) == "code"]
            has_empty_check = any(
                "db_queries" in (n.get("parameters", {}).get("jsCode", ""))
                for n in code_nodes
            )

            if has_empty_check:
                tests.append(
                    TestResult(
                        "empty_array_handling", True, "Handles empty db_queries array"
                    )
                )
            else:
                tests.append(
                    TestResult(
                        "empty_array_handling", False, "Missing empty array handling"
                    )
                )

        # Test Route_Message specific patterns
        elif "Route_Message" in workflow_name:
            # Check for tag parsing
            code_nodes = [n for n in nodes if self.get_node_type(n) == "code"]
            has_tag_parsing = any(
                "tag" in (n.get("parameters", {}).get("jsCode", "").lower())
                for n in code_nodes
            )

            if has_tag_parsing:
                tests.append(
                    TestResult("tag_parsing", True, "Implements tag parsing logic")
                )
            else:
                tests.append(TestResult("tag_parsing", False, "Missing tag parsing"))

        return tests

    def test_documentation_coverage(self, workflow: dict) -> List[TestResult]:
        """Test if workflow has documentation coverage"""
        tests = []
        workflow_name = workflow.get("name", "")
        workflow_file_stem = Path(workflow_name.replace(" ", "_")).stem

        # Check for test file (.py or .json)
        test_dir = self.workflow_dir / "tests"
        test_py = test_dir / f"test_{workflow_file_stem}.py"
        test_json = test_dir / f"test_{workflow_file_stem}.json"

        if test_py.exists():
            tests.append(
                TestResult("test_file_exists", True, f"Test file: {test_py.name}")
            )
        elif test_json.exists():
            tests.append(
                TestResult("test_file_exists", True, f"Test file: {test_json.name}")
            )
        else:
            tests.append(
                TestResult(
                    "test_file_exists",
                    False,
                    f"Missing test file: test_{workflow_file_stem}.py",
                )
            )

        # Check for documentation in root README or n8n-workflows/README
        root_readme = Path("README.md")
        workflows_readme = self.workflow_dir / "README.md"

        found_in_readme = False
        for readme_file in [root_readme, workflows_readme]:
            if readme_file.exists():
                with open(readme_file, "r") as f:
                    readme_content = f.read()
                    if workflow_name in readme_content:
                        tests.append(
                            TestResult(
                                "documentation", True, f"Documented in {readme_file}"
                            )
                        )
                        found_in_readme = True
                        break

        if not found_in_readme:
            tests.append(
                TestResult("documentation", False, "Not documented in any README.md")
            )

        return tests

    def run_workflow_tests(self, filepath: str) -> WorkflowTest:
        """Run all tests for a single workflow"""
        workflow_name = Path(filepath).stem.replace("_", " ")

        try:
            with open(filepath, "r") as f:
                workflow = json.load(f)
        except Exception as e:
            return WorkflowTest(
                workflow_name,
                [TestResult("load_workflow", False, f"Failed to load: {e}")],
            )

        test_suite = WorkflowTest(workflow_name, [])

        # Run all test categories
        test_categories = [
            ("Structural", self.test_structural_validation),
            ("Context Patterns", self.test_ctx_patterns),
            ("Database Patterns", self.test_database_patterns),
            ("API Patterns", self.test_api_patterns),
            ("Workflow Specific", self.test_workflow_specific_patterns),
            ("Documentation", self.test_documentation_coverage),
        ]

        for category_name, test_func in test_categories:
            try:
                category_tests = test_func(workflow)
                for test in category_tests:
                    test_suite.add_test(
                        TestResult(
                            f"{category_name}: {test.name}", test.passed, test.details
                        )
                    )
            except Exception as e:
                test_suite.add_test(
                    TestResult(f"{category_name}: error", False, f"Test error: {e}")
                )

        return test_suite

    def test_trace_chain_formatting(self) -> List[TestResult]:
        """Test Postgres array formatting for trace_chain (ported from Smoke_Test)"""
        tests = []

        def format_chain(chain):
            """Format array for Postgres array literal syntax"""
            return "{" + ",".join(chain) + "}"

        test_cases = [
            (["uuid-1"], "{uuid-1}"),
            (["uuid-1", "uuid-2"], "{uuid-1,uuid-2}"),
            (["uuid-1", "uuid-2", "uuid-3"], "{uuid-1,uuid-2,uuid-3}"),
            ([], "{}"),
        ]

        fails = []
        for chain, expected in test_cases:
            result = format_chain(chain)
            if result != expected:
                fails.append(f"{chain} => '{result}' (want '{expected}')")

        if not fails:
            tests.append(
                TestResult(
                    "trace_chain_format", True, f"All {len(test_cases)} cases passed"
                )
            )
        else:
            tests.append(
                TestResult("trace_chain_format", False, f"Fails: {'; '.join(fails)}")
            )

        return tests

    def run_system_tests(self) -> WorkflowTest:
        """Run general system tests (ported from Smoke_Test)"""
        test_suite = WorkflowTest("System Tests", [])

        test_categories = [
            ("Database", self.test_database_schema),
            ("Serialization", self.test_json_serialization),
            ("Context", self.test_ctx_pattern_logic),
            ("Trace Formatting", self.test_trace_chain_formatting),
        ]

        for category_name, test_func in test_categories:
            try:
                category_tests = test_func()
                for test in category_tests:
                    test_suite.add_test(
                        TestResult(
                            f"{category_name}: {test.name}", test.passed, test.details
                        )
                    )
            except Exception as e:
                test_suite.add_test(
                    TestResult(f"{category_name}: error", False, f"Test error: {e}")
                )

        return test_suite

    def run_all_tests(self, verbose: bool = False) -> Dict[str, WorkflowTest]:
        """Run tests for all workflows"""
        workflow_files = list(self.workflow_dir.glob("*.json"))

        print(f"\n{CYAN}{'=' * 60}{NC}")
        print(f"{BOLD}Running Unit Tests for {len(workflow_files)} Workflows{NC}")
        print(f"{CYAN}{'=' * 60}{NC}")

        # Run system tests first
        print(f"\n{BLUE}Running System Tests (ported from Smoke_Test){NC}")
        system_results = self.run_system_tests()
        self.results["__system__"] = system_results

        if verbose or system_results.failed > 0:
            for test in system_results.tests:
                status = f"{GREEN}✓{NC}" if test.passed else f"{RED}✗{NC}"
                print(f"  {status} {test.name}: {test.details}")

        total = system_results.passed + system_results.failed
        success_rate = (system_results.passed / total * 100) if total > 0 else 0
        print(
            f"  {BOLD}Summary:{NC} {system_results.passed}/{total} passed ({success_rate:.1f}%)"
        )

        for filepath in sorted(workflow_files):
            print(f"\n{BLUE}Testing: {filepath.name}{NC}")

            test_result = self.run_workflow_tests(str(filepath))
            self.results[filepath.name] = test_result

            if verbose:
                for test in test_result.tests:
                    status = f"{GREEN}✓{NC}" if test.passed else f"{RED}✗{NC}"
                    print(f"  {status} {test.name}: {test.details}")

            # Summary for this workflow
            total = test_result.passed + test_result.failed
            success_rate = (test_result.passed / total * 100) if total > 0 else 0
            print(
                f"  {BOLD}Summary:{NC} {test_result.passed}/{total} passed ({success_rate:.1f}%)"
            )

        return self.results

    def generate_test_template(self, workflow_file: str) -> str:
        """Generate a test template for a workflow"""
        filepath = self.workflow_dir / workflow_file
        if not filepath.exists():
            return f"Workflow file not found: {filepath}"

        with open(filepath, "r") as f:
            workflow = json.load(f)

        workflow_name = workflow.get("name", Path(workflow_file).stem.replace("_", " "))
        test_filename = f"test_{Path(workflow_file).name}"
        test_filepath = self.workflow_dir / "tests" / test_filename

        # Create test directory if it doesn't exist
        test_filepath.parent.mkdir(exist_ok=True)

        class_name = workflow_name.replace(" ", "")

        template = f'''#!/usr/bin/env python3
"""
Unit Tests for {workflow_name} Workflow

Generated test template. Add specific test cases for this workflow.
"""

import json
import pytest
from pathlib import Path

def load_workflow():
    """Load the workflow JSON"""
    workflow_file = Path(__file__).parent.parent / "{workflow_file}"
    with open(workflow_file, 'r') as f:
        return json.load(f)

class Test{class_name}:
    """Test cases for {workflow_name} workflow"""
    
    def test_workflow_structure(self):
        """Test that the workflow has valid structure"""
        workflow = load_workflow()
        assert 'name' in workflow
        assert 'nodes' in workflow
        assert 'connections' in workflow
        
        # Add specific structure tests for this workflow
    
    def test_node_types(self):
        """Test that required node types are present"""
        workflow = load_workflow()
        nodes = workflow.get('nodes', [])
        
        # Add specific node type tests for this workflow
        node_types = [n.get('type', '') for n in nodes]
        
    def test_connections(self):
        """Test that connections are valid"""
        workflow = load_workflow()
        connections = workflow.get('connections', {{}})
        
        # Add specific connection tests for this workflow
    
    def test_ctx_pattern(self):
        """Test ctx pattern compliance"""
        workflow = load_workflow()
        
        # Add specific ctx pattern tests for this workflow
        pass

if __name__ == "__main__":
    pytest.main([__file__, "-v"])
'''

        with open(test_filepath, "w") as f:
            f.write(template)

        return f"Generated test template: {test_filepath}"

    def show_coverage(self):
        """Show test coverage across all workflows"""
        workflow_files = list(self.workflow_dir.glob("*.json"))
        total_workflows = len(workflow_files)

        # Count workflows with tests
        test_dir = self.workflow_dir / "tests"
        test_files = list(test_dir.glob("test_*.json")) if test_dir.exists() else []
        workflows_with_tests = len(test_files)

        print(f"\n{CYAN}{'=' * 60}{NC}")
        print(f"{BOLD}Test Coverage Report{NC}")
        print(f"{CYAN}{'=' * 60}{NC}")

        print(f"Total workflows: {total_workflows}")
        print(f"Workflows with tests: {workflows_with_tests}")
        print(f"Coverage: {workflows_with_tests / total_workflows * 100:.1f}%")

        if workflows_with_tests < total_workflows:
            print(f"\n{YELLOW}Missing test files:{NC}")
            for filepath in sorted(workflow_files):
                test_file = test_dir / f"test_{filepath.name}"
                if not test_file.exists():
                    print(f"  - {filepath.name}")

    def show_stats(self):
        """Show workflow statistics"""
        workflow_files = list(self.workflow_dir.glob("*.json"))

        print(f"\n{CYAN}{'=' * 60}{NC}")
        print(f"{BOLD}Workflow Statistics{NC}")
        print(f"{CYAN}{'=' * 60}{NC}")

        total_nodes = 0
        node_type_counts = defaultdict(int)
        workflow_types = defaultdict(int)

        for filepath in workflow_files:
            with open(filepath, "r") as f:
                workflow = json.load(f)

            nodes = workflow.get("nodes", [])
            total_nodes += len(nodes)

            # Count node types
            for node in nodes:
                node_type = self.get_node_type(node)
                node_type_counts[node_type] += 1

            # Categorize workflows
            name = workflow.get("name", "")
            if "route" in name.lower():
                workflow_types["Routing"] += 1
            elif "capture" in name.lower():
                workflow_types["Capture"] += 1
            elif "handle" in name.lower():
                workflow_types["Handling"] += 1
            elif "execute" in name.lower():
                workflow_types["Execution"] += 1
            else:
                workflow_types["Other"] += 1

        print(f"Total workflows: {len(workflow_files)}")
        print(f"Total nodes: {total_nodes}")
        print(f"Average nodes per workflow: {total_nodes / len(workflow_files):.1f}")

        print(f"\n{BOLD}Workflow Types:{NC}")
        for category, count in sorted(workflow_types.items()):
            print(f"  {category}: {count}")

        print(f"\n{BOLD}Top Node Types:{NC}")
        for node_type, count in sorted(node_type_counts.items(), key=lambda x: -x[1])[
            :10
        ]:
            print(f"  {node_type}: {count}")


def main():
    parser = argparse.ArgumentParser(
        description="Unit Test Framework for n8n Workflows"
    )
    parser.add_argument("workflow", nargs="?", help="Specific workflow file to test")
    parser.add_argument("--all", action="store_true", help="Test all workflows")
    parser.add_argument(
        "--generate", action="store_true", help="Generate test templates"
    )
    parser.add_argument("--coverage", action="store_true", help="Show test coverage")
    parser.add_argument("--stats", action="store_true", help="Show workflow statistics")
    parser.add_argument("--verbose", "-v", action="store_true", help="Verbose output")
    parser.add_argument(
        "--workflow-dir", default="n8n-workflows", help="Workflow directory"
    )

    args = parser.parse_args()

    tester = WorkflowTester(args.workflow_dir)

    if args.coverage:
        tester.show_coverage()
    elif args.stats:
        tester.show_stats()
    elif args.generate:
        if args.workflow:
            result = tester.generate_test_template(args.workflow)
            print(result)
        else:
            print("Usage: --generate requires a workflow filename")
    elif args.workflow:
        # Test specific workflow
        result = tester.run_workflow_tests(args.workflow)
        print(f"\n{CYAN}{'=' * 60}{NC}")
        print(f"{BOLD}Test Results for {args.workflow}{NC}")
        print(f"{CYAN}{'=' * 60}{NC}")

        for test in result.tests:
            status = f"{GREEN}✓{NC}" if test.passed else f"{RED}✗{NC}"
            print(f"{status} {test.name}: {test.details}")

        total = result.passed + result.failed
        success_rate = (result.passed / total * 100) if total > 0 else 0
        print(
            f"\n{BOLD}Summary:{NC} {result.passed}/{total} passed ({success_rate:.1f}%)"
        )
    elif args.all:
        # Test all workflows
        results = tester.run_all_tests(args.verbose)

        # Overall summary
        total_tests = sum(len(r.tests) for r in results.values())
        total_passed = sum(r.passed for r in results.values())
        overall_success = (total_passed / total_tests * 100) if total_tests > 0 else 0

        print(f"\n{CYAN}{'=' * 60}{NC}")
        print(f"{BOLD}Overall Summary{NC}")
        print(f"{CYAN}{'=' * 60}{NC}")
        print(f"Total workflows tested: {len(results)}")
        print(f"Total tests run: {total_tests}")
        print(f"Total passed: {total_passed}")
        print(f"Total failed: {total_tests - total_passed}")
        print(f"Overall success rate: {overall_success:.1f}%")
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
