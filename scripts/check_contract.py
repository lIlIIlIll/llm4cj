#!/usr/bin/env python3
"""Check public API, diagnostic codes, and provider fixture digests."""

from __future__ import annotations

import hashlib
import datetime
import json
import re
import argparse
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent.parent
production_sources = [path for path in sorted((ROOT / "src").glob("*.cj")) if not path.name.endswith("_test.cj")]
source = "\n".join(path.read_text(encoding="utf-8") for path in production_sources)


# This is a lexical contract, not a compiler AST. Keep its verified boundary visible.
API_SHAPE_COVERAGE = {
    "covered": (
        "public class/struct/enum/interface headers and declaration annotations",
        "enum cases with associated types; explicit public fields and constructors",
        "public methods/operators/properties, including interface implicit visibility",
        "modifiers, generics/where bounds, parameter names/types/named markers/defaults, returns",
        "property get/set signatures; implementation bodies and comments excluded",
        "escaped, triple-quoted and hash-delimited literals; nested block comments and delimiters",
    ),
    "unverified": (
        "macro-expanded declarations and conditional compilation semantics",
        "extend/type aliases, primary constructors and implicit generated members",
        "modal/local declarations, FFI-specific syntax and interpolated-expression parsing",
    ),
}
MODIFIERS = frozenset(
    "public private internal protected static override redef abstract sealed open foreign "
    "unsafe operator const mut common specific required".split()
)
TYPE_KINDS = frozenset({"class", "enum", "interface", "struct"})
MEMBER_KINDS = frozenset({"let", "var", "prop", "init", "func"})
LITERAL_RE = re.compile(r'(\#*)("""|\'\'\'|"|\')')
IDENTIFIER_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*|`[^`\n]+`")


@dataclass(frozen=True)
class ApiToken:
    value: str
    line: int


def api_tokens(value: str) -> list[ApiToken]:
    """Tokenize declaration text without interpreting literals as Cangjie code."""
    tokens: list[ApiToken] = []
    index, line = 0, 1
    while index < len(value):
        start, token_line = index, line
        if value[index].isspace():
            line += value[index] == "\n"
            index += 1
            continue
        if value.startswith("//", index):
            end = value.find("\n", index)
            index = len(value) if end < 0 else end
            continue
        if value.startswith("/*", index):
            depth = 1
            index += 2
            while depth and index < len(value):
                if value.startswith("/*", index):
                    depth += 1
                    index += 2
                elif value.startswith("*/", index):
                    depth -= 1
                    index += 2
                else:
                    line += value[index] == "\n"
                    index += 1
            if depth:
                raise SystemExit("unterminated comment while building API shape")
            continue
        literal = LITERAL_RE.match(value, index)
        if literal:
            hashes, quote = literal.groups()
            terminator = quote + hashes
            index += len(literal.group())
            while index < len(value):
                if value.startswith(terminator, index):
                    index += len(terminator)
                    break
                if not hashes and value[index] == "\\":
                    line += value[index:index + 2].count("\n")
                    index += 2
                else:
                    line += value[index] == "\n"
                    index += 1
            else:
                raise SystemExit("unterminated literal while building API shape")
        else:
            identifier = IDENTIFIER_RE.match(value, index)
            index += len(identifier.group()) if identifier else 1
        tokens.append(ApiToken(value[start:index], token_line))
    return tokens


def public_api_shape(value: str) -> list[str]:
    """Extract the lexical API subset listed in API_SHAPE_COVERAGE."""
    tokens = api_tokens(value)
    pairs: dict[int, int] = {}
    depths: list[int] = []
    stack: list[int] = []
    for index, token in enumerate(tokens):
        depths.append(len(stack))
        if token.value in {"(", "[", "{"}:
            stack.append(index)
        elif token.value in {")", "]", "}"}:
            if not stack or tokens[stack[-1]].value != {")": "(", "]": "[", "}": "{"}[token.value]:
                raise SystemExit("unbalanced declaration while building API shape")
            opening = stack.pop()
            pairs[opening], pairs[index] = index, opening
    if stack:
        raise SystemExit("unbalanced declaration while building API shape")

    def text(start: int, end: int) -> str:
        return " ".join(token.value.replace("\\", "\\\\").replace("\r", "\\r").replace("\n", "\\n")
                        for token in tokens[start:end])

    def prefix(index: int) -> int:
        while index and tokens[index - 1].value in MODIFIERS:
            index -= 1
        while index:
            end = index - 1
            beginning = pairs[end] if tokens[end].value in {"]", ")"} else end + 1
            name = beginning - 1
            if name >= 1 and tokens[name - 1].value == "@":
                index = name - 1
            elif end >= 1 and tokens[end - 1].value == "@":
                index = end - 1
            else:
                break
        return index

    def starts_declaration(index: int) -> bool:
        while index < len(tokens) and tokens[index].value in MODIFIERS:
            index += 1
        return index < len(tokens) and tokens[index].value in TYPE_KINDS | MEMBER_KINDS

    def signature_end(index: int, limit: int, field: bool = False) -> int:
        cursor = index + 1
        while cursor < limit:
            current = tokens[cursor].value
            if current in {"{", ";", "}"} or field and current == "=":
                return cursor
            if (tokens[cursor].line > tokens[cursor - 1].line and
                    starts_declaration(cursor)):
                return cursor
            if current in {"(", "["}:
                cursor = pairs[cursor] + 1
            else:
                cursor += 1
        return cursor

    declarations: list[str] = []
    for index, token in enumerate(tokens):
        if depths[index] != 0 or token.value not in TYPE_KINDS | {"func"}:
            continue
        start = prefix(index)
        if "public" not in [item.value for item in tokens[start:index]]:
            continue
        opening = signature_end(index, len(tokens))
        declarations.append(text(start, opening))
        if token.value == "func":
            continue
        if opening == len(tokens) or tokens[opening].value != "{":
            raise SystemExit("public type has no body while building API shape")
        closing, name = pairs[opening], tokens[index + 1].value
        members = [member for member in range(opening + 1, closing)
                   if depths[member] == 1 and tokens[member].value in MEMBER_KINDS]
        if token.value == "enum":
            end = prefix(members[0]) if members else closing
            if end > opening + 1:
                declarations.append(name + " cases " + text(opening + 1, end).rstrip(" ;"))
        for member in members:
            start = prefix(member)
            modifiers = {item.value for item in tokens[start:member]}
            if "public" not in modifiers and not (
                    token.value == "interface" and not modifiers.intersection({"private", "internal", "protected"})):
                continue
            end = signature_end(member, closing, tokens[member].value in {"let", "var"})
            declaration = name + " member " + text(start, end)
            if tokens[member].value == "prop" and tokens[end].value == "{":
                accessors: list[str] = []
                for accessor in range(end + 1, pairs[end]):
                    if depths[accessor] == 2 and tokens[accessor].value in {"get", "set"}:
                        accessors.append(text(prefix(accessor), signature_end(accessor, pairs[end])))
                declaration += " accessors " + " ; ".join(accessors)
            declarations.append(declaration)
    return sorted(declarations)

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--write-api-shape", action="store_true",
                        help="regenerate only the readable API shape snapshot and its SHA-256")
    args = parser.parse_args(argv)
    api_shape = public_api_shape(source)
    api_shape_text = "\n".join(api_shape) + "\n"
    api_shape_digest = hashlib.sha256(api_shape_text.encode("utf-8")).hexdigest()
    if args.write_api_shape:
        (ROOT / "contract/public-api-shape.txt").write_text(api_shape_text, encoding="utf-8")
        (ROOT / "contract/public-api-shape.sha256").write_text(api_shape_digest + "\n", encoding="utf-8")
        print(f"wrote {len(api_shape)} public API shapes and SHA-256")
        return 0
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
        added = sorted(set(api) - set(expected_api))
        removed = sorted(set(expected_api) - set(api))
        raise SystemExit(f"public API snapshot drifted; added={added}, removed={removed}")

    expected_api_shape = (ROOT / "contract/public-api-shape.txt").read_text(encoding="utf-8").splitlines()
    if api_shape != expected_api_shape:
        added = sorted(set(api_shape) - set(expected_api_shape))
        removed = sorted(set(expected_api_shape) - set(api_shape))
        raise SystemExit(f"public API shape snapshot drifted; added={added}, removed={removed}")
    expected_api_shape_digest = (ROOT / "contract/public-api-shape.sha256").read_text(encoding="utf-8").strip()
    if api_shape_digest != expected_api_shape_digest:
        raise SystemExit(f"public API shape drifted: {api_shape_digest}")

    codes = sorted(set(re.findall(r'"(llm\.[a-z0-9_.]+)"', source)))
    expected_codes = (ROOT / "contract/error-codes.txt").read_text(encoding="utf-8").splitlines()
    if codes != expected_codes:
        added = sorted(set(codes) - set(expected_codes))
        removed = sorted(set(expected_codes) - set(codes))
        raise SystemExit(f"error-code inventory drifted; added={added}, removed={removed}")

    digest = hashlib.sha256()
    fixtures = (
        sorted((ROOT / "fixtures").glob("*.json"))
        + sorted((ROOT / "fixtures/requests").glob("*.json"))
        + sorted((ROOT / "fixtures/streams").glob("*.json"))
        + sorted((ROOT / "fixtures/transcripts").glob("*.json"))
    )
    if len(fixtures) != 21:
        raise SystemExit(f"expected six response, six request, six stream and three native transcript fixtures, found {len(fixtures)}")
    native_sources = {
        "openai-responses": ("developers.openai.com", "openai.responses.v1"),
        "anthropic-messages": ("platform.claude.com", "anthropic.messages.v1"),
        "kimi-chat": ("platform.kimi.ai", "kimi.chat.v1"),
    }
    native_fixtures = sorted((ROOT / "fixtures/transcripts").glob("*.json"))
    if {path.stem for path in native_fixtures} != set(native_sources):
        raise SystemExit("native transcript fixture set is incomplete")
    for path in native_fixtures:
        record = json.loads(path.read_text())
        expected_host, expected_dialect = native_sources[path.stem]
        if urlsplit(record.get("source", "")).hostname != expected_host:
            raise SystemExit(f"native fixture source is not a primary protocol document: {path.name}")
        try:
            datetime.date.fromisoformat(record.get("checked_at", ""))
        except (ValueError, TypeError):
            raise SystemExit(f"native fixture has no fixed check date: {path.name}") from None
        profile, body = record.get("profile", {}), record.get("body", {})
        endpoint = urlsplit(profile.get("endpoint", ""))
        if (profile.get("dialect") != expected_dialect or profile.get("contract_version") != 1 or
            profile.get("evidence") != "caller_declared" or profile.get("live_verified") is not False or
            not profile.get("id") or not profile.get("model") or profile["model"] != body.get("model") or
            endpoint.scheme != "https" or not endpoint.hostname or endpoint.username or endpoint.query or endpoint.fragment):
            raise SystemExit(f"native fixture has no exact offline endpoint/model/contract identity: {path.name}")
        if not isinstance(record.get("required_headers"), list):
            raise SystemExit(f"native fixture has no explicit required-header contract: {path.name}")
    for path in fixtures:
        digest.update(path.relative_to(ROOT / "fixtures").as_posix().encode("utf-8") + b"\0" + path.read_bytes() + b"\0")
    actual_digest = digest.hexdigest()
    expected_digest = (ROOT / "contract/fixture-digest.txt").read_text(encoding="utf-8").strip()
    if actual_digest != expected_digest:
        raise SystemExit(f"fixture digest drifted: {actual_digest}")

    print(f"contract check passed: {len(api)} declarations, {len(api_shape)} API shapes, {len(codes)} codes, {len(fixtures)} fixtures")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
