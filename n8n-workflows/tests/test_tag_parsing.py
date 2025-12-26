#!/usr/bin/env python3
"""
Unit Tests for Tag Parsing Logic
Ported from n8n-workflows-dev/Smoke_Test.json
"""

import pytest

TAG_TABLE = [
    ["!!", "act"],
    ["..", "note"],
    ["++", "chat"],
    ["--", "save"],
    ["::", "cmd"],
    ["$$", "todo", "to-do"],
]


def parse_tag(content):
    lower = content.lower()
    for row in TAG_TABLE:
        norm = row[0]
        # Match symbol or word alias
        match = None
        for a in row:
            al = a.lower()
            is_symbol = not any(c.isalnum() for c in al)
            if is_symbol:
                if lower.startswith(al):
                    match = a
                    break
            else:
                if lower.startswith(al + " ") or lower == al:
                    match = a
                    break

        if match:
            return {"tag": norm, "clean_text": content[len(match) :].strip()}

    return {"tag": None, "clean_text": content}


@pytest.mark.parametrize(
    "input_text,expected_tag,expected_clean",
    [
        # Symbol tags
        ("!! did work", "!!", "did work"),
        ("..thinking", "..", "thinking"),
        ("++ chat", "++", "chat"),
        ("-- save", "--", "save"),
        ("::help", "::", "help"),
        ("$$ todo", "$$", "todo"),
        # Word aliases
        ("act work", "!!", "work"),
        ("note thought", "..", "thought"),
        ("chat hello", "++", "hello"),
        ("save this", "--", "this"),
        ("cmd list", "::", "list"),
        ("todo buy milk", "$$", "buy milk"),
        # No tag
        ("no tag here", None, "no tag here"),
        # Glued symbols (should match)
        ("!!glued", "!!", "glued"),
        # Glued words (should NOT match - requires space)
        ("actglued", None, "actglued"),
        # Empty after tag
        ("!!", "!!", ""),
        ("act", "!!", ""),
        # Case sensitivity
        ("ACT work", "!!", "work"),
        ("..THINKING", "..", "THINKING"),
    ],
)
def test_tag_parsing(input_text, expected_tag, expected_clean):
    result = parse_tag(input_text)
    assert result["tag"] == expected_tag
    assert result["clean_text"] == expected_clean


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
