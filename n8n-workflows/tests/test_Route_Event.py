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

    def test_message_validation_logic(self):
        """Test the message validation tier logic"""
        workflow = load_workflow()
        nodes = workflow.get("nodes", [])
        validate_node = next(
            (n for n in nodes if n["name"] == "Validate Message"), None
        )
        assert validate_node is not None

        code = validate_node["parameters"]["jsCode"]
        assert 'validation: { result: "block" }' in code
        assert 'validation: { result: "warn" }' in code
        assert 'validation: { result: "no_projections" }' in code
        assert 'validation: { result: "continue" }' in code

    def test_validation_routing(self):
        """Test that validation result routes to correct nodes"""
        workflow = load_workflow()
        connections = workflow.get("connections", {})

        # Parse Message -> Validate Message
        assert {"node": "Validate Message", "type": "main", "index": 0} in [
            c for c in connections["Parse Message"]["main"][0]
        ]

        # Validate Message -> Switch on Validation
        assert {"node": "Switch on Validation", "type": "main", "index": 0} in [
            c for c in connections["Validate Message"]["main"][0]
        ]

        # Switch outputs
        switch_conns = connections["Switch on Validation"]["main"]
        assert len(switch_conns) >= 4
        assert {
            "node": "React: Block Message",
            "type": "main",
            "index": 0,
        } in switch_conns[0]
        assert {
            "node": "React: Warn Message",
            "type": "main",
            "index": 0,
        } in switch_conns[1]
        assert {
            "node": "React: No Projections",
            "type": "main",
            "index": 0,
        } in switch_conns[2]
        assert {
            "node": "Merge: Continue Paths",
            "type": "main",
            "index": 0,
        } in switch_conns[3]

    def test_switch_logic(self):
        """Test the switch logic for validation results"""
        workflow = load_workflow()
        nodes = workflow.get("nodes", [])
        switch_node = next(
            (n for n in nodes if n["name"] == "Switch on Validation"), None
        )
        assert switch_node is not None

        rules = switch_node["parameters"]["rules"]["values"]
        assert (
            rules[0]["conditions"]["conditions"][0]["leftValue"]
            == "={{ $json.ctx.validation.result }}"
        )
        assert rules[0]["conditions"]["conditions"][0]["rightValue"] == "block"
        assert rules[1]["conditions"]["conditions"][0]["rightValue"] == "warn"
        assert rules[2]["conditions"]["conditions"][0]["rightValue"] == "no_projections"

    def test_no_projections_bypass(self):
        """Test that no_projections tier bypasses extraction via Initialize node"""
        workflow = load_workflow()
        nodes = workflow.get("nodes", [])
        init_node = next(
            (n for n in nodes if n["name"] == "Initialize Message Context"), None
        )
        assert init_node is not None

        code = init_node["parameters"]["jsCode"]
        assert "validation_result === 'no_projections'" in code
        assert "return [];" in code

    def test_tier1_empty_no_tag(self):
        """Test that empty messages without tags trigger block"""
        workflow = load_workflow()
        nodes = workflow.get("nodes", [])
        validate_node = next(
            (n for n in nodes if n["name"] == "Validate Message"), None
        )
        assert validate_node is not None

        code = validate_node["parameters"]["jsCode"]
        # Tier 1: Empty/whitespace (NO TAG)
        assert "!cleanText.trim() && !tag" in code

    def test_tier2_tag_only_messages(self):
        """Test that tag-only messages trigger warn (not block)"""
        workflow = load_workflow()
        nodes = workflow.get("nodes", [])
        validate_node = next(
            (n for n in nodes if n["name"] == "Validate Message"), None
        )
        assert validate_node is not None

        code = validate_node["parameters"]["jsCode"]
        # Tier 2: Tag-only (HAS TAG but no content)
        assert (
            "tag && !cleanText.trim()" in code
            or 'tag && cleanText.trim() === ""' in code
        )


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
