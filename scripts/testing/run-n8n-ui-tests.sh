#!/bin/bash
# n8n UI Compatibility Test Runner
# Runs comprehensive UI compatibility tests for workflows

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Configuration
N8N_TEST_PORT=5679
WORKFLOW_DIR="$REPO_ROOT/n8n-workflows"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check dependencies
check_dependencies() {
    local missing_deps=()

    if ! command -v node &> /dev/null; then
        missing_deps+=("node")
    fi

    if ! command -v npm &> /dev/null; then
        missing_deps+=("npm")
    fi

    if ! command -v python3 &> /dev/null; then
        missing_deps+=("python3")
    fi

    if ! command -v google-chrome &> /dev/null && ! command -v chromium-browser &> /dev/null; then
        missing_deps+=("google-chrome or chromium-browser")
    fi

    if [ ${#missing_deps[@]} -ne 0 ]; then
        echo -e "${RED}❌ Missing dependencies: ${missing_deps[*]}${NC}"
        echo "Please install missing dependencies and try again."
        exit 1
    fi
}

# Install test dependencies
setup_test_environment() {
    echo "🔧 Setting up test environment..."

    # Install selenium if not available
    if ! python3 -c "import selenium" 2>/dev/null; then
        echo "Installing selenium..."
        pip3 install selenium webdriver-manager 2>/dev/null || {
            echo -e "${YELLOW}⚠️  Could not install selenium via pip3. UI tests will be skipped.${NC}"
            return 1
        }
    fi

    # Check if n8n can be installed
    if ! npm list -g n8n 2>/dev/null; then
        echo "Installing n8n globally..."
        npm install -g n8n 2>/dev/null || {
            echo -e "${YELLOW}⚠️  Could not install n8n globally. Tests will use API-only mode.${NC}"
            return 1
        }
    fi

    return 0
}

# Run UI compatibility tests
run_ui_tests() {
    local test_mode="$1"
    local workflow_files=()

    # Find workflow files
    while IFS= read -r -d '' file; do
        workflow_files+=("$file")
    done < <(find "$WORKFLOW_DIR" -name "*.json" -print0)

    if [ ${#workflow_files[@]} -eq 0 ]; then
        echo -e "${RED}❌ No workflow files found in $WORKFLOW_DIR${NC}"
        return 1
    fi

    echo -e "${GREEN}🧪 Running n8n UI Compatibility Tests${NC}"
    echo "Mode: $test_mode"
    echo "Workflows to test: ${#workflow_files[@]}"
    echo ""

    # Run the Python test suite
    local test_args=("${workflow_files[@]}")

    case "$test_mode" in
        "full")
            test_args+=("--port" "$N8N_TEST_PORT")
            ;;
        "api-only")
            test_args+=("--api-only")
            ;;
        "headed")
            test_args+=("--port" "$N8N_TEST_PORT" "--no-headless")
            ;;
    esac

    if python3 "$SCRIPT_DIR/n8n-ui-tester.py" "${test_args[@]}"; then
        echo -e "\n${GREEN}✅ UI compatibility tests completed successfully${NC}"
        return 0
    else
        echo -e "\n${RED}❌ UI compatibility tests failed${NC}"
        return 1
    fi
}

# Main execution
main() {
    local test_mode="api-only"  # Default to API-only to avoid complex setup

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --full)
                test_mode="full"
                shift
                ;;
            --api-only)
                test_mode="api-only"
                shift
                ;;
            --headed)
                test_mode="headed"
                shift
                ;;
            --help)
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Run n8n UI compatibility tests for workflows"
                echo ""
                echo "Options:"
                echo "  --full      Run full UI tests with headless browser (default)"
                echo "  --api-only  Run API-only tests (no browser)"
                echo "  --headed    Run full UI tests with visible browser"
                echo "  --help      Show this help"
                exit 0
                ;;
            *)
                echo -e "${RED}❌ Unknown option: $1${NC}"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done

    echo "🔍 n8n UI Compatibility Test Suite"
    echo "=================================="

    # Check dependencies
    check_dependencies

    # Setup test environment
    if ! setup_test_environment; then
        if [ "$test_mode" != "api-only" ]; then
            echo -e "${YELLOW}⚠️  Falling back to API-only mode${NC}"
            test_mode="api-only"
        fi
    fi

    # Run tests
    run_ui_tests "$test_mode"
}

# Run main function
main "$@"