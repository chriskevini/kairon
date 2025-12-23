import pytest
import json
from pathlib import Path


def load_workflow():
    workflow_file = Path(__file__).parent.parent / "Handle_Correction.json"
    with open(workflow_file, "r") as f:
        return json.load(f)


class TestHandle_Correction:
    def test_structural_integrity(self):
        workflow = load_workflow()
        assert "nodes" in workflow
        assert "connections" in workflow

        # Verify essential nodes exist
        node_names = [n["name"] for n in workflow["nodes"]]
        assert "execute_workflow_trigger" in node_names
        assert "build_lookup_query" in node_names
        assert "prepare_correction" in node_names
        assert "build_correction_queries" in node_names
        assert "execute_correction_queries" in node_names

    def test_ctx_pattern_build_lookup(self):
        workflow = load_workflow()
        node = next(n for n in workflow["nodes"] if n["name"] == "build_lookup_query")
        code = node["parameters"]["jsCode"]

        # Should read from ctx.event.message_id
        assert "ctx.event.message_id" in code
        # Should build db_queries
        assert "db_queries" in code
        assert "FROM events" in code

    def test_ctx_pattern_prepare_correction(self):
        workflow = load_workflow()
        node = next(n for n in workflow["nodes"] if n["name"] == "prepare_correction")
        code = node["parameters"]["jsCode"]

        # Should read from ctx.db?.original?.row
        assert "ctx.db?.original?.row" in code
        # Should handle emoji mapping
        assert "emoji_mapping" in code
        assert "original.guild_id" in code

    def test_ctx_pattern_build_correction_queries(self):
        workflow = load_workflow()
        node = next(
            n for n in workflow["nodes"] if n["name"] == "build_correction_queries"
        )
        code = node["parameters"]["jsCode"]

        # Should use $results chaining
        assert "$results.correction_event.row.id" in code
        assert "INSERT INTO events" in code
        assert "UPDATE projections" in code
        assert "status = 'voided'" in code

    def test_ctx_pattern_build_capture_ctx(self):
        workflow = load_workflow()
        node = next(n for n in workflow["nodes"] if n["name"] == "build_capture_ctx")
        code = node["parameters"]["jsCode"]

        # Should build a full ctx for Capture_Projection
        assert "ctx: {" in code
        assert "event: {" in code
        assert "projection: {" in code
        assert "trace_chain" in code

    def test_subworkflow_calls(self):
        workflow = load_workflow()
        exec_nodes = [
            n
            for n in workflow["nodes"]
            if n["type"] == "n8n-nodes-base.executeWorkflow"
        ]

        # Should call Execute_Queries and Capture_Projection
        target_workflows = [
            n["parameters"]["workflowId"]["cachedResultName"]
            for n in exec_nodes
            if "cachedResultName" in n["parameters"]["workflowId"]
        ]
        assert "Execute_Queries" in target_workflows
        assert "Capture_Projection" in target_workflows
