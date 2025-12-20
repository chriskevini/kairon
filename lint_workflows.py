#!/usr/bin/env python3
"""
lint_workflows.py - Lint n8n workflows for ctx pattern compliance and best practices

Usage:
    ./lint_workflows.py                    # Lint all workflows
    ./lint_workflows.py workflow.json      # Lint specific workflow
    ./lint_workflows.py --fix workflow.json  # Auto-fix some issues (coming soon)

Exit codes:
    0 - All checks passed
    1 - Errors found
    2 - Warnings only
"""

import json
import sys
import os
import re
from pathlib import Path
from typing import Dict, List, Tuple, Optional

# ANSI colors
RED = '\033[0;31m'
YELLOW = '\033[0;33m'
GREEN = '\033[0;32m'
BLUE = '\033[0;34m'
CYAN = '\033[0;36m'
NC = '\033[0m'  # No Color

class LintResult:
    def __init__(self):
        self.errors: List[str] = []
        self.warnings: List[str] = []
        self.infos: List[str] = []
    
    def error(self, msg: str):
        self.errors.append(msg)
    
    def warn(self, msg: str):
        self.warnings.append(msg)
    
    def ok(self, msg: str):
        self.infos.append(msg)
    
    def has_errors(self) -> bool:
        return len(self.errors) > 0
    
    def has_warnings(self) -> bool:
        return len(self.warnings) > 0


def find_node(workflow: dict, name: str) -> Optional[dict]:
    """Find a node by name"""
    for node in workflow.get('nodes', []):
        if node.get('name') == name:
            return node
    return None


def get_node_type(node: dict) -> str:
    """Get the simplified node type"""
    full_type = node.get('type', '')
    # Extract the last part: n8n-nodes-base.code -> code
    return full_type.split('.')[-1] if '.' in full_type else full_type


def check_ctx_initialization(workflow: dict, result: LintResult):
    """Check if workflow initializes ctx object properly"""
    nodes = workflow.get('nodes', [])
    
    # Find trigger node
    trigger_types = ['executeWorkflowTrigger', 'webhook', 'manualTrigger']
    trigger_node = None
    for node in nodes:
        if any(t in node.get('type', '') for t in trigger_types):
            trigger_node = node
            break
    
    if not trigger_node:
        result.warn("No trigger node found - cannot verify ctx initialization")
        return
    
    # Check if first code/set node after trigger initializes ctx
    connections = workflow.get('connections', {})
    trigger_name = trigger_node.get('name')
    
    if trigger_name in connections:
        next_nodes = connections[trigger_name].get('main', [[]])[0]
        for conn in next_nodes:
            next_node_name = conn.get('node')
            next_node = find_node(workflow, next_node_name)
            if next_node:
                node_type = get_node_type(next_node)
                if node_type == 'set':
                    # Check if it sets ctx fields
                    assignments = next_node.get('parameters', {}).get('assignments', {}).get('assignments', [])
                    has_ctx = any('ctx.' in a.get('name', '') for a in assignments)
                    if has_ctx:
                        result.ok(f"ctx initialized in '{next_node_name}' (Set node)")
                    else:
                        result.warn(f"Set node '{next_node_name}' after trigger doesn't initialize ctx")
                elif node_type == 'code':
                    code = next_node.get('parameters', {}).get('jsCode', '')
                    if 'ctx:' in code or 'ctx: {' in code:
                        result.ok(f"ctx initialized in '{next_node_name}' (Code node)")
                    else:
                        result.warn(f"Code node '{next_node_name}' after trigger may not initialize ctx")


def check_code_node_ctx_pattern(node: dict, result: LintResult):
    """Check if a Code node follows ctx pattern"""
    name = node.get('name', 'Unknown')
    code = node.get('parameters', {}).get('jsCode', '')
    
    if not code:
        return
    
    # Check for ctx return pattern
    has_ctx_return = 'ctx:' in code or 'ctx: {' in code
    
    # Check for old flat patterns
    old_patterns = [
        (r'return\s*\{\s*response:', 'returns flat {response:} instead of {ctx: {..., response:}}'),
        (r'return\s*\{\s*error:', 'returns flat {error:} instead of {ctx: {..., validation:}}'),
        (r'return\s*\{\s*valid:', 'returns flat {valid:} instead of {ctx: {..., validation:}}'),
        (r'\.\.\.\$json(?!\s*\.ctx)', 'spreads $json instead of $json.ctx'),
        (r"return\s*\{\s*\.\.\.\s*event", 'returns {...event} instead of ctx pattern'),
    ]
    
    for pattern, msg in old_patterns:
        if re.search(pattern, code):
            result.error(f"'{name}': {msg}")
    
    # Check for proper ctx access patterns
    good_patterns = [
        (r'\$json\.ctx\.', 'uses $json.ctx.* access'),
        (r"\$\('.*'\)\..*\.json\.ctx", 'uses node reference with ctx'),
    ]
    
    bad_access_patterns = [
        (r"\$json\.(?!ctx)[a-z_]+(?!\s*\|\|)", 'accesses $json.X directly instead of $json.ctx.X'),
    ]
    
    # Skip validation for simple passthrough nodes
    if 'passthrough' in code.lower() or len(code) < 50:
        return
    
    for pattern, msg in bad_access_patterns:
        matches = re.findall(pattern, code)
        if matches and not has_ctx_return:
            # Only warn if it doesn't look like it's setting up ctx
            result.warn(f"'{name}': may be using flat data access")


