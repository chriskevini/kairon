#!/usr/bin/env python3
"""
Unit Tests for Execute_Queries Workflow

Generated test template. Add specific test cases for this workflow.
"""

import json
import pytest
from pathlib import Path


def load_workflow():
    """Load the workflow JSON"""
    workflow_file = Path(__file__).parent.parent / "Execute_Queries.json"
    with open(workflow_file, "r") as f:
        return json.load(f)


class TestExecute_Queries:
    """Test cases for Execute_Queries workflow"""

    def test_workflow_structure(self):
        """Test that the workflow has valid structure"""
        workflow = load_workflow()
        assert workflow["name"] == "Execute_Queries"
        nodes = workflow.get("nodes", [])
        assert len(nodes) >= 5

    def test_loop_logic(self):
        """Test the loop initialization and empty array handling"""
        workflow = load_workflow()
        nodes = workflow.get("nodes", [])
        init_node = next((n for n in nodes if n["name"] == "InitializeLoop"), None)
        assert init_node is not None

        code = init_node["parameters"]["jsCode"]
        assert "db_queries" in code
        assert "has_more: false" in code  # Empty check
        assert "queries: ctx.db_queries" in code

    def test_finalize_logic(self):
        """Test how context is finalized"""
        workflow = load_workflow()
        nodes = workflow.get("nodes", [])
        finalize_node = next(
            (n for n in nodes if n["name"] == "FinalizeContext"), None
        )
        assert finalize_node is not None

        code = finalize_node["parameters"]["jsCode"]
        assert "ctx:" in code
        assert "state.results" in code
        assert "original_ctx" in code

    def test_database_node(self):
        """Test that the postgres node is present and correctly configured"""
        workflow = load_workflow()
        nodes = workflow.get("nodes", [])
        pg_node = next(
            (n for n in nodes if n.get("type") == "n8n-nodes-base.postgres"), None
        )
        assert pg_node is not None
        assert pg_node["parameters"]["operation"] == "executeQuery"


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
