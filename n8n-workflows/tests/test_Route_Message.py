#!/usr/bin/env python3
"""
Unit Tests for Route_Message Workflow

Generated test template. Add specific test cases for this workflow.
"""

import json
import pytest
from pathlib import Path


def load_workflow():
    """Load the workflow JSON"""
    workflow_file = Path(__file__).parent.parent / "Route_Message.json"
    with open(workflow_file, "r") as f:
        return json.load(f)


class TestRoute_Message:
    """Test cases for Route_Message workflow"""

    def test_workflow_structure(self):
        """Test that the workflow has valid structure"""
        workflow = load_workflow()
        assert workflow["name"] == "Route_Message"
        nodes = workflow.get("nodes", [])
        assert len(nodes) >= 10

    def test_entry_point(self):
        """Test that the entry point is Receive Event"""
        workflow = load_workflow()
        nodes = workflow.get("nodes", [])
        triggers = [
            n for n in nodes if n.get("type") == "n8n-nodes-base.executeWorkflowTrigger"
        ]
        assert len(triggers) == 1
        assert triggers[0]["name"] == "ReceiveEvent"

    def test_tag_routing_rules(self):
        """Test that all required tags are routed"""
        workflow = load_workflow()
        nodes = workflow.get("nodes", [])
        route_node = next((n for n in nodes if n["name"] == "RouteByTag"), None)
        assert route_node is not None

        rules = route_node["parameters"]["rules"]["values"]
        tags = [r["conditions"]["conditions"][0]["rightValue"] for r in rules]

        assert "!!" in tags  # activity
        assert ".." in tags  # note
        assert "$$" in tags  # todo
        assert "++" in tags  # chat
        assert "::" in tags  # command

    def test_projection_preparation(self):
        """Test that projection type is correctly prepared"""
        workflow = load_workflow()
        nodes = workflow.get("nodes", [])
        prep_node = next((n for n in nodes if n["name"] == "PrepareProjection"), None)
        assert prep_node is not None

        code = prep_node["parameters"]["jsCode"]
        assert "ctx.event.tag" in code
        assert "tagToType" in code
        assert "projection" in code

    def test_subworkflow_calls(self):
        """Test that essential subworkflows are called"""
        workflow = load_workflow()
        nodes = workflow.get("nodes", [])
        subworkflows = [
            n["name"]
            for n in nodes
            if n.get("type") == "n8n-nodes-base.executeWorkflow"
        ]

        assert "MultiCapture" in subworkflows
        assert "CaptureProjection" in subworkflows
        assert "ExecuteCommand" in subworkflows
        assert "StartThread" in subworkflows


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