def check_if_node_ctx_pattern(node: dict, result: LintResult):
    """Check if an If node checks ctx.validation.valid"""
    name = node.get('name', 'Unknown')
    conditions = node.get('parameters', {}).get('conditions', {}).get('conditions', [])
    
    for cond in conditions:
        left_value = cond.get('leftValue', '')
        
        # Check for old pattern
        if '$json.valid' in left_value and 'ctx' not in left_value:
            result.error(f"'{name}': checks $json.valid instead of $json.ctx.validation.valid")
        
        # Check for correct pattern
        if 'ctx.validation.valid' in left_value:
            result.ok(f"'{name}': correctly checks ctx.validation.valid")


def check_postgres_node_pattern(node: dict, result: LintResult):
    """Check if Postgres nodes use ctx for query parameters"""
    name = node.get('name', 'Unknown')
    options = node.get('parameters', {}).get('options', {})
    query_replacement = options.get('queryReplacement', '')
    
    if not query_replacement:
        return
    
    # Check for old node reference pattern
    old_pattern = r"\$\('([^']+)'\)\.item\.json\.(?!ctx)"
    matches = re.findall(old_pattern, query_replacement)
    if matches:
        result.error(f"'{name}': uses node reference without ctx: $('...').item.json.X")
    
    # Check for correct pattern
    if '$json.ctx.' in query_replacement:
        result.ok(f"'{name}': correctly uses ctx for query parameters")


def check_discord_node_pattern(node: dict, result: LintResult):
    """Check if Discord nodes use ctx.event for IDs"""
    name = node.get('name', 'Unknown')
    params = node.get('parameters', {})
    
    guild_id = params.get('guildId', {}).get('value', '')
    channel_id = params.get('channelId', {}).get('value', '')
    content = params.get('content', '')
    
    # Check guild/channel IDs
    for field, value in [('guildId', guild_id), ('channelId', channel_id)]:
        if '$json.' in value and 'ctx.event' not in value:
            result.error(f"'{name}': {field} uses $json.X instead of $json.ctx.event.X")
    
    # Check content field
    if '$json.response' in content and 'ctx' not in content:
        result.error(f"'{name}': content uses $json.response instead of $json.ctx.response.content")
    if '$json.error_message' in content and 'ctx' not in content:
        result.error(f"'{name}': content uses $json.error_message instead of $json.ctx.validation.error_message")


def check_set_node_pattern(node: dict, result: LintResult):
    """Check if Set nodes preserve ctx with includeOtherFields"""
    name = node.get('name', 'Unknown')
    params = node.get('parameters', {})
    
    include_other = params.get('includeOtherFields', False)
    assignments = params.get('assignments', {}).get('assignments', [])
    
    # Check if any assignments set ctx fields
    sets_ctx = any('ctx.' in a.get('name', '') for a in assignments)
    
    if sets_ctx and not include_other:
        result.warn(f"'{name}': sets ctx.* fields but includeOtherFields is false - may lose ctx data")


def check_switch_node_fallback(node: dict, result: LintResult):
    """Check if Switch nodes have a fallback output"""
    name = node.get('name', 'Unknown')
    options = node.get('parameters', {}).get('options', {})
    
    if 'fallbackOutput' not in options:
        result.warn(f"'{name}': Switch node has no fallback output - unmatched cases will produce no output")


def check_node_references(workflow: dict, result: LintResult):
    """Check for scattered node references that should use ctx instead"""
    nodes = workflow.get('nodes', [])
    
    for node in nodes:
        node_type = get_node_type(node)
        name = node.get('name', 'Unknown')
        
        if node_type == 'code':
            code = node.get('parameters', {}).get('jsCode', '')
            
            # Find all node references
            refs = re.findall(r"\$\('([^']+)'\)", code)
            
            # Filter out the immediate upstream context reference (which is acceptable)
            # Wrapper nodes referencing the previous node for ctx is OK
            if len(refs) > 2:
                result.warn(f"'{name}': has {len(refs)} node references - consider using ctx pattern to reduce coupling")


