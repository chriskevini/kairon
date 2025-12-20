#!/usr/bin/env python3
import json
import os
import sys
import re

def test_json_file(filepath):
    """Test if a JSON file can be parsed and return any errors."""
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            json.load(f)
        return None, None
    except json.JSONDecodeError as e:
        return str(e), e.lineno
    except Exception as e:
        return str(e), None

def find_control_characters(content):
    """Find control characters in JSON strings that need escaping."""
    control_chars = []
    lines = content.split('\n')
    
    for line_num, line in enumerate(lines, 1):
        # Look for unescaped control characters in string literals
        in_string = False
        escape_next = False
        string_start = 0
        
        for i, char in enumerate(line):
            if escape_next:
                escape_next = False
                continue
                
            if char == '\\' and in_string:
                escape_next = True
                continue
                
            if char == '"' and not escape_next:
                in_string = not in_string
                if in_string:
                    string_start = i
                continue
                
            if in_string and ord(char) < 32 and char not in ['\n', '\r', '\t']:
                control_chars.append({
                    'line': line_num,
                    'position': i,
                    'char': repr(char),
                    'char_code': ord(char),
                    'context': line[max(0, string_start-10):i+10]
                })
    
    return control_chars

def fix_control_characters(content):
    """Fix control characters by properly escaping them."""
    # Replace common control characters with their escaped equivalents
    fixes = [
        ('\x0b', '\\v'),   # vertical tab
        ('\x0c', '\\f'),   # form feed
        ('\x1b', '\\e'),   # escape
        ('\x08', '\\b'),   # backspace
        ('\x0c', '\\f'),   # form feed
        ('\x0b', '\\v'),   # vertical tab
        ('\x19', '\\x19'), # end of medium
        ('\x01', '\\x01'), # start of heading
        ('\x02', '\\x02'), # start of text
        ('\x03', '\\x03'), # end of text
        ('\x04', '\\x04'), # end of transmission
        ('\x05', '\\x05'), # enquiry
        ('\x06', '\\x06'), # acknowledge
        ('\x07', '\\a'),   # bell
        ('\x0e', '\\x0e'), # shift out
        ('\x0f', '\\x0f'), # shift in
        ('\x10', '\\x10'), # data link escape
        ('\x11', '\\x11'), # device control 1
        ('\x12', '\\x12'), # device control 2
        ('\x13', '\\x13'), # device control 3
        ('\x14', '\\x14'), # device control 4
        ('\x15', '\\x15'), # negative acknowledge
        ('\x16', '\\x16'), # synchronous idle
        ('\x17', '\\x17'), # end of transmission block
        ('\x18', '\\x18'), # cancel
        ('\x1a', '\\x1a'), # substitute
        ('\x1c', '\\x1c'), # file separator
        ('\x1d', '\\x1d'), # group separator
        ('\x1e', '\\x1e'), # record separator
        ('\x1f', '\\x1f'), # unit separator
    ]
    
    fixed_content = content
    for control_char, escape_seq in fixes:
        fixed_content = fixed_content.replace(control_char, escape_seq)
    
    return fixed_content

def main():
    workflow_dir = "/home/chris/Work/kairon/n8n-workflows"
    json_files = [f for f in os.listdir(workflow_dir) if f.endswith('.json')]
    
    print(f"Testing {len(json_files)} JSON files...")
    print("=" * 60)
    
    broken_files = []
    fixed_files = []
    
    for filename in json_files:
        filepath = os.path.join(workflow_dir, filename)
        print(f"\nTesting {filename}...", end=' ')
        
        error, line_num = test_json_file(filepath)
        
        if error:
            print(f"❌ BROKEN")
            print(f"  Error: {error}")
            if line_num:
                print(f"  Line: {line_num}")
            
            # Read the file and check for control characters
            with open(filepath, 'r', encoding='utf-8') as f:
                content = f.read()
            
            control_chars = find_control_characters(content)
            if control_chars:
                print(f"  Found {len(control_chars)} control characters:")
                for cc in control_chars[:3]:  # Show first 3
                    print(f"    Line {cc['line']}: {cc['char']} (code {cc['char_code']})")
                    print(f"      Context: ...{cc['context']}...")
            
            broken_files.append({
                'filename': filename,
                'filepath': filepath,
                'error': error,
                'line_num': line_num,
                'control_chars': control_chars
            })
        else:
            print(f"✅ OK")
    
    if broken_files:
        print(f"\n{'='*60}")
        print(f"Found {len(broken_files)} broken files. Attempting to fix...")
        
        for file_info in broken_files:
            filename = file_info['filename']
            filepath = file_info['filepath']
            
            print(f"\nFixing {filename}...")
            
            # Read original content
            with open(filepath, 'r', encoding='utf-8') as f:
                original_content = f.read()
            
            # Fix control characters
            fixed_content = fix_control_characters(original_content)
            
            # Write fixed content
            with open(filepath, 'w', encoding='utf-8') as f:
                f.write(fixed_content)
            
            # Test the fix
            error, line_num = test_json_file(filepath)
            if error:
                print(f"  ❌ Still broken: {error}")
            else:
                print(f"  ✅ Fixed successfully!")
                fixed_files.append(filename)
    
    print(f"\n{'='*60}")
    print(f"SUMMARY:")
    print(f"- Total files tested: {len(json_files)}")
    print(f"- Files broken: {len(broken_files)}")
    print(f"- Files fixed: {len(fixed_files)}")
    
    if fixed_files:
        print(f"\nFixed files:")
        for filename in fixed_files:
            print(f"  - {filename}")
    
    if broken_files and len(fixed_files) != len(broken_files):
        print(f"\nStill broken files:")
        for file_info in broken_files:
            if file_info['filename'] not in fixed_files:
                print(f"  - {file_info['filename']}: {file_info['error']}")

if __name__ == "__main__":
    main()