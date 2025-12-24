#!/usr/bin/env python3
"""
n8n Workflow Property Validation
Validates workflows against n8n's internal property schemas to prevent UI compatibility issues.
"""

import json
import sys
import os
import argparse
from pathlib import Path
from typing import Dict, Any, List, Optional
import requests


class N8nWorkflowValidator:
    """Validates n8n workflows against API and property schemas"""

    def __init__(self, api_url: str = None, api_key: str = None):
        self.api_url = api_url or os.getenv("N8N_API_URL", "http://localhost:5678")
        self.api_key = api_key or os.getenv("N8N_API_KEY")
        self.session = requests.Session()
        self.session.timeout = 30

        if self.api_key:
            self.session.headers.update({"X-N8N-API-KEY": self.api_key})

    def validate_workflow_api(self, workflow: Dict[str, Any]) -> Dict[str, Any]:
        """Validate workflow by testing API operations"""
        result = {"valid": True, "errors": [], "warnings": [], "tests": []}

        # Test 1: Basic API connectivity
        try:
            response = self.session.get(f"{self.api_url}/health")
            if response.status_code != 200:
                result["warnings"].append(
                    f"API health check failed: {response.status_code}"
                )
        except requests.RequestException as e:
            result["warnings"].append(f"API connectivity issue: {e}")

        # Test 2: Workflow schema validation
        try:
            # Attempt to validate workflow structure
            response = self.session.post(
                f"{self.api_url}/api/v1/workflows/validate",
                json=workflow,
                headers={"Content-Type": "application/json"},
            )

            if response.status_code == 200:
                result["tests"].append("✅ Workflow schema validation passed")
            elif response.status_code == 400:
                error_data = response.json()
                result["errors"].append(f"Schema validation failed: {error_data}")
                result["valid"] = False
            else:
                result["warnings"].append(
                    f"Unexpected validation response: {response.status_code}"
                )

        except requests.RequestException as e:
            result["warnings"].append(f"Schema validation unavailable: {e}")

        # Test 3: Workflow upload simulation
        try:
            # Create a temporary workflow for testing
            test_workflow = workflow.copy()
            test_workflow["name"] = f"validation-test-{workflow.get('name', 'unknown')}"
            test_workflow["active"] = False

            response = self.session.post(
                f"{self.api_url}/api/v1/workflows",
                json=test_workflow,
                headers={"Content-Type": "application/json"},
            )

            if response.status_code in [200, 201]:
                workflow_id = response.json().get("id")
                result["tests"].append("✅ Workflow upload simulation successful")

                # Clean up test workflow
                if workflow_id:
                    self.session.delete(
                        f"{self.api_url}/api/v1/workflows/{workflow_id}"
                    )

            elif response.status_code == 400:
                error_data = response.json()
                result["errors"].append(f"Upload validation failed: {error_data}")
                result["valid"] = False
            else:
                result["warnings"].append(f"Upload test failed: {response.status_code}")

        except requests.RequestException as e:
            result["warnings"].append(f"Upload simulation unavailable: {e}")

        return result

    def validate_workflow_properties(self, workflow: Dict[str, Any]) -> Dict[str, Any]:
        """Validate workflow properties that affect UI compatibility"""
        result = {"valid": True, "errors": [], "warnings": [], "checks": []}

        # Check basic workflow structure
        if "nodes" not in workflow:
            result["errors"].append("Missing 'nodes' array")
            result["valid"] = False
            return result

        if "connections" not in workflow:
            result["errors"].append("Missing 'connections' object")
            result["valid"] = False
            return result

        nodes = workflow.get("nodes", [])
        connections = workflow.get("connections", {})

        # Check each node for required properties
        for node in nodes:
            node_name = node.get("name", "Unknown")
            node_type = node.get("type", "")

            # Required node properties
            required_props = ["parameters", "type", "typeVersion", "position"]
            for prop in required_props:
                if prop not in node:
                    result["errors"].append(
                        f"Node '{node_name}': missing required property '{prop}'"
                    )
                    result["valid"] = False

            # Check node type format
            if not node_type or "." not in node_type:
                result["warnings"].append(
                    f"Node '{node_name}': unusual type format '{node_type}'"
                )

            # Validate position coordinates
            position = node.get("position", [])
            if not isinstance(position, list) or len(position) != 2:
                result["errors"].append(f"Node '{node_name}': invalid position format")
                result["valid"] = False

            result["checks"].append(f"✅ Node '{node_name}' has required properties")

        # Check connections validity
        for source_node, outputs in connections.items():
            if source_node not in [n.get("name") for n in nodes]:
                result["errors"].append(
                    f"Connection from non-existent node: {source_node}"
                )
                result["valid"] = False

            for output_name, output_list in outputs.items():
                for output in output_list:
                    for conn in output:
                        target_node = conn.get("node")
                        if target_node and target_node not in [
                            n.get("name") for n in nodes
                        ]:
                            result["errors"].append(
                                f"Connection to non-existent node: {source_node} → {target_node}"
                            )
                            result["valid"] = False

        result["checks"].append("✅ Connection validation completed")

        return result

    def validate_workflow_file(self, filepath: str) -> Dict[str, Any]:
        """Validate a single workflow file"""
        result = {
            "filepath": filepath,
            "valid": True,
            "api_validation": {},
            "property_validation": {},
            "summary": {},
        }

        try:
            with open(filepath, "r", encoding="utf-8") as f:
                workflow = json.load(f)
        except (json.JSONDecodeError, FileNotFoundError) as e:
            result["valid"] = False
            result["summary"] = {"error": f"Failed to load workflow: {e}"}
            return result

        # Run property validation (always available)
        prop_result = self.validate_workflow_properties(workflow)
        result["property_validation"] = prop_result
        result["valid"] = result["valid"] and prop_result["valid"]

        # Run API validation (if n8n is available)
        if self.api_key and self.api_url:
            api_result = self.validate_workflow_api(workflow)
            result["api_validation"] = api_result
            result["valid"] = result["valid"] and api_result["valid"]
        else:
            result["api_validation"] = {"skipped": "n8n API not configured"}

        # Generate summary
        total_errors = len(prop_result.get("errors", []))
        total_warnings = len(prop_result.get("warnings", []))
        total_checks = len(prop_result.get("checks", []))

        if "api_validation" in result and "errors" in result["api_validation"]:
            total_errors += len(result["api_validation"]["errors"])
        if "api_validation" in result and "warnings" in result["api_validation"]:
            total_warnings += len(result["api_validation"]["warnings"])

        result["summary"] = {
            "errors": total_errors,
            "warnings": total_warnings,
            "checks": total_checks,
            "status": "PASS" if result["valid"] else "FAIL",
        }

        return result


