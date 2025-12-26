#!/usr/bin/env python3
"""
Transform workflow JSON for dev environment testing.

Replaces external API calls (Discord, LLM) with mock Code nodes,
converts Webhook triggers to Execute Workflow Triggers, and
remaps workflow IDs for Execute Workflow nodes.

Usage:
    cat workflow.json | python transform_for_dev.py > transformed.json

    # With workflow ID remapping (prod ID -> dev ID):
    cat workflow.json | WORKFLOW_ID_REMAP='{"prodId1":"devId1"}' python transform_for_dev.py
"""

import json
import os
import sys


# Workflow ID remapping (prod ID -> dev ID), populated from environment
WORKFLOW_ID_REMAP: dict[str, str] = {}


def load_workflow_id_remap():
    """Load workflow ID remapping from WORKFLOW_ID_REMAP environment variable."""
    global WORKFLOW_ID_REMAP
    ids_json = os.environ.get("WORKFLOW_ID_REMAP", "{}")
    try:
        WORKFLOW_ID_REMAP = json.loads(ids_json)
    except json.JSONDecodeError:
        WORKFLOW_ID_REMAP = {}


def transform_node(node: dict) -> dict:
    """Transform a single node if it matches replacement criteria.

    Note: mode:list Execute Workflow nodes are preserved to maintain
    portable workflow references across environments. Workflow names are
    stable across dev/prod/staging, while IDs change.
    """
    node_type = node.get("type", "")

    # Webhook Trigger → Execute Workflow Trigger
    # Allows smoke tests to invoke workflows directly without HTTP
    # Exception: Smoke_Test entry point webhook should not be transformed
    if node_type == "n8n-nodes-base.webhook":
        node_name = node.get("name", "").lower()

        # Entry point for smoke tests (old method)
        if "smoke_test" in node_name or "test" in node_name:
            return node

        # Entry point for external test-all-paths.sh script
        if "discord webhook entry" in node_name or "test webhook" in node_name:
            node["parameters"]["path"] = "kairon-dev-test"
            # Switch to production response mode to ensure it's registered properly
            node["parameters"]["responseMode"] = "onReceived"
            return node

        node["type"] = "n8n-nodes-base.executeWorkflowTrigger"
        node["typeVersion"] = 1
        node["parameters"] = {}
        # Remove webhook-specific fields
        node.pop("webhookId", None)
        return node

    # Schedule Trigger → Execute Workflow Trigger
    # Allows smoke tests to invoke cron workflows directly
    if node_type == "n8n-nodes-base.scheduleTrigger":
        node["type"] = "n8n-nodes-base.executeWorkflowTrigger"
        node["typeVersion"] = 1
        node["parameters"] = {}
        return node

    # Discord Node → Mock Code Node
    # Returns fake Discord API response
    if node_type == "n8n-nodes-base.discord":
        original_name = node.get("name", "Discord")
        node["type"] = "n8n-nodes-base.code"
        node["typeVersion"] = 2
        node["parameters"] = {
            "jsCode": f'''// Mock Discord node: {original_name}
// Returns fake Discord API response for dev testing
const input = $input.first().json;
return [{{ 
  json: {{ 
    id: "mock-discord-" + Date.now(),
    channel_id: input.channelId || "mock-channel",
    content: input.content || "",
    success: true,
    _mock: true,
    _original_node: "{original_name}"
  }} 
}}];'''
        }
        # Remove credential reference
        node.pop("credentials", None)
        return node

    # LLM Chain Node → Mock Code Node
    # Returns fake LLM response
    if node_type == "@n8n/n8n-nodes-langchain.chainLlm":
        original_name = node.get("name", "LLM Chain")
        node["type"] = "n8n-nodes-base.code"
        node["typeVersion"] = 2

        # Enhanced mocking logic
        js_code = f'''// Mock LLM Chain node: {original_name}
const input = $input.first().json;
const inputText = input.ctx?.event?.clean_text 
  || input.text 
  || input.prompt 
  || "";

// Check for specific keywords to provide more realistic mocks
let response = "[MOCK LLM] I processed your request.";

if (inputText.includes("!!") || inputText.toLowerCase().includes("act")) {{
  response = "[MOCK LLM] Activity recorded: " + inputText.replace(/!!|act/i, "").trim();
}} else if (inputText.includes("..") || inputText.toLowerCase().includes("note")) {{
  response = "[MOCK LLM] Note saved.";
}} else if (inputText.includes("$$") || inputText.toLowerCase().includes("todo")) {{
  response = "[MOCK LLM] Added to your todo list.";
}} else if (inputText.includes("++")) {{
  response = "[MOCK LLM] I am starting a new thread for you. How can I help?";
}} else if (inputText.includes("--")) {{
  response = "[MOCK LLM] Thread summarized and closed.";
}}

return [{{ 
  json: {{ 
    text: response,
    _mock: true,
    _original_node: "{original_name}",
    _input_preview: inputText.substring(0, 200)
  }} 
}}];'''

        node["parameters"] = {"jsCode": js_code}
        return node

    # HTTP Request nodes that call external APIs could also be mocked here
    # if needed in the future

    # Execute Workflow Node → Remap workflow IDs from prod to dev
    if node_type == "n8n-nodes-base.executeWorkflow":
        params = node.get("parameters", {})
        workflow_ref = params.get("workflowId", {})

        if isinstance(workflow_ref, dict):
            mode = workflow_ref.get("mode", "")
            value = workflow_ref.get("value", "")

            # Remap prod ID to dev ID
            # Also handle mode="list" which is used in newer n8n versions
            if (mode == "id" or mode == "list") and value in WORKFLOW_ID_REMAP:
                workflow_ref["value"] = WORKFLOW_ID_REMAP[value]
                # Force mode to "id" for cleaner mapping in dev
                workflow_ref["mode"] = "id"

        return node

    return node


def transform_workflow(workflow: dict) -> dict:
    """Transform all nodes in a workflow for dev environment."""
    if "nodes" not in workflow:
        return workflow

    workflow["nodes"] = [transform_node(node) for node in workflow["nodes"]]

    # Ensure the workflow has a name if it's missing (needed by n8n-push-local.sh)
    # Prefer name from environment, then existing name, then fallback
    env_name = os.environ.get("WORKFLOW_NAME")
    if env_name:
        workflow["name"] = env_name
    elif not workflow.get("name"):
        workflow["name"] = "Unnamed Transformed Workflow"

    # Force activation for dev testing if not explicitly set
    if "active" not in workflow:
        workflow["active"] = True

    # Add a marker to indicate this workflow was transformed
    if not workflow.get("meta"):
        workflow["meta"] = {}
    workflow["meta"]["transformedForDev"] = True

    return workflow


def main():
    load_workflow_id_remap()

    try:
        workflow = json.load(sys.stdin)
    except json.JSONDecodeError as e:
        print(f"Error: Invalid JSON input - {e}", file=sys.stderr)
        sys.exit(1)

    transformed = transform_workflow(workflow)
    json.dump(transformed, sys.stdout, indent=2)


if __name__ == "__main__":
    main()