def check_merge_node_config(node: dict, result: LintResult):
    """Check if Merge nodes are properly configured"""
    name = node.get('name', 'Unknown')
    params = node.get('parameters', {})
    
    if not params:
        result.error(f"'{name}': Merge node has empty parameters - needs mode and numberInputs")
    elif 'mode' not in params:
        result.warn(f"'{name}': Merge node missing 'mode' parameter (should usually be 'append')")


def lint_workflow(filepath: str) -> LintResult:
    """Lint a single workflow file"""
    result = LintResult()
    
    try:
        with open(filepath, 'r') as f:
            workflow = json.load(f)
    except json.JSONDecodeError as e:
        result.error(f"Invalid JSON: {e}")
        return result
    except FileNotFoundError:
        result.error(f"File not found: {filepath}")
        return result
    
    # Run all checks
    check_ctx_initialization(workflow, result)
    
    for node in workflow.get('nodes', []):
        node_type = get_node_type(node)
        
        if node_type == 'code':
            check_code_node_ctx_pattern(node, result)
        elif node_type == 'if':
            check_if_node_ctx_pattern(node, result)
        elif node_type == 'postgres':
            check_postgres_node_pattern(node, result)
        elif node_type == 'discord':
            check_discord_node_pattern(node, result)
        elif node_type == 'set':
            check_set_node_pattern(node, result)
        elif node_type == 'switch':
            check_switch_node_fallback(node, result)
        elif node_type == 'merge':
            check_merge_node_config(node, result)
    
    check_node_references(workflow, result)
    
    return result


def print_result(filepath: str, result: LintResult):
    """Print lint results for a workflow"""
    filename = os.path.basename(filepath)
    
    if result.has_errors():
        status = f"{RED}FAIL{NC}"
    elif result.has_warnings():
        status = f"{YELLOW}WARN{NC}"
    else:
        status = f"{GREEN}PASS{NC}"
    
    print(f"\n{CYAN}{'='*60}{NC}")
    print(f"{BLUE}{filename}{NC} - {status}")
    print(f"{CYAN}{'='*60}{NC}")
    
    if result.errors:
        print(f"\n{RED}Errors:{NC}")
        for msg in result.errors:
            print(f"  {RED}✗{NC} {msg}")
    
    if result.warnings:
        print(f"\n{YELLOW}Warnings:{NC}")
        for msg in result.warnings:
            print(f"  {YELLOW}!{NC} {msg}")
    
    if result.infos and not result.errors:
        print(f"\n{GREEN}OK:{NC}")
        for msg in result.infos[:5]:  # Limit to first 5
            print(f"  {GREEN}✓{NC} {msg}")
        if len(result.infos) > 5:
            print(f"  ... and {len(result.infos) - 5} more")


def main():
    args = sys.argv[1:]
    
    # Parse arguments
    fix_mode = '--fix' in args
    if fix_mode:
        args.remove('--fix')
        print(f"{YELLOW}Fix mode not yet implemented{NC}")
    
    # Determine files to lint
    if args:
        files = args
    else:
        workflow_dir = Path('n8n-workflows')
        if not workflow_dir.exists():
            print(f"{RED}n8n-workflows directory not found{NC}")
            sys.exit(1)
        files = sorted(workflow_dir.glob('*.json'))
    
    if not files:
        print(f"{RED}No workflow files found{NC}")
        sys.exit(1)
    
    # Lint all files
    total_errors = 0
    total_warnings = 0
    
    print(f"\n{CYAN}Linting {len(files)} workflow(s)...{NC}")
    
    for filepath in files:
        result = lint_workflow(str(filepath))
        print_result(str(filepath), result)
        total_errors += len(result.errors)
        total_warnings += len(result.warnings)
    
    # Summary
    print(f"\n{CYAN}{'='*60}{NC}")
    print(f"{BLUE}Summary:{NC}")
    print(f"  Files: {len(files)}")
    print(f"  Errors: {RED if total_errors else GREEN}{total_errors}{NC}")
    print(f"  Warnings: {YELLOW if total_warnings else GREEN}{total_warnings}{NC}")
    print(f"{CYAN}{'='*60}{NC}\n")
    
    # Exit code
    if total_errors > 0:
        sys.exit(1)
    elif total_warnings > 0:
        sys.exit(2)
    else:
        sys.exit(0)


if __name__ == '__main__':
    main()
