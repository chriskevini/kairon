#!/usr/bin/env python3
"""
Refactor Proactive_Pulse to use Execute_Queries pattern for database operations.

Changes:
- Replace StoreTrace + MergeTraceResult + StoreProjection + MergeForDiscord + UpdateProjectionWithMessageId
- With: PrepareDbQueries → Execute_Queries → PrepareForDiscord
- Reduces node count and follows best practices
"""

import json
import sys


def main():
    # Load the workflow
    with open("n8n-workflows/Proactive_Pulse.json", "r") as f:
        workflow = json.load(f)

    # Get nodes and connections
    nodes = workflow["nodes"]
    connections = workflow["connections"]

    # Find nodes to remove
    nodes_to_remove = [
        "StoreTrace",
        "MergeTraceResult",
        "StoreProjection",
        "MergeForDiscord",
        "UpdateProjectionWithMessageId",
    ]
    nodes[:] = [n for n in nodes if n["name"] not in nodes_to_remove]

    # Add new PrepareDbQueries node (replaces MergeTraceResult position)
    prepare_db_queries_node = {
        "parameters": {
            "jsCode": """// Prepare db_queries for Execute_Queries: trace → projection
const ctx = $json.ctx;
const eventId = ctx.event.event_id;
const traceChainPg = ctx.event.trace_chain_pg;
const timezone = ctx.event.timezone || 'UTC';

// Pre-stringify projection data for Postgres
const projectionData = {
  timestamp: new Date().toISOString(),
  text: $json.message,
  context_description: $json.context_description,
  technique_source: $json.technique_source
};

return {
  json: {
    ctx: {
      ...ctx,
      db_queries: [
        {
          key: 'trace',
          sql: `INSERT INTO traces (event_id, step_name, data, trace_chain)
                VALUES ($1::uuid, 'proactive_agent', $2::jsonb, $3::uuid[])
                RETURNING id, trace_chain || id AS updated_trace_chain`,
          params: [
            eventId,
            JSON.stringify({
              prompt: $json.assembled_prompt,
              completion: $json.llm_response,
              context_description: $json.context_description,
              technique_source: $json.technique_source,
              input_summary: $json.input_summary,
              duration_ms: $json.duration_ms
            }),
            traceChainPg
          ]
        },
        {
          key: 'projection',
          sql: `INSERT INTO projections (trace_id, event_id, trace_chain, projection_type, data, status, timezone)
                VALUES ($1::uuid, $2::uuid, $3::uuid[], 'pulse', $4::jsonb, 'auto_confirmed', $5)
                RETURNING id`,
          params: [
            '$results.trace.row.id',
            eventId,
            '$results.trace.row.updated_trace_chain',
            JSON.stringify(projectionData),
            timezone
          ]
        }
      ],
      // Pass through data needed after Execute_Queries
      temp: {
        message: $json.message,
        is_empty: $json.is_empty
      }
    }
  }
};""",
            "mode": "runOnceForEachItem",
        },
        "type": "n8n-nodes-base.code",
        "typeVersion": 2,
        "position": [4256, 96],
        "id": "prepare-db-queries",
        "name": "PrepareDbQueries",
    }

    # Add new StoreTraceAndProjection ExecuteWorkflow node
    store_trace_projection_node = {
        "parameters": {
            "workflowId": {
                "__rl": True,
                "value": "CgUAxK0i4YhrZ2Wp",
                "mode": "list",
                "cachedResultName": "Execute_Queries",
                "cachedResultUrl": "/workflow/CgUAxK0i4YhrZ2Wp",
            },
            "workflowInputs": {
                "mappingMode": "defineBelow",
                "value": {"ctx": "={{ $json.ctx }}"},
            },
            "options": {"waitForSubWorkflow": True},
        },
        "type": "n8n-nodes-base.executeWorkflow",
        "typeVersion": 1.3,
        "position": [4480, 96],
        "id": "store-trace-and-projection",
        "name": "StoreTraceAndProjection",
    }

    # Add new PrepareForDiscord node
    prepare_for_discord_node = {
        "parameters": {
            "jsCode": """// Prepare data for Discord and additional updates
const ctx = $json.ctx;
const message = ctx.temp?.message || '';
const isEmpty = ctx.temp?.is_empty || false;
const projectionId = ctx.db?.projection?.row?.id;

return {
  json: {
    ctx: {
      ...ctx,
      // Clean up temp namespace
      temp: undefined
    },
    message: message,
    is_empty: isEmpty,
    projection_id: projectionId
  }
};""",
            "mode": "runOnceForEachItem",
        },
        "type": "n8n-nodes-base.code",
        "typeVersion": 2,
        "position": [4704, 96],
        "id": "prepare-for-discord",
        "name": "PrepareForDiscord",
    }

    # Add new PrepareDiscordUpdate node (after SendMessage)
    prepare_discord_update_node = {
        "parameters": {
            "jsCode": """// Prepare Discord message ID update query
const discordResult = $json;
const prepData = $('PrepareForDiscord').first().json;
const ctx = prepData.ctx;

return {
  json: {
    ctx: {
      ...ctx,
      db_queries: [{
        key: 'update_projection',
        sql: `UPDATE projections 
              SET data = data || jsonb_build_object(
                'discord_message_id', $1,
                'discord_channel_id', $2,
                'discord_guild_id', $3
              )
              WHERE id = $4::uuid
              RETURNING id`,
        params: [
          discordResult.id,
          $env.DISCORD_CHANNEL_ARCANE_SHELL,
          $env.DISCORD_GUILD_ID,
          prepData.projection_id
        ]
      }]
    }
  }
};""",
            "mode": "runOnceForEachItem",
        },
        "type": "n8n-nodes-base.code",
        "typeVersion": 2,
        "position": [5376, 176],
        "id": "prepare-discord-update",
        "name": "PrepareDiscordUpdate",
    }

    # Add new UpdateProjection Execute_Queries call
    update_projection_node = {
        "parameters": {
            "workflowId": {
                "__rl": True,
                "value": "CgUAxK0i4YhrZ2Wp",
                "mode": "list",
                "cachedResultName": "Execute_Queries",
                "cachedResultUrl": "/workflow/CgUAxK0i4YhrZ2Wp",
            },
            "workflowInputs": {
                "mappingMode": "defineBelow",
                "value": {"ctx": "={{ $json.ctx }}"},
            },
            "options": {"waitForSubWorkflow": True},
        },
        "type": "n8n-nodes-base.executeWorkflow",
        "typeVersion": 1.3,
        "position": [5600, 176],
        "id": "update-projection-with-message-id",
        "name": "UpdateProjectionWithMessageId",
    }

    nodes.extend(
        [
            prepare_db_queries_node,
            store_trace_projection_node,
            prepare_for_discord_node,
            prepare_discord_update_node,
            update_projection_node,
        ]
    )

    # Update connections
    # ParseLlmResponse → PrepareDbQueries (and UpdateNextPulse in parallel)
    connections["ParseLlmResponse"] = {
        "main": [
            [
                {"node": "PrepareDbQueries", "type": "main", "index": 0},
                {"node": "UpdateNextPulse", "type": "main", "index": 0},
            ]
        ]
    }

    # PrepareDbQueries → StoreTraceAndProjection
    connections["PrepareDbQueries"] = {
        "main": [[{"node": "StoreTraceAndProjection", "type": "main", "index": 0}]]
    }

    # StoreTraceAndProjection → PrepareForDiscord
    connections["StoreTraceAndProjection"] = {
        "main": [[{"node": "PrepareForDiscord", "type": "main", "index": 0}]]
    }

    # PrepareForDiscord → IfEmptyMessage
    connections["PrepareForDiscord"] = {
        "main": [[{"node": "IfEmptyMessage", "type": "main", "index": 0}]]
    }

    # IfEmptyMessage → false branch → SendMessage
    connections["IfEmptyMessage"] = {
        "main": [
            [],  # true branch (empty message) - no connection
            [{"node": "SendMessage", "type": "main", "index": 0}],  # false branch
        ]
    }

    # SendMessage → PrepareDiscordUpdate
    connections["SendMessage"] = {
        "main": [[{"node": "PrepareDiscordUpdate", "type": "main", "index": 0}]]
    }

    # PrepareDiscordUpdate → UpdateProjectionWithMessageId
    connections["PrepareDiscordUpdate"] = {
        "main": [
            [{"node": "UpdateProjectionWithMessageId", "type": "main", "index": 0}]
        ]
    }

    # UpdateProjectionWithMessageId → AddDiagnosticReaction
    connections["UpdateProjectionWithMessageId"] = {
        "main": [[{"node": "AddDiagnosticReaction", "type": "main", "index": 0}]]
    }

    # Remove old connections for deleted nodes
    for node_name in nodes_to_remove:
        connections.pop(node_name, None)

    # Write the refactored workflow
    with open("n8n-workflows/Proactive_Pulse.json", "w") as f:
        json.dump(workflow, f, indent=2)

    print(f"✅ Refactored Proactive_Pulse successfully")
    print(f"   - Removed {len(nodes_to_remove)} nodes")
    print(f"   - Added 5 new nodes following Execute_Queries pattern")
    print(f"   - New node count: {len(nodes)}")


if __name__ == "__main__":
    main()
