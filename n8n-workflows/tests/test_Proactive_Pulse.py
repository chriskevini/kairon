#!/usr/bin/env python3
"""
Unit Tests for Proactive_Pulse Workflow

Tests the structure, node configuration, and logic of the Proactive_Pulse workflow.
"""

import json
import pytest
from pathlib import Path


def load_workflow():
    """Load the workflow JSON"""
    workflow_file = Path(__file__).parent.parent / "Proactive_Pulse.json"
    with open(workflow_file, "r") as f:
        return json.load(f)


class TestProactive_Pulse:
    """Test cases for Proactive_Pulse workflow"""

    def test_workflow_structure(self):
        """Test that the workflow has valid structure"""
        workflow = load_workflow()
        assert workflow["name"] == "Proactive_Pulse"
        nodes = workflow.get("nodes", [])
        assert len(nodes) >= 27  # Complex workflow with many nodes

    def test_entry_points(self):
        """Test that it has the two expected entry points"""
        workflow = load_workflow()
        nodes = workflow.get("nodes", [])
        trigger_types = [n.get("type") for n in nodes]

        # Should have schedule trigger and execute workflow trigger
        # Note: Schedule trigger transforms to webhook in dev for testing
        assert "n8n-nodes-base.scheduleTrigger" in trigger_types
        assert "n8n-nodes-base.executeWorkflowTrigger" in trigger_types

        # Find the schedule trigger and verify it's every 5 minutes
        schedule_node = next(
            n for n in nodes if n["type"] == "n8n-nodes-base.scheduleTrigger"
        )
        assert schedule_node["name"] == "Every5Minutes"
        assert (
            schedule_node["parameters"]["rule"]["interval"][0]["minutesInterval"] == 5
        )

    def test_cron_path_nodes(self):
        """Test that the cron trigger path has all required nodes"""
        workflow = load_workflow()
        nodes = workflow.get("nodes", [])
        node_names = [n["name"] for n in nodes]

        # Cron trigger path
        assert "Every5Minutes" in node_names
        assert "CheckNextPulse" in node_names
        assert "ShouldRunPulse?" in node_names
        assert "SetDefaultNextPulse" in node_names
        assert "PrepareCronData" in node_names

    def test_workflow_trigger_path(self):
        """Test that the workflow trigger path exists"""
        workflow = load_workflow()
        nodes = workflow.get("nodes", [])
        node_names = [n["name"] for n in nodes]

        assert "WhenCalledByAnotherWorkflow" in node_names

    def test_core_processing_nodes(self):
        """Test that all core processing nodes exist"""
        workflow = load_workflow()
        nodes = workflow.get("nodes", [])
        node_names = [n["name"] for n in nodes]

        # Event and context setup
        assert "PrepareEvent" in node_names
        assert "InsertEvent" in node_names
        assert "InitializeCtx" in node_names

        # Query execution
        assert "ExecuteQueries" in node_names
        assert "BuildContextSummary" in node_names

        # Semantic selection and RAG
        assert "SemanticSelectTechniques" in node_names
        assert "EmbedContextForRag" in node_names
        assert "PrepareEmbeddingForRag" in node_names
        assert "RagSimilarProjections" in node_names
        assert "MergeSemanticResults" in node_names

        # LLM and message generation
        assert "AssemblePrompt" in node_names
        assert "GenerateMessageWithLlm" in node_names
        assert "ParseLlmResponse" in node_names

        # Database and Discord
        assert "PrepareDbQueries" in node_names
        assert "StoreTraceAndProjection" in node_names
        assert "PrepareForDiscord" in node_names
        assert "IfEmptyMessage" in node_names
        assert "SendMessage" in node_names
        assert "UpdateNextPulse" in node_names

    def test_check_next_pulse_query(self):
        """Test that CheckNextPulse has correct SQL"""
        workflow = load_workflow()
        nodes = workflow.get("nodes", [])
        check_node = next((n for n in nodes if n["name"] == "CheckNextPulse"), None)
        assert check_node is not None

        query = check_node["parameters"]["query"]
        # Should get next_pulse and check if it's time to run
        assert "next_pulse" in query
        assert "config" in query
        assert "should_run" in query
        assert "<=" in query  # Comparison for time check

    def test_set_default_next_pulse_has_lock(self):
        """Test that SetDefaultNextPulse uses advisory lock"""
        workflow = load_workflow()
        nodes = workflow.get("nodes", [])
        set_node = next((n for n in nodes if n["name"] == "SetDefaultNextPulse"), None)
        assert set_node is not None

        query = set_node["parameters"]["query"]
        # Should use advisory lock to prevent concurrent executions
        assert "pg_advisory_xact_lock" in query
        assert "proactive_pulse" in query
        assert "next_pulse" in query
        assert "INTERVAL '2 hours'" in query

    def test_prepare_event_creates_idempotency_key(self):
        """Test that PrepareEvent creates correct idempotency key"""
        workflow = load_workflow()
        nodes = workflow.get("nodes", [])
        prepare_node = next((n for n in nodes if n["name"] == "PrepareEvent"), None)
        assert prepare_node is not None

        code = prepare_node["parameters"]["jsCode"]
        assert "idempotency_key" in code
        assert "scheduled:proactive:" in code
        assert "trigger_reason" in code
        assert "timestamp" in code

    def test_insert_event_query(self):
        """Test that InsertEvent creates system event"""
        workflow = load_workflow()
        nodes = workflow.get("nodes", [])
        insert_node = next((n for n in nodes if n["name"] == "InsertEvent"), None)
        assert insert_node is not None

        query = insert_node["parameters"]["query"]
        assert "INSERT INTO events" in query
        assert "event_type" in query
        assert "'system'" in query
        assert "proactive_agent" in query
        assert "ON CONFLICT" in query  # Should handle duplicate idempotency keys

    def test_initialize_ctx_structure(self):
        """Test that InitializeCtx sets up ctx correctly"""
        workflow = load_workflow()
        nodes = workflow.get("nodes", [])
        init_node = next((n for n in nodes if n["name"] == "InitializeCtx"), None)
        assert init_node is not None

        code = init_node["parameters"]["jsCode"]
        # Should initialize ctx with event and db_queries
        assert "ctx: {" in code
        assert "event: {" in code
        assert "event_id:" in code
        assert "db_queries:" in code
        assert "prompt_modules" in code
        assert "recent_activities" in code
        assert "recent_notes" in code
        assert "pending_todos" in code
        assert "north_star" in code

    def test_execute_queries_called_correctly(self):
        """Test that ExecuteQueries workflow is called"""
        workflow = load_workflow()
        nodes = workflow.get("nodes", [])
        execute_node = next((n for n in nodes if n["name"] == "ExecuteQueries"), None)
        assert execute_node is not None

        assert execute_node["type"] == "n8n-nodes-base.executeWorkflow"
        # Should reference Execute_Queries workflow
        assert (
            execute_node["parameters"]["workflowId"]["cachedResultName"]
            == "Execute_Queries"
        )

    def test_build_context_summary_logic(self):
        """Test that BuildContextSummary processes ctx.db correctly"""
        workflow = load_workflow()
        nodes = workflow.get("nodes", [])
        build_node = next(
            (n for n in nodes if n["name"] == "BuildContextSummary"), None
        )
        assert build_node is not None

        code = build_node["parameters"]["jsCode"]
        # Should extract data from ctx.db
        assert "ctx.db" in code
        assert "prompt_modules" in code
        assert "recent_activities" in code
        assert "recent_notes" in code
        assert "pending_todos" in code
        # Should build context summary
        assert "context_summary" in code
        assert "technique_candidates" in code

    def test_semantic_selection_http_request(self):
        """Test that SemanticSelectTechniques calls embedding service"""
        workflow = load_workflow()
        nodes = workflow.get("nodes", [])
        semantic_node = next(
            (n for n in nodes if n["name"] == "SemanticSelectTechniques"), None
        )
        assert semantic_node is not None

        assert semantic_node["type"] == "n8n-nodes-base.httpRequest"
        params = semantic_node["parameters"]
        assert params["method"] == "POST"
        assert "EMBEDDING_SERVICE_URL" in params["url"]
        assert "/search" in params["url"]
        # Should continue on fail (embedding service optional)
        assert semantic_node.get("continueOnFail") == True

    def test_embed_context_http_request(self):
        """Test that EmbedContextForRag calls embedding service"""
        workflow = load_workflow()
        nodes = workflow.get("nodes", [])
        embed_node = next((n for n in nodes if n["name"] == "EmbedContextForRag"), None)
        assert embed_node is not None

        assert embed_node["type"] == "n8n-nodes-base.httpRequest"
        params = embed_node["parameters"]
        assert params["method"] == "POST"
        assert "EMBEDDING_SERVICE_URL" in params["url"]
        assert "/embed" in params["url"]
        assert embed_node.get("continueOnFail") == True

    def test_rag_similar_projections_query(self):
        """Test that RagSimilarProjections uses pgvector"""
        workflow = load_workflow()
        nodes = workflow.get("nodes", [])
        rag_node = next(
            (n for n in nodes if n["name"] == "RagSimilarProjections"), None
        )
        assert rag_node is not None

        query = rag_node["parameters"]["query"]
        # Should use pgvector distance operator
        assert "<=>" in query
        assert "::vector" in query
        assert "embeddings" in query
        assert "projections" in query
        assert "ORDER BY" in query
        assert "LIMIT" in query
        # Should continue on fail (RAG optional)
        assert rag_node.get("continueOnFail") == True

    def test_merge_semantic_results(self):
        """Test that MergeSemanticResults merges two inputs"""
        workflow = load_workflow()
        nodes = workflow.get("nodes", [])
        merge_node = next(
            (n for n in nodes if n["name"] == "MergeSemanticResults"), None
        )
        assert merge_node is not None

        assert merge_node["type"] == "n8n-nodes-base.merge"
        params = merge_node["parameters"]
        assert params["mode"] == "append"
        assert params["numberInputs"] == 2

    def test_assemble_prompt_processes_all_data(self):
        """Test that AssemblePrompt combines all context"""
        workflow = load_workflow()
        nodes = workflow.get("nodes", [])
        assemble_node = next((n for n in nodes if n["name"] == "AssemblePrompt"), None)
        assert assemble_node is not None

        code = assemble_node["parameters"]["jsCode"]
        # Should process all merged data
        assert "allItems" in code or "$input.all()" in code
        assert "ctx" in code
        assert "prompt_modules" in code
        assert "assembled_prompt" in code
        # Should handle timezone
        assert "timezone" in code

    def test_generate_message_uses_langchain(self):
        """Test that GenerateMessageWithLlm uses LangChain"""
        workflow = load_workflow()
        nodes = workflow.get("nodes", [])
        generate_node = next(
            (n for n in nodes if n["name"] == "GenerateMessageWithLlm"), None
        )
        assert generate_node is not None

        assert generate_node["type"] == "@n8n/n8n-nodes-langchain.chainLlm"
        params = generate_node["parameters"]
        assert params["promptType"] == "define"
        assert "assembled_prompt" in params["text"]

    def test_restore_ctx_after_llm(self):
        """Test that RestoreCtx restores context after LLM call"""
        workflow = load_workflow()
        nodes = workflow.get("nodes", [])
        restore_node = next((n for n in nodes if n["name"] == "RestoreCtx"), None)
        assert restore_node is not None

        code = restore_node["parameters"]["jsCode"]
        # Should restore ctx from AssemblePrompt
        assert "AssemblePrompt" in code
        assert "ctx" in code

    def test_parse_llm_response_handles_json(self):
        """Test that ParseLlmResponse handles JSON and fallback"""
        workflow = load_workflow()
        nodes = workflow.get("nodes", [])
        parse_node = next((n for n in nodes if n["name"] == "ParseLlmResponse"), None)
        assert parse_node is not None

        code = parse_node["parameters"]["jsCode"]
        # Should parse JSON with fallback
        assert "JSON.parse" in code
        assert "message" in code
        assert "next_pulse_minutes" in code
        assert "try" in code or "catch" in code  # Error handling
        assert "is_empty" in code

    def test_update_next_pulse_query(self):
        """Test that UpdateNextPulse sets next pulse time"""
        workflow = load_workflow()
        nodes = workflow.get("nodes", [])
        update_node = next((n for n in nodes if n["name"] == "UpdateNextPulse"), None)
        assert update_node is not None

        query = update_node["parameters"]["query"]
        assert "UPDATE config" in query
        assert "next_pulse" in query
        assert "::interval" in query
        assert "minutes" in query

    def test_prepare_db_queries_for_trace_and_projection(self):
        """Test that PrepareDbQueries sets up trace and projection inserts"""
        workflow = load_workflow()
        nodes = workflow.get("nodes", [])
        prepare_node = next((n for n in nodes if n["name"] == "PrepareDbQueries"), None)
        assert prepare_node is not None

        code = prepare_node["parameters"]["jsCode"]
        # Should prepare queries for Execute_Queries
        assert "db_queries" in code
        assert "trace" in code
        assert "projection" in code
        assert "INSERT INTO traces" in code
        assert "INSERT INTO projections" in code
        assert "projection_type" in code
        assert "'pulse'" in code

    def test_store_trace_and_projection_calls_execute_queries(self):
        """Test that StoreTraceAndProjection calls Execute_Queries"""
        workflow = load_workflow()
        nodes = workflow.get("nodes", [])
        store_node = next(
            (n for n in nodes if n["name"] == "StoreTraceAndProjection"), None
        )
        assert store_node is not None

        assert store_node["type"] == "n8n-nodes-base.executeWorkflow"
        params = store_node["parameters"]
        assert params["workflowId"]["cachedResultName"] == "Execute_Queries"
        # Should pass ctx
        assert params["workflowInputs"]["value"]["ctx"] == "={{ $json.ctx }}"

    def test_if_empty_message_condition(self):
        """Test that IfEmptyMessage checks for empty messages"""
        workflow = load_workflow()
        nodes = workflow.get("nodes", [])
        if_node = next((n for n in nodes if n["name"] == "IfEmptyMessage"), None)
        assert if_node is not None

        assert if_node["type"] == "n8n-nodes-base.if"
        conditions = if_node["parameters"]["conditions"]["conditions"]
        assert len(conditions) >= 1
        # Should check is_empty flag
        assert "is_empty" in conditions[0]["leftValue"]

    def test_send_message_to_discord(self):
        """Test that SendMessage posts to Discord"""
        workflow = load_workflow()
        nodes = workflow.get("nodes", [])
        send_node = next((n for n in nodes if n["name"] == "SendMessage"), None)
        assert send_node is not None

        assert send_node["type"] == "n8n-nodes-base.discord"
        params = send_node["parameters"]
        assert params["resource"] == "message"
        assert "DISCORD_CHANNEL_ARCANE_SHELL" in params["channelId"]["value"]
        assert params["content"] == "={{ $json.message }}"
        # Should have retries configured
        assert send_node.get("retryOnFail") == True

    def test_prepare_discord_update_query(self):
        """Test that PrepareDiscordUpdate prepares message ID update"""
        workflow = load_workflow()
        nodes = workflow.get("nodes", [])
        prepare_node = next(
            (n for n in nodes if n["name"] == "PrepareDiscordUpdate"), None
        )
        assert prepare_node is not None

        code = prepare_node["parameters"]["jsCode"]
        # Should prepare update query for projection
        assert "db_queries" in code
        assert "UPDATE projections" in code
        assert "discord_message_id" in code

    def test_workflow_connections_cron_path(self):
        """Test that cron trigger path connections are correct"""
        workflow = load_workflow()
        connections = workflow.get("connections", {})

        # Every5Minutes -> CheckNextPulse
        assert "Every5Minutes" in connections
        assert any(
            c["node"] == "CheckNextPulse"
            for c in connections["Every5Minutes"]["main"][0]
        )

        # CheckNextPulse -> ShouldRunPulse?
        assert "CheckNextPulse" in connections
        assert any(
            c["node"] == "ShouldRunPulse?"
            for c in connections["CheckNextPulse"]["main"][0]
        )

        # ShouldRunPulse? -> SetDefaultNextPulse (true branch)
        assert "ShouldRunPulse?" in connections
        assert len(connections["ShouldRunPulse?"]["main"]) >= 1
        assert any(
            c["node"] == "SetDefaultNextPulse"
            for c in connections["ShouldRunPulse?"]["main"][0]
        )

        # SetDefaultNextPulse -> PrepareCronData
        assert "SetDefaultNextPulse" in connections
        assert any(
            c["node"] == "PrepareCronData"
            for c in connections["SetDefaultNextPulse"]["main"][0]
        )

        # PrepareCronData -> PrepareEvent
        assert "PrepareCronData" in connections
        assert any(
            c["node"] == "PrepareEvent"
            for c in connections["PrepareCronData"]["main"][0]
        )

    def test_workflow_connections_main_path(self):
        """Test that main processing path connections are correct"""
        workflow = load_workflow()
        connections = workflow.get("connections", {})

        # PrepareEvent -> InsertEvent -> InitializeCtx -> ExecuteQueries
        assert "PrepareEvent" in connections
        assert "InsertEvent" in connections
        assert "InitializeCtx" in connections

        # ExecuteQueries -> BuildContextSummary
        assert "ExecuteQueries" in connections
        assert any(
            c["node"] == "BuildContextSummary"
            for c in connections["ExecuteQueries"]["main"][0]
        )

        # BuildContextSummary splits to SemanticSelectTechniques and EmbedContextForRag
        assert "BuildContextSummary" in connections
        build_conns = connections["BuildContextSummary"]["main"][0]
        assert len(build_conns) == 2
        nodes = [c["node"] for c in build_conns]
        assert "SemanticSelectTechniques" in nodes
        assert "EmbedContextForRag" in nodes

    def test_workflow_connections_merge_path(self):
        """Test that merge and prompt assembly path is correct"""
        workflow = load_workflow()
        connections = workflow.get("connections", {})

        # Both semantic paths -> MergeSemanticResults
        assert "SemanticSelectTechniques" in connections
        assert any(
            c["node"] == "MergeSemanticResults"
            for c in connections["SemanticSelectTechniques"]["main"][0]
        )

        # RagSimilarProjections -> MergeSemanticResults (second input)
        assert "RagSimilarProjections" in connections
        assert any(
            c["node"] == "MergeSemanticResults"
            for c in connections["RagSimilarProjections"]["main"][0]
        )

        # MergeSemanticResults -> AssemblePrompt
        assert "MergeSemanticResults" in connections
        assert any(
            c["node"] == "AssemblePrompt"
            for c in connections["MergeSemanticResults"]["main"][0]
        )

    def test_workflow_connections_llm_path(self):
        """Test that LLM and response handling path is correct"""
        workflow = load_workflow()
        connections = workflow.get("connections", {})

        # AssemblePrompt -> GenerateMessageWithLlm
        assert "AssemblePrompt" in connections
        assert any(
            c["node"] == "GenerateMessageWithLlm"
            for c in connections["AssemblePrompt"]["main"][0]
        )

        # GenerateMessageWithLlm -> RestoreCtx
        assert "GenerateMessageWithLlm" in connections
        assert any(
            c["node"] == "RestoreCtx"
            for c in connections["GenerateMessageWithLlm"]["main"][0]
        )

        # RestoreCtx -> ParseLlmResponse
        assert "RestoreCtx" in connections
        assert any(
            c["node"] == "ParseLlmResponse"
            for c in connections["RestoreCtx"]["main"][0]
        )

        # ParseLlmResponse splits to PrepareDbQueries and UpdateNextPulse
        assert "ParseLlmResponse" in connections
        parse_conns = connections["ParseLlmResponse"]["main"][0]
        nodes = [c["node"] for c in parse_conns]
        assert "PrepareDbQueries" in nodes
        assert "UpdateNextPulse" in nodes

    def test_workflow_connections_discord_path(self):
        """Test that Discord message path is correct"""
        workflow = load_workflow()
        connections = workflow.get("connections", {})

        # PrepareDbQueries -> StoreTraceAndProjection
        assert "PrepareDbQueries" in connections
        assert any(
            c["node"] == "StoreTraceAndProjection"
            for c in connections["PrepareDbQueries"]["main"][0]
        )

        # StoreTraceAndProjection -> PrepareForDiscord
        assert "StoreTraceAndProjection" in connections
        assert any(
            c["node"] == "PrepareForDiscord"
            for c in connections["StoreTraceAndProjection"]["main"][0]
        )

        # PrepareForDiscord -> IfEmptyMessage
        assert "PrepareForDiscord" in connections
        assert any(
            c["node"] == "IfEmptyMessage"
            for c in connections["PrepareForDiscord"]["main"][0]
        )

        # IfEmptyMessage -> SendMessage (false branch - not empty)
        assert "IfEmptyMessage" in connections
        if_conns = connections["IfEmptyMessage"]["main"]
        # False branch (index 1) should go to SendMessage
        assert len(if_conns) >= 2
        assert any(c["node"] == "SendMessage" for c in if_conns[1])

        # SendMessage -> PrepareDiscordUpdate
        assert "SendMessage" in connections
        assert any(
            c["node"] == "PrepareDiscordUpdate"
            for c in connections["SendMessage"]["main"][0]
        )

        # PrepareDiscordUpdate -> UpdateProjectionWithMessageId
        assert "PrepareDiscordUpdate" in connections
        assert any(
            c["node"] == "UpdateProjectionWithMessageId"
            for c in connections["PrepareDiscordUpdate"]["main"][0]
        )

    def test_error_workflow_configured(self):
        """Test that error workflow is configured"""
        workflow = load_workflow()
        settings = workflow.get("settings", {})
        assert "errorWorkflow" in settings
        # Should have error workflow ID
        assert settings["errorWorkflow"] is not None


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
