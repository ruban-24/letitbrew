#!/usr/bin/env python3
"""Reject pathname-based filesystem transport in the agent install command."""
import re
import sys
from pathlib import Path


def call_expression(text: str, start: int) -> str:
    opening = text.find("(", start)
    if opening < 0:
        return ""
    depth = 0
    quote = None
    escaped = False
    for index in range(opening, len(text)):
        char = text[index]
        if quote:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = None
            continue
        if char in "\"'":
            quote = char
        elif char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return text[start:index + 1]
    return text[start:]


def violations(text: str) -> list[str]:
    errors: list[str] = []
    patterns = {
        "/dev/fd": r"/dev/fd",
        "unanchored ExactFileTarget": r"ExactFileTarget\s*\.\s*ordinary\s*\(",
        "Data contentsOf": r"Data\s*\(\s*contentsOf\s*:",
        "Data write(to:)": r"\.write\s*\(\s*to\s*:",
        "FileManager mutation": r"FileManager\s*\.\s*default\s*\.\s*(?:createDirectory|removeItem|moveItem|replaceItem)\s*\(",
    }
    errors.extend(f"forbidden transport: {name}" for name, pattern in patterns.items() if re.search(pattern, text, re.S))
    for match in re.finditer(r"AtomicFile\.(?:write|remove)\s*\(", text):
        expression = call_expression(text, match.start())
        if re.search(r"\b(?:to|ifUnchangedFrom)\s*:", expression):
            errors.append("legacy URL AtomicFile overload")
    # `openat` is descriptor-relative. Any plain `open(` in command flow is a
    # pathname mutation/reopen and must not be reintroduced, including across
    # formatting changes.
    if re.search(r"(?<![A-Za-z0-9_])open\s*\(", text):
        errors.append("path-based open in agent install command flow")
    return errors


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: check-agent-install-transport.py InstallCommand.swift", file=sys.stderr)
        return 2
    issues = violations(Path(sys.argv[1]).read_text())
    if issues:
        print("AGENT_INSTALL_TRANSPORT_GATE_FAILED: " + "; ".join(issues), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
