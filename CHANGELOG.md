# Changelog

All notable changes are recorded here.

## [0.2.0] - 2026-08-27

- Replace protocol-only entry points with `LlmWireCodec`, explicit provider dialects, model capabilities, and strict/lenient validation policy.
- Make thinking provider-default by default and reject unsupported or unrepresentable controls.
- Preserve provider-native thinking, redacted thinking, and unknown Messages blocks as dialect-bound opaque replay data.
- Distinguish pending, succeeded, incomplete, and failed response states, including structured provider failures.
- Add stateful incremental decoders with stable block, item, call, choice, and tool-call identities.
- Rebuild SSE parsing around bytes with CR/LF/CRLF, BOM, empty data, persistent fields, complete-event limits, and RFC-compatible `Retry-After` dates.
- Pin `yjson` to commit `92858f75aedc3dd6f7322789117854514549e62c` and add API, error-code, fixture, coverage, consumer, and provider-smoke release evidence.

This release intentionally breaks the v0.1 API. See [the migration guide](docs/migrating-from-v0.1.md).

## [0.1.0] - 2026-08-26

- Extract provider-neutral LLM request, reply, and stream codecs.
- Support OpenAI Responses, Chat Completions, Anthropic Messages, and DeepSeek
  request dialects.
- Add incremental SSE decoding, Retry-After parsing, bounded body reads, and
  structured transport errors.
- Use `yjson` for JSON values and parsing.
