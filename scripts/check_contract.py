#!/usr/bin/env python3
"""Check public API, diagnostic codes, and provider fixture digests."""

from __future__ import annotations

import hashlib
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
source = "\n".join(path.read_text(encoding="utf-8") for path in sorted((ROOT / "src").glob("*.cj")))


def normalize_declaration(value: str) -> str:
    return re.sub(r"\s+", " ", value).strip()


def mask_non_code(value: str) -> str:
    """Preserve offsets while hiding comments and literals from brace matching."""
    output = list(value)
    index = 0
    state = "code"
    while index < len(value):
        current = value[index]
        following = value[index + 1] if index + 1 < len(value) else ""
        if state == "code" and current == "/" and following == "/":
            output[index] = output[index + 1] = " "
            index += 2
            state = "line"
            continue
        if state == "code" and current == "/" and following == "*":
            output[index] = output[index + 1] = " "
            index += 2
            state = "block"
            continue
        if state == "code" and current in {'"', "'"}:
            output[index] = " "
            index += 1
            state = "string" if current == '"' else "character"
            continue
        if state == "line":
            if current == "\n":
                state = "code"
            else:
                output[index] = " "
            index += 1
            continue
        if state == "block":
            if current == "*" and following == "/":
                output[index] = output[index + 1] = " "
                index += 2
                state = "code"
            else:
                if current != "\n":
                    output[index] = " "
                index += 1
            continue
        if state in {"string", "character"}:
            quote = '"' if state == "string" else "'"
            if current == "\\":
                output[index] = " "
                if index + 1 < len(value):
                    output[index + 1] = " "
                index += 2
            elif current == quote:
                output[index] = " "
                index += 1
                state = "code"
            else:
                if current != "\n":
                    output[index] = " "
                index += 1
            continue
        index += 1
    return "".join(output)


def matching_brace(masked: str, opening: int) -> int:
    depth = 0
    for index in range(opening, len(masked)):
        if masked[index] == "{":
            depth += 1
        elif masked[index] == "}":
            depth -= 1
            if depth == 0:
                return index
    raise SystemExit("unbalanced public declaration while building API shape")


def public_api_shape(value: str) -> list[str]:
    """Capture exported type shapes, enum cases, members, and callable signatures."""
    masked = mask_non_code(value)
    depth_at = [0] * (len(masked) + 1)
    depth = 0
    for index, character in enumerate(masked):
        depth_at[index] = depth
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
    declarations: list[str] = []
    type_pattern = re.compile(r"^public\s+(class|enum|interface|struct)\s+([A-Za-z][A-Za-z0-9_]*)", re.MULTILINE)
    member_pattern = re.compile(r"^[ \t]*public\s+(?:let|var|prop|init|(?:static\s+)?func|operator\s+func)\b", re.MULTILINE)

    for found in type_pattern.finditer(masked):
        if depth_at[found.start()] != 0:
            continue
        kind = found.group(1)
        name = found.group(2)
        opening = masked.find("{", found.start())
        closing = matching_brace(masked, opening)
        header = normalize_declaration(value[found.start():opening])
        previous_line_start = value.rfind("\n", 0, found.start() - 1) + 1
        previous = value[previous_line_start:found.start()].strip()
        if previous.startswith("@Derive["):
            header = normalize_declaration(previous) + " " + header
        declarations.append(header)

        if kind == "enum":
            body_mask = masked[opening + 1:closing]
            member = member_pattern.search(body_mask)
            end = member.start() if member else len(body_mask)
            variants = normalize_declaration(value[opening + 1:opening + 1 + end])
            if variants:
                declarations.append(name + " cases " + variants)
        elif kind == "interface":
            body = normalize_declaration(value[opening + 1:closing])
            if body:
                declarations.append(name + " members " + body)
        else:
            body_mask = masked[opening + 1:closing]
            for member in member_pattern.finditer(body_mask):
                absolute = opening + 1 + member.start()
                if depth_at[absolute] != 1:
                    continue
                line_end = masked.find("\n", absolute)
                brace = masked.find("{", absolute)
                keyword = member.group(0).strip().split()[1]
                if keyword in {"let", "var"} or brace < 0 or (line_end >= 0 and line_end < brace and "(" not in masked[absolute:line_end]):
                    end = line_end if line_end >= 0 else closing
                else:
                    end = brace
                declarations.append(name + " member " + normalize_declaration(value[absolute:end]))

    function_pattern = re.compile(r"^public\s+func\s+[A-Za-z]", re.MULTILINE)
    for found in function_pattern.finditer(masked):
        if depth_at[found.start()] != 0:
            continue
        opening = masked.find("{", found.start())
        declarations.append(normalize_declaration(value[found.start():opening]))
    return sorted(declarations)

api = sorted(
    f"{kind} {name}"
    for kind, name in re.findall(
        r"^public\s+(class|enum|interface|struct|func)\s+([A-Za-z][A-Za-z0-9_]*)",
        source,
        re.MULTILINE,
    )
)
expected_api = (ROOT / "contract/public-api.txt").read_text(encoding="utf-8").splitlines()
if api != expected_api:
    raise SystemExit("public API snapshot drifted; update contract/public-api.txt intentionally")

api_shape = public_api_shape(source)
api_shape_digest = hashlib.sha256(("\n".join(api_shape) + "\n").encode("utf-8")).hexdigest()
expected_api_shape_digest = (ROOT / "contract/public-api-shape.sha256").read_text(encoding="utf-8").strip()
if api_shape_digest != expected_api_shape_digest:
    raise SystemExit("public API shape drifted; update contract/public-api-shape.sha256 intentionally")

codes = sorted(set(re.findall(r'"(llm\.[a-z0-9_.]+)"', source)))
expected_codes = (ROOT / "contract/error-codes.txt").read_text(encoding="utf-8").splitlines()
if codes != expected_codes:
    raise SystemExit("error-code inventory drifted; update contract/error-codes.txt intentionally")

digest = hashlib.sha256()
fixtures = (
    sorted((ROOT / "fixtures").glob("*.json"))
    + sorted((ROOT / "fixtures/requests").glob("*.json"))
    + sorted((ROOT / "fixtures/streams").glob("*.json"))
)
if len(fixtures) != 18:
    raise SystemExit(f"expected six response, six request, and six stream dialect fixtures, found {len(fixtures)}")
for path in fixtures:
    digest.update(path.relative_to(ROOT / "fixtures").as_posix().encode("utf-8") + b"\0" + path.read_bytes() + b"\0")
actual_digest = digest.hexdigest()
expected_digest = (ROOT / "contract/fixture-digest.txt").read_text(encoding="utf-8").strip()
if actual_digest != expected_digest:
    raise SystemExit(f"fixture digest drifted: {actual_digest}")

print(f"contract check passed: {len(api)} declarations, {len(api_shape)} API shapes, {len(codes)} codes, {len(fixtures)} fixtures")
