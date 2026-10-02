# Changelog

All notable changes are recorded here.

## [0.3.0] - Unreleased

- Replace the separated request `instructions`, `messages`, and `tools` API with one immutable ordered transcript and its initial context. Remove the old request constructor and builder input setters without compatibility shims.
- Preserve dynamic instruction, tool declaration, activation, and deactivation positions; derive the active tool view by replay and validate historical calls against the definitions active at each point.
- Add versioned transcript snapshots, explicit tool definition identities, deterministic duplicate handling, bounded diagnostics, and endpoint/model/dialect-bound native update capability declarations.
- Encode Responses `additional_tools`, Anthropic predeclared/deferred tool references and native update beta headers, and Kimi `system.tools` without collapsing updates into the initial context or falling back to another protocol.
- Update fixtures, public API snapshots, examples, and external consumers for the breaking contract; document the Axyndra integration boundary and reproducible live cache experiment procedure.
- Keep absent cache usage unknown and distinguish it from reported zero. Offline protocol fixtures prove layout and semantics only; no real provider cache benefit is claimed without a recorded live experiment.

See [the v0.2 migration guide](docs/migrating-from-v0.2.md) and [the transcript ADR](docs/adr/0002-ordered-transcript.md). A release tag, remote consumer result, and live provider/cache evidence are separate gates; this entry does not assert that they have run. Evidence is bound to the published source commit in [the implementation record](docs/issue-27-implementation.md).

## [0.1.1]

- Replace protocol-only entry points with `LlmWireCodec`, explicit provider dialects, model capabilities, and strict-only validation.
- Make thinking provider-default by default and reject unsupported or unrepresentable controls.
- Declare per-dialect tool-result error strategies: Anthropic Messages keeps native `is_error`, DeepSeek Messages encodes failures as a `[tool_error]` content marker instead of the ignored `is_error` field, and Messages dialects without a declared strategy stay fail-closed.
- Add protocol-independent tool input contract validation with three opt-in modes, a bounded first-violation diagnostic, and a permanent split between malformed JSON and schema violations.
- Preserve supported provider-native thinking as dialect-bound `NativeReplay`; reject unknown semantic blocks as `Unsupported` with bounded diagnostics.
- Distinguish pending, succeeded, incomplete, and failed response states, including structured provider failures.
- Add stateful incremental decoders with stable block, item, call, choice, and tool-call identities.
- Preserve DeepSeek `reasoning_content` across tool continuation and Responses native/message ordering.
- Enforce aggregate stream limits, message phases, immutable tool identities, executable tool arguments, and request schema invariants.
- Verify public request, fixed-response, and stream fixtures with deterministic byte fragmentation, and refuse release-asset replacement.
- Rebuild SSE parsing around bytes with CR/LF/CRLF, BOM, empty data, persistent fields, complete-event limits, and RFC-compatible `Retry-After` dates.
- Pin the `yjson` dependency to immutable tag `0.1.0` (previously tracked on `main`); the release gate verifies both manifest tag selection and lock resolution against the tag object, with API, error-code, fixture, coverage, consumer, and provider-smoke release evidence.
- Freeze dialect contracts inside codecs, add model-level image modalities (including DeepSeek Vision file/header encoding), and restrict native reasoning replay to built-in dialect identities.
- Count every provider stream event, preserve failed/incomplete Responses classification, and count both CRLF bytes against SSE event limits.
- Require `[DONE]` for built-in Chat transport completion, coalesce pre-identity tool fragments, enforce Responses value-done ordering, and use current OpenAI prompt-cache TTL mapping.
- Verify Provider Smoke workflow provenance and artifact digests before release, and record them in the release manifest.
- Reject unrepresentable custom thinking dialects and invalid thinking/tool-choice combinations, and fail continuation projection before native replay order can change.
- Encode Chat Files API blocks per dialect, reject unmodeled provider semantics, and make SSE retained-byte accounting incremental.
- Isolate custom dialects, cache pre-warm, custom tools, and grammars in `llm4cj.experimental`; bind pre-warm requests to request-aware response expectations.
- Harden patch coverage against missing DA records, verify API changes against the latest release tag, and preserve SSE events emitted during transport finish.

This release intentionally breaks the v0.1 API. See [the migration guide](docs/migrating-from-v0.1.md).

## [0.1.0] - 2026-08-26

- Extract provider-neutral LLM request, reply, and stream codecs.
- Support OpenAI Responses, Chat Completions, Anthropic Messages, and DeepSeek
  request dialects.
- Add incremental SSE decoding, Retry-After parsing, bounded body reads, and
  structured transport errors.
- Use `yjson` for JSON values and parsing.
