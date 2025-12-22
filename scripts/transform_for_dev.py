#!/usr/bin/env python3
"""
Transform workflow JSON for dev environment testing.

Replaces external API calls (Discord, LLM) with mock Code nodes,
and converts Webhook triggers to Execute Workflow Triggers for
pure internal testing.

Usage:
    cat workflow.json | python transform_for_dev.py > transformed.json
    python transform_for_dev.py < workflow.json > transformed.json
"""

import json
import sys


def transform_node(node: dict) -> dict:
    """Transform a single node if it matches replacement criteria."""
    node_type = node.get("type", "")

    # Webhook Trigger → Execute Workflow Trigger
    # Allows smoke tests to invoke workflows directly without HTTP
    if node_type == "n8n-nodes-base.webhook":
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
        node["parameters"] = {
            "jsCode": f'''// Mock LLM Chain node: {original_name}
// Returns fake LLM response for dev testing
const input = $input.first().json;
const inputText = input.ctx?.event?.clean_text 
  || input.text 
  || input.prompt 
  || "unknown input";

return [{{ 
  json: {{ 
    text: "[MOCK LLM] Response for: " + inputText.substring(0, 100),
    _mock: true,
    _original_node: "{original_name}",
    _input_preview: inputText.substring(0, 200)
  }} 
}}];'''
        }
        return node

    # HTTP Request nodes that call external APIs could also be mocked here
    # if needed in the future

    return node


def transform_workflow(workflow: dict) -> dict:
    """Transform all nodes in a workflow for dev environment."""
    if "nodes" not in workflow:
        return workflow

    workflow["nodes"] = [transform_node(node) for node in workflow["nodes"]]

    # Add a marker to indicate this workflow was transformed
    if not workflow.get("meta"):
        workflow["meta"] = {}
    workflow["meta"]["transformedForDev"] = True

    return workflow


def main():
    try:
        workflow = json.load(sys.stdin)
    except json.JSONDecodeError as e:
        print(f"Error: Invalid JSON input - {e}", file=sys.stderr)
        sys.exit(1)

    transformed = transform_workflow(workflow)
    json.dump(transformed, sys.stdout, indent=2)


if __name__ == "__main__":
    main()
