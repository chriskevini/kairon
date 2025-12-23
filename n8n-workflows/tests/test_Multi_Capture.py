#!/usr/bin/env python3
"""
Unit Tests for Multi_Capture Workflow

Generated test template. Add specific test cases for this workflow.
"""

import json
import pytest
from pathlib import Path


def load_workflow():
    """Load the workflow JSON"""
    workflow_file = Path(__file__).parent.parent / "Multi_Capture.json"
    with open(workflow_file, "r") as f:
        return json.load(f)


class TestMulti_Capture:
    """Test cases for Multi_Capture workflow"""

    def test_workflow_structure(self):
        """Test that the workflow has valid structure"""
        workflow = load_workflow()
        assert workflow["name"] == "Multi_Capture"
        nodes = workflow.get("nodes", [])
        assert len(nodes) >= 15

    def test_llm_nodes(self):
        """Test that LLM nodes are present"""
        workflow = load_workflow()
        nodes = workflow.get("nodes", [])
        llm_nodes = [
            n
            for n in nodes
            if "lmChat" in n.get("type", "") or "chainLlm" in n.get("type", "")
        ]
        assert len(llm_nodes) >= 1

    def test_ctx_preservation(self):
        """Test that ctx is preserved in key nodes"""
        workflow = load_workflow()
        nodes = workflow.get("nodes", [])
        prep_node = next((n for n in nodes if n["name"] == "PrepareCapture"), None)
        assert prep_node is not None
        assert "ctx: ctx" in prep_node["parameters"]["jsCode"]

    def test_capture_splitting(self):
        """Test the logic that splits captures into projections"""
        workflow = load_workflow()
        nodes = workflow.get("nodes", [])
        split_node = next((n for n in nodes if n["name"] == "SplitCaptures"), None)
        assert split_node is not None

        code = split_node["parameters"]["jsCode"]
        assert "parseResult.captures.map" in code
        assert "INSERT INTO projections" in code
        assert "trace_id" in code

    def test_database_integration(self):
        """Test that it calls Execute_Queries for storage"""
        workflow = load_workflow()
        nodes = workflow.get("nodes", [])
        exec_queries = [
            n
            for n in nodes
            if n.get("type") == "n8n-nodes-base.executeWorkflow"
            and (
                n.get("parameters", {}).get("workflowId", {}).get("cachedResultName")
                == "Execute_Queries"
                or n["name"] == "store_llm_trace"
            )
        ]
        assert len(exec_queries) >= 1


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
