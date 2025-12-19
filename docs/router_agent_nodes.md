# Router Agent Implementation Plan

The Router Agent needs these nodes in sequence:

## 1. Fetch User Context (before calling agent)
- Get recent activities (last 3)
- Get activity categories
- Get note categories  
- Get user state (sleeping status)

## 2. AI Agent Node
- System prompt from prompts/router-agent.md
- Tools: log_activity, store_note, start_thinking_session, get_recent_context
- Model: Claude or GPT-4

## 3. Route Based on Tool Called
- Switch node to check which tool was called
- Branch to appropriate handler

## Current Issue
The "Router Agent (Agentic)" node at line 253-279 is just a placeholder Set node.
It should be replaced with an "Execute Workflow" node or the full agent logic.

## MVP Approach
For simplicity, let me create a comment in the workflow JSON that explains what needs
to be configured in the n8n UI, since AI Agent nodes with tools are complex to define
in raw JSON.
