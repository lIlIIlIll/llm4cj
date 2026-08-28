# Changelog

All notable changes are recorded here.

## [Unreleased]

- Replace protocol-only entry points with `LlmWireCodec`, explicit provider dialects, model capabilities, and strict-only validation.
- Make thinking provider-default by default and reject unsupported or unrepresentable controls.
- Preserve supported provider-native thinking as dialect-bound `NativeReplay`; reject unknown semantic blocks as `Unsupported` with bounded diagnostics.
- Distinguish pending, succeeded, incomplete, and failed response states, including structured provider failures.
- Add stateful incremental decoders with stable block, item, call, choice, and tool-call identities.
- Preserve DeepSeek `reasoning_content` across tool continuation and Responses native/message ordering.
- Enforce aggregate stream limits, message phases, immutable tool identities, executable tool arguments, and request schema invariants.
- Verify public request, fixed-response, and stream fixtures with deterministic byte fragmentation, and refuse release-asset replacement.
- Rebuild SSE parsing around bytes with CR/LF/CRLF, BOM, empty data, persistent fields, complete-event limits, and RFC-compatible `Retry-After` dates.
- Pin `yjson` to commit `92858f75aedc3dd6f7322789117854514549e62c` and add API, error-code, fixture, coverage, consumer, and provider-smoke release evidence.
- Freeze dialect contracts inside codecs, add model-level image modalities (including DeepSeek Vision file/header encoding), and restrict native reasoning replay to built-in dialect identities.
- Count every provider stream event, preserve failed/incomplete Responses classification, and count both CRLF bytes against SSE event limits.
- Require `[DONE]` for built-in Chat transport completion, coalesce pre-identity tool fragments, enforce Responses value-done ordering, and use current OpenAI prompt-cache TTL mapping.
- Verify Provider Smoke workflow provenance and artifact digests before release, and record them in the release manifest.

This release intentionally breaks the v0.1 API. See [the migration guide](docs/migrating-from-v0.1.md).

## [0.1.0] - 2026-08-26

- Extract provider-neutral LLM request, reply, and stream codecs.
- Support OpenAI Responses, Chat Completions, Anthropic Messages, and DeepSeek
  request dialects.
- Add incremental SSE decoding, Retry-After parsing, bounded body reads, and
  structured transport errors.
- Use `yjson` for JSON values and parsing.
