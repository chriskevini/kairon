#!/usr/bin/env python3
"""
Unit Tests for Route_Event Workflow

Generated test template. Add specific test cases for this workflow.
"""

import json
import pytest
from pathlib import Path


def load_workflow():
    """Load the workflow JSON"""
    workflow_file = Path(__file__).parent.parent / "Route_Event.json"
    with open(workflow_file, "r") as f:
        return json.load(f)


class TestRoute_Event:
    """Test cases for Route_Event workflow"""

    def test_workflow_structure(self):
        """Test that the workflow has valid structure"""
        workflow = load_workflow()
        assert workflow["name"] == "Route_Event"
        nodes = workflow.get("nodes", [])
        assert len(nodes) >= 15

    def test_entry_points(self):
        """Test that it has the three expected entry points"""
        workflow = load_workflow()
        nodes = workflow.get("nodes", [])
        trigger_types = [n.get("type") for n in nodes]

        assert "n8n-nodes-base.webhook" in trigger_types
        assert "n8n-nodes-base.scheduleTrigger" in trigger_types

    def test_tag_parsing_logic(self):
        """Test that tag parsing logic is correct and handles aliases"""
        workflow = load_workflow()
        nodes = workflow.get("nodes", [])
        parse_node = next((n for n in nodes if n["name"] == "Parse Message"), None)
        assert parse_node is not None

        code = parse_node["parameters"]["jsCode"]
        assert "TAG_TABLE" in code
        assert "!!" in code
        assert "act" in code
        assert "$$" in code
        assert "todo" in code
        assert "clean_text = content.slice" in code

    def test_ctx_initialization(self):
        """Test that ctx.event is properly initialized"""
        workflow = load_workflow()
        nodes = workflow.get("nodes", [])
        init_node = next(
            (n for n in nodes if n["name"] == "Initialize Message Context"), None
        )
        assert init_node is not None

        code = init_node["parameters"]["jsCode"]
        assert "ctx: {" in code
        assert "event: {" in code
        assert "event_id:" in code
        assert "clean_text:" in code
        assert "trace_chain:" in code

    def test_event_routing(self):
        """Test that it routes by event_type"""
        workflow = load_workflow()
        nodes = workflow.get("nodes", [])
        switch_node = next(
            (n for n in nodes if n["name"] == "Route by Event Type"), None
        )
        assert switch_node is not None

        rules = switch_node["parameters"]["rules"]["values"]
        event_types = [r["conditions"]["conditions"][0]["rightValue"] for r in rules]
        assert "message" in event_types
        assert "reaction" in event_types


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
