#!/usr/bin/env python3
"""
Unit Tests for Save_Extraction Workflow

Generated test template. Add specific test cases for this workflow.
"""

import json
import pytest
from pathlib import Path


def load_workflow():
    """Load the workflow JSON"""
    workflow_file = Path(__file__).parent.parent / "Save_Extraction.json"
    with open(workflow_file, "r") as f:
        return json.load(f)


class TestSave_Extraction:
    """Test cases for Save_Extraction workflow"""

    def test_workflow_structure(self):
        """Test that the workflow has valid structure"""
        workflow = load_workflow()
        assert workflow["name"] == "Save_Extraction"
        nodes = workflow.get("nodes", [])
        assert len(nodes) >= 20

    def test_emoji_parsing_logic(self):
        """Test the logic that maps emojis to actions"""
        workflow = load_workflow()
        nodes = workflow.get("nodes", [])
        parse_node = next((n for n in nodes if n["name"] == "Parse Emoji Type"), None)
        assert parse_node is not None

        code = parse_node["parameters"]["jsCode"]
        assert "emojiMap" in code
        assert "1️⃣" in code
        assert "❌" in code
        assert "🗑️" in code
        assert "actionType = 'dismiss'" in code
        assert "actionType = 'save_item'" in code
        assert "actionType = 'delete_thread'" in code

    def test_action_routing(self):
        """Test that it routes by action.type"""
        workflow = load_workflow()
        nodes = workflow.get("nodes", [])
        switch_node = next((n for n in nodes if n["name"] == "What Action"), None)
        assert switch_node is not None

        rules = switch_node["parameters"]["rules"]["values"]
        actions = [r["conditions"]["conditions"][0]["rightValue"] for r in rules]
        assert "save_item" in actions
        assert "dismiss" in actions
        assert "delete_thread" in actions

    def test_ctx_preservation(self):
        """Test that it restores ctx after native nodes"""
        workflow = load_workflow()
        nodes = workflow.get("nodes", [])
        merge_nodes = [n for n in nodes if n.get("type") == "n8n-nodes-base.merge"]
        assert len(merge_nodes) >= 3

        # Check for standard "Restore ctx" nodes
        restore_nodes = [n["name"] for n in merge_nodes if "Restore" in n["name"]]
        assert len(restore_nodes) >= 2

    def test_database_operations(self):
        """Test for essential database nodes"""
        workflow = load_workflow()
        nodes = workflow.get("nodes", [])
        pg_nodes = [
            n["name"] for n in nodes if n.get("type") == "n8n-nodes-base.postgres"
        ]

        assert "Promote to Note" in pg_nodes
        assert "Promote to Todo" in pg_nodes
        assert "Get Extraction Item" in pg_nodes


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
