# Changelog

All notable changes are recorded here.

## [0.1.0] - 2026-08-26

- Extract provider-neutral LLM request, reply, and stream codecs.
- Support OpenAI Responses, Chat Completions, Anthropic Messages, and DeepSeek
  request dialects.
- Add incremental SSE decoding, Retry-After parsing, bounded body reads, and
  structured transport errors.
- Use `yjson` from its `main` branch for JSON values and parsing.
