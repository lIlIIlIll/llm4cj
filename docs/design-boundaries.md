# Package boundaries

`llm4cj` isolates provider wire differences from the rest of a Cangjie agent.
The boundary is intentionally below model routing and above raw JSON and SSE
framing.

## What llm4cj owns

The package owns behavior that must remain consistent across callers:

- the provider-neutral request, reply, block, usage, and stream-event models;
- request encoding for Responses, Chat Completions, Messages, and DeepSeek
  request dialects;
- reply and stream decoding for the three protocol families;
- incremental SSE framing;
- bounded response-body reads;
- JSON size, depth, numeric-literal, and duplicate-key handling; and
- structured transport and provider errors.

Keeping these rules in one package prevents each HTTP adapter from developing a
different interpretation of tool calls, usage data, or stream completion.

## What the caller owns

The calling application owns policy and lifecycle decisions:

- endpoints, credentials, TLS, and HTTP client configuration;
- model and provider selection;
- timeouts, cancellation, retries, and backoff budgets;
- conversation state and context compaction;
- tool approval, execution, and result persistence; and
- recovery after a process or transport failure.

For example, `llm4cj` can parse `Retry-After` into milliseconds. The caller must
still decide whether the request is idempotent and whether a retry fits the
remaining deadline.

## Why terminal events remain distinct

A provider terminal marker proves only that the marker appeared on the wire. It
does not prove that all required content blocks, usage data, or terminal payloads
were assembled into a usable result.

For that reason, `MessageTerminalObserved` and `Completed` are separate
`LlmWireEventKind` values. Callers that make an agent decision must wait for the
validated result produced by the complete stream decoder.

## JSON values remain loss-aware

Tool arguments, tool schemas, and structured-output schemas use
`yjson.JsonNode`. Provider input rejects duplicate object keys and preserves JSON
number literals. These rules avoid silently choosing one duplicate field or
rounding a number before the application can validate it.
