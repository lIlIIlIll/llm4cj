# API reference

This page lists the public `llm4cj` surface. Optional constructor arguments show
their defaults.

## Protocol and request types

### `LlmWireProtocol`

`Responses`, `ChatCompletions`, or `Messages`.

### `LlmWireRequest`

```cangjie
LlmWireRequest(
    model: String,
    messages: Array<LlmWireMessage>,
    system!: String = "",
    tools!: Array<LlmWireTool> = [],
    thinking!: LlmWireThinkingControl =
        LlmWireThinkingControl.Effort(LlmWireThinkingLevel.Medium),
    maxOutputTokens!: Int64 = 2000,
    streaming!: Bool = false,
    parallelToolCalls!: Bool = true,
    serviceTier!: String = "",
    cachePolicy!: LlmWireCachePolicy = LlmWireCachePolicy.Default,
    cacheKey!: String = "",
    toolChoice!: LlmWireToolChoice = LlmWireToolChoice.Auto,
    structuredOutput!: ?LlmWireStructuredOutput = None
)
```

`messages` contains `LlmWireMessage` values. Each message has a `User` or
`Assistant` role and an array of `LlmWireBlock` values.

### `LlmWireBlock`

```cangjie
LlmWireBlock(
    kind: LlmWireBlockKind,
    text!: String = "",
    callId!: String = "",
    name!: String = "",
    arguments!: JsonNode = wireJsonObject([]),
    isError!: Bool = false,
    image!: ?LlmWireImage = None,
    opaqueState!: ?LlmWireOpaqueState = None
)
```

Block kinds are `Text`, `Image`, `Reasoning`, `ToolCall`, `ToolResult`, `Refusal`,
`Error`, and `Unknown`. `arguments` defaults to an empty JSON object.

### Supporting request types

- `LlmWireImage` stores a URL or Base64 image, media type, and image detail.
- `LlmWireTool` stores a name, description, and `JsonNode` input schema.
- `LlmWireStructuredOutput` stores a schema name, `JsonNode` schema, optional
  description, and `strict` flag.
- `LlmWireOpaqueState` stores provider data that must survive a decode and later
  encode cycle.
- `LlmWireThinkingControl` provides `Disabled`, `Toggle`, `Effort`, `Budget`, and
  `Adaptive` variants. See [Provider codecs](provider-codecs.md) for valid
  combinations.
- `LlmWireCachePolicy` is `Default` or `StablePrefix`.
- `LlmWireToolChoice` is `Auto`, `NoTools`, or `Required`.

## Request encoders

```cangjie
encodeLlmWireRequest(protocol: LlmWireProtocol, request: LlmWireRequest): String
encodeResponsesWireRequest(request: LlmWireRequest): String
encodeChatCompletionsWireRequest(request: LlmWireRequest): String
encodeMessagesWireRequest(request: LlmWireRequest): String
encodeDeepSeekChatWireRequest(request: LlmWireRequest): String
encodeDeepSeekMessagesWireRequest(request: LlmWireRequest): String
```

Each function returns a JSON request body. Invalid model combinations throw
`LlmTransportError`.

## Replies and streams

`LlmWireReply` contains decoded `blocks`, `stopReason`, `usage`, and
`responseId`. `LlmWireUsage` contains input, output, reasoning, cache-read, and
cache-write token counts.

```cangjie
decodeLlmWireReply(
    protocol: LlmWireProtocol,
    source: String,
    provider!: String = ""
): LlmWireReply

decodeResponsesWireReply(source: String, provider!: String = ""): LlmWireReply
decodeChatCompletionsWireReply(source: String, provider!: String = ""): LlmWireReply
decodeMessagesWireReply(source: String, provider!: String = ""): LlmWireReply

decodeLlmWireEventFrame(
    protocol: LlmWireProtocol,
    payload: String
): Array<LlmWireEvent>

decodeLlmWireEventStream(
    protocol: LlmWireProtocol,
    source: String,
    provider!: String = ""
): LlmWireStreamResult
```

`LlmWireStreamResult` contains the reconstructed `terminalSource` and ordered
`events`. Event kinds include stream and block lifecycle events, text and
reasoning deltas, tool-call events, usage events, provider errors, transport
closure, and validated completion.

## SSE framing

```cangjie
SseDecoder(
    maxEventBytes!: Int64 = 8388608,
    maxBufferedBytes!: Int64 = 16777216
)

SseDecoder.push(chunk: String): LlmResult<Array<SseEvent>>
SseDecoder.finish(): LlmResult<Array<SseEvent>>
sseDataLine(line: String): ?String
```

`SseEvent` exposes `event`, `data`, `id`, and `retryMillis`.

## Response bodies and retry headers

```cangjie
readLlmHttpBody(
    stream: InputStream,
    declaredSize: ?Int64,
    maxBytes: Int64
): LlmResult<Array<Byte>>

parseRetryAfterMillis(value: String): Int64
extractRetryAfterMillis(headers: String): Int64
```

Only positive integer `Retry-After` seconds are accepted. Invalid or absent
values produce `0`.

## Errors and results

`LlmResult<T>` is `Ok(T)` or `Err(LlmTransportError)`. `isOk()` returns whether
the value is `Ok`.

`LlmTransportError` extends `Exception` and exposes:

- `kind`: `InvalidWire`, `Http`, `BodyLimit`, `Sse`, `Cancelled`, `Deadline`, or
  `Transport`;
- `code` and `message`;
- `retryable`, `httpStatus`, and `retryAfterMillis`;
- `provider`, `providerErrorCode`, and `providerErrorType`.
