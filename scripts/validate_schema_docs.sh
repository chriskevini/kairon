#!/bin/bash
# validate_schema_docs.sh - Check if DATABASE.md matches db/schema.sql

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SCHEMA_FILE="$REPO_ROOT/db/schema.sql"
DOCS_FILE="$REPO_ROOT/docs/DATABASE.md"

echo "🔍 Validating schema documentation consistency..."
echo "Schema file: $SCHEMA_FILE"
echo "Docs file: $DOCS_FILE"
echo ""

# Check if schema file exists
if [ ! -f "$SCHEMA_FILE" ]; then
    echo "❌ Schema file not found: $SCHEMA_FILE"
    exit 1
fi

# Check if docs file exists
if [ ! -f "$DOCS_FILE" ]; then
    echo "❌ Docs file not found: $DOCS_FILE"
    exit 1
fi

# Extract table names from schema.sql
echo "📋 Tables defined in schema.sql:"
SCHEMA_TABLES=$(grep "CREATE TABLE" "$SCHEMA_FILE" | sed 's/.*CREATE TABLE.* \([a-zA-Z_]*\) (.*/\1/' | sort | uniq)
echo "$SCHEMA_TABLES"
echo ""

# Extract table names from DATABASE.md (look for headers after Core Tables)
echo "📖 Tables documented in DATABASE.md:"
DOCS_TABLES=$(sed -n '/^## Core Tables/,/^## Relationships/ p' "$DOCS_FILE" | grep "^### [a-zA-Z_]" | sed 's/### \([a-zA-Z_]*\).*/\1/' | sort | uniq)
echo "$DOCS_TABLES"
echo ""

# Compare table lists
if [ "$SCHEMA_TABLES" != "$DOCS_TABLES" ]; then
    echo "⚠️  Table list mismatch!"
    echo "Schema has: $(echo "$SCHEMA_TABLES" | tr '\n' ' ')"
    echo "Docs have:  $(echo "$DOCS_TABLES" | tr '\n' ' ')"
    echo ""
    echo "💡 Update docs/DATABASE.md to match db/schema.sql"
    exit 1
else
    echo "✅ Table lists match"
fi

# Check schema version in header
SCHEMA_VERSION=$(grep "Schema version:" "$SCHEMA_FILE" | sed 's/.*Schema version: //' || echo "unknown")
DOCS_VERSION=$(grep "**Schema Version:**" "$DOCS_FILE" | awk '{print $3}' | grep -E '^[0-9]+$' || echo "unknown")

if [ "$SCHEMA_VERSION" != "$DOCS_VERSION" ] && [ "$SCHEMA_VERSION" != "unknown" ]; then
    echo "⚠️  Schema version mismatch!"
    echo "Schema: $SCHEMA_VERSION"
    echo "Docs: $DOCS_VERSION"
    echo ""
    echo "💡 Update version in docs/DATABASE.md"
    exit 1
else
    echo "✅ Schema versions match ($SCHEMA_VERSION)"
fi

# Check last sync date
SCHEMA_DATE=$(grep "Last synced:" "$SCHEMA_FILE" | sed 's/.*Last synced: //' || echo "unknown")
TODAY=$(date +%Y-%m-%d)

if [ "$SCHEMA_DATE" != "$TODAY" ]; then
    echo "💡 Consider updating 'Last synced' date in db/schema.sql to $TODAY"
fi

echo ""
echo "✅ Schema documentation validation complete!"
echo ""
echo "📝 To update docs after schema changes:"
echo "1. Edit docs/DATABASE.md to match new schema"
echo "2. Update 'Last synced' date in db/schema.sql"
echo "3. Update schema version if applicable"
echo "4. Run this script to validate: ./scripts/validate_schema_docs.sh"