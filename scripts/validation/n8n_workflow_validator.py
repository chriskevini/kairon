#!/usr/bin/env python3
"""
n8n Workflow Property Validation
Validates workflows against n8n's internal property schemas to prevent UI compatibility issues.
"""

import json
import sys
import os
from pathlib import Path
from typing import Dict, Any, List


class N8nWorkflowValidator:
    """Validates n8n workflows for UI compatibility"""

    def validate_workflow_properties(self, workflow: Dict[str, Any]) -> Dict[str, Any]:
        """Validate workflow properties that affect UI compatibility"""
        result = {
            'valid': True,
            'errors': [],
            'warnings': [],
            'checks': []
        }

        # Check basic workflow structure
        if 'nodes' not in workflow:
            result['errors'].append("Missing 'nodes' array")
            result['valid'] = False
            return result

        if 'connections' not in workflow:
            result['errors'].append("Missing 'connections' object")
            result['valid'] = False
            return result

        nodes = workflow.get('nodes', [])
        connections = workflow.get('connections', {})

        # Check each node for required properties
        for node in nodes:
            node_name = node.get('name', 'Unknown')
            node_type = node.get('type', '')

            # Required node properties
            required_props = ['parameters', 'type', 'typeVersion', 'position']
            for prop in required_props:
                if prop not in node:
                    result['errors'].append(f"Node '{node_name}': missing required property '{prop}'")
                    result['valid'] = False

            # Check node type format
            if not node_type or '.' not in node_type:
                result['warnings'].append(f"Node '{node_name}': unusual type format '{node_type}'")

            # Validate position coordinates
            position = node.get('position', [])
            if not isinstance(position, list) or len(position) != 2:
                result['errors'].append(f"Node '{node_name}': invalid position format")
                result['valid'] = False

            result['checks'].append(f"✅ Node '{node_name}' has required properties")

        # Check connections validity
        for source_node, outputs in connections.items():
            if source_node not in [n.get('name') for n in nodes]:
                result['errors'].append(f"Connection from non-existent node: {source_node}")
                result['valid'] = False

            for output_name, output_list in outputs.items():
                for output in output_list:
                    for conn in output:
                        target_node = conn.get('node')
                        if target_node and target_node not in [n.get('name') for n in nodes]:
                            result['errors'].append(f"Connection to non-existent node: {source_node} → {target_node}")
                            result['valid'] = False

        result['checks'].append("✅ Connection validation completed")

        return result

    def validate_workflow_file(self, filepath: str) -> Dict[str, Any]:
        """Validate a single workflow file"""
        result = {
            'filepath': filepath,
            'valid': True,
            'property_validation': {},
            'summary': {}
        }

        try:
            with open(filepath, 'r', encoding='utf-8') as f:
                workflow = json.load(f)
        except json.JSONDecodeError as e:
            result['valid'] = False
            result['summary'] = {'status': 'FAIL', 'errors': 1, 'warnings': 0, 'checks': 0, 'error': f"Invalid JSON: {e}"}
            result['property_validation'] = {'errors': [f"Invalid JSON: {e}"]}
            return result
        except FileNotFoundError as e:
            result['valid'] = False
            result['summary'] = {'status': 'FAIL', 'errors': 1, 'warnings': 0, 'checks': 0, 'error': f"File not found: {e}"}
            result['property_validation'] = {'errors': [f"File not found: {e}"]}
            return result

        # Run property validation (always available)
        prop_result = self.validate_workflow_properties(workflow)
        result['property_validation'] = prop_result
        result['valid'] = result['valid'] and prop_result['valid']

        # Generate summary
        total_errors = len(prop_result.get('errors', []))
        total_warnings = len(prop_result.get('warnings', []))
        total_checks = len(prop_result.get('checks', []))

        result['summary'] = {
            'errors': total_errors,
            'warnings': total_warnings,
            'checks': total_checks,
            'status': 'PASS' if result['valid'] else 'FAIL'
        }

        return result


def main():
    import argparse

    parser = argparse.ArgumentParser(description='Validate n8n workflows for UI compatibility')
    parser.add_argument('workflow', help='Workflow file to validate')
    parser.add_argument('--verbose', '-v', action='store_true', help='Verbose output')

    args = parser.parse_args()

    validator = N8nWorkflowValidator()
    result = validator.validate_workflow_file(args.workflow)

    # Output results
    print(f"Workflow: {result['filepath']}")
    status = result['summary'].get('status', 'UNKNOWN')
    print(f"Status: {status}")
    print(f"Errors: {result['summary'].get('errors', 0)}, Warnings: {result['summary'].get('warnings', 0)}, Checks: {result['summary'].get('checks', 0)}")
    print()

    if args.verbose:
        # Show detailed results
        if result['property_validation'].get('errors'):
            print("Property Validation Errors:")
            for error in result['property_validation']['errors']:
                print(f"  ❌ {error}")

        if result['property_validation'].get('warnings'):
            print("Property Validation Warnings:")
            for warning in result['property_validation']['warnings']:
                print(f"  ⚠️  {warning}")

        if result['property_validation'].get('checks'):
            print("Validation Checks Passed:")
            for check in result['property_validation']['checks']:
                print(f"  ✅ {check}")

    # Exit with appropriate code
    sys.exit(0 if result['valid'] else 1)


if __name__ == '__main__':
    main()
