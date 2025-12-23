#!/usr/bin/env python3
import json
import sys
import re
from pathlib import Path


def fix_json_string_content(content):
    string_pattern = r'"([^"\\]*(?:\\.[^"\\]*)*)"'

    def fix_string(match):
        string_content = match.group(1)
        fixed = string_content
        replacements = {
            "\n": "\\n",
            "\r": "\\r",
            "\t": "\\t",
            "\b": "\\b",
            "\f": "\\f",
            "\v": "\\v",
            "\x1b": "\\x1b",
        }
        for i in range(32):
            if chr(i) not in ["\n", "\r", "\t"]:
                if chr(i) in fixed:
                    fixed = fixed.replace(chr(i), f"\\x{i:02x}")
        for char, escaped in replacements.items():
            if char in fixed:
                fixed = fixed.replace(char, escaped)
        return f'"{fixed}"'

    return re.sub(string_pattern, fix_string, content, flags=re.DOTALL)


def main():
    if len(sys.argv) < 2:
        print("Usage: fix_json.py <file1> <file2> ...")
        sys.exit(1)

    for filepath in sys.argv[1:]:
        path = Path(filepath)
        if not path.exists():
            print(f"File not found: {filepath}")
            continue

        print(f"Processing {filepath}...")
        content = path.read_text(encoding="utf-8")

        try:
            json.loads(content)
            print("  Already valid")
            continue
        except json.JSONDecodeError:
            fixed_content = fix_json_string_content(content)
            try:
                json.loads(fixed_content)
                path.write_text(fixed_content, encoding="utf-8")
                print("  Fixed successfully")
            except json.JSONDecodeError as e:
                print(f"  Still broken: {e}")


if __name__ == "__main__":
    main()