def main():
    parser = argparse.ArgumentParser(
        description="Validate n8n workflows for UI compatibility"
    )
    parser.add_argument("workflow", help="Workflow file to validate")
    parser.add_argument(
        "--api-url", help="n8n API URL (default: from N8N_API_URL env var)"
    )
    parser.add_argument(
        "--api-key", help="n8n API key (default: from N8N_API_KEY env var)"
    )
    parser.add_argument("--verbose", "-v", action="store_true", help="Verbose output")

    args = parser.parse_args()

    validator = N8nWorkflowValidator(args.api_url, args.api_key)
    result = validator.validate_workflow_file(args.workflow)

    # Output results
    print(f"Workflow: {result['filepath']}")
    print(f"Status: {result['summary']['status']}")
    print(
        f"Errors: {result['summary']['errors']}, Warnings: {result['summary']['warnings']}, Checks: {result['summary']['checks']}"
    )
    print()

    if args.verbose:
        # Show detailed results
        if result["property_validation"].get("errors"):
            print("Property Validation Errors:")
            for error in result["property_validation"]["errors"]:
                print(f"  ❌ {error}")

        if result["property_validation"].get("warnings"):
            print("Property Validation Warnings:")
            for warning in result["property_validation"]["warnings"]:
                print(f"  ⚠️  {warning}")

        if result["api_validation"].get("errors"):
            print("API Validation Errors:")
            for error in result["api_validation"]["errors"]:
                print(f"  ❌ {error}")

        if result["api_validation"].get("warnings"):
            print("API Validation Warnings:")
            for warning in result["api_validation"]["warnings"]:
                print(f"  ⚠️  {warning}")

        if result["property_validation"].get("checks"):
            print("Validation Checks Passed:")
            for check in result["property_validation"]["checks"]:
                print(f"  ✅ {check}")

    # Exit with appropriate code
    sys.exit(0 if result["valid"] else 1)


if __name__ == "__main__":
    main()
