#!/usr/bin/env python3
import json
import os
import sys
import re
from pathlib import Path

def fix_json_string_content(content):
    """Fix control characters in JSON string content by properly escaping them."""
    
    # Pattern to match JSON string literals (including escaped quotes)
    string_pattern = r'"([^"\\]*(?:\\.[^"\\]*)*)"'
    
    def fix_string(match):
        string_content = match.group(1)
        # Escape control characters that aren't already properly escaped
        fixed = string_content
        
        # Replace literal newlines, tabs, etc. with their escaped equivalents
        # but only if they're not already escaped
        replacements = {
            '\n': '\\n',
            '\r': '\\r', 
            '\t': '\\t',
            '\b': '\\b',
            '\f': '\\f',
            '\v': '\\v',
            '\x1b': '\\x1b',  # escape
        }
        
        # For control characters that aren't standard whitespace
        for i in range(32):
            if chr(i) not in ['\n', '\r', '\t']:
                if chr(i) in fixed:
                    fixed = fixed.replace(chr(i), f'\\x{i:02x}')
        
        # Apply standard whitespace escaping
        for char, escaped in replacements.items():
            if char in fixed:
                fixed = fixed.replace(char, escaped)
        
        return f'"{fixed}"'
    
    # Apply the fix to all string literals
    fixed_content = re.sub(string_pattern, fix_string, content, flags=re.DOTALL)
    
    return fixed_content

def test_and_fix_json_file(filepath):
    """Test and fix a JSON file if needed."""
    content = None
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            content = f.read()
        
        # Try to parse first
        json.loads(content)
        return True, "Already valid", content
        
    except json.JSONDecodeError as e:
        # Try to fix it
        if content is None:
            return False, f"Could not read file: {e}", ""
        fixed_content = fix_json_string_content(content)
        
        try:
            # Test if the fix worked
            json.loads(fixed_content)
            return True, "Fixed successfully", fixed_content
        except json.JSONDecodeError as e2:
            return False, f"Still broken: {e2}", content

def main():
    script_dir = Path(__file__).parent
    workflow_dir = script_dir / "n8n-workflows"
    broken_files = [
        "Continue_Chat.json",
        "Start_Chat.json", 
        "Save_Chat.json"
    ]
    
    print("Attempting to fix broken JSON files...")
    print("=" * 60)
    
    fixed_files = []
    still_broken = []
    
    for filename in broken_files:
        filepath = os.path.join(workflow_dir, filename)
        print(f"\nProcessing {filename}...")
        
        # Backup original
        with open(filepath, 'r', encoding='utf-8') as f:
            original_content = f.read()
        
        success, message, fixed_content = test_and_fix_json_file(filepath)
        
        if success and "Fixed" in message:
            # Write the fixed content
            with open(filepath, 'w', encoding='utf-8') as f:
                f.write(fixed_content)
            print(f"  ✅ {message}")
            fixed_files.append(filename)
        elif success and "Already" in message:
            print(f"  ✅ {message}")
        else:
            print(f"  ❌ {message}")
            still_broken.append(filename)
    
    print(f"\n{'='*60}")
    print(f"FIX SUMMARY:")
    print(f"- Files processed: {len(broken_files)}")
    print(f"- Files fixed: {len(fixed_files)}")
    print(f"- Still broken: {len(still_broken)}")
    
    if fixed_files:
        print(f"\nSuccessfully fixed:")
        for filename in fixed_files:
            print(f"  - {filename}")
    
    if still_broken:
        print(f"\nStill need manual fixing:")
        for filename in still_broken:
            print(f"  - {filename}")

if __name__ == "__main__":
    main()