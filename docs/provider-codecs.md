# Provider codecs

`llm4cj` uses one request model and three protocol families. Select a family at
the point where your HTTP adapter creates or consumes a provider body.

## Codec selection

- OpenAI Responses: encode with `encodeResponsesWireRequest`, decode replies
  with `decodeResponsesWireReply`, and decode streams with the `Responses`
  protocol.
- OpenAI-compatible Chat Completions: encode with
  `encodeChatCompletionsWireRequest`, decode replies with
  `decodeChatCompletionsWireReply`, and decode streams with the
  `ChatCompletions` protocol.
- Anthropic Messages: encode with `encodeMessagesWireRequest`, decode replies
  with `decodeMessagesWireReply`, and decode streams with the `Messages`
  protocol.
- DeepSeek Chat Completions: encode requests with
  `encodeDeepSeekChatWireRequest`. Use the Chat Completions reply and stream
  decoders.
- DeepSeek Messages: encode requests with `encodeDeepSeekMessagesWireRequest`.
  Use the Messages reply and stream decoders.

Use `encodeLlmWireRequest` or `decodeLlmWireReply` when the caller already has
an `LlmWireProtocol` value. The DeepSeek request dialects require their named
encoders because `LlmWireProtocol` identifies a protocol family, not a provider.

## Thinking controls

Choose a control that the selected request encoder accepts. Invalid combinations
throw `LlmTransportError` with `kind` set to `InvalidWire`.

| Request encoder | Accepted controls |
| --- | --- |
| Responses | `Disabled`, `Toggle`, `Effort`, `Adaptive` |
| Chat Completions | `Disabled`, `Toggle`, `Effort`, `Adaptive` |
| Messages | `Disabled`, `Toggle`, `Budget`, `Adaptive` |
| DeepSeek Chat | `Disabled`, `Toggle`, `Effort` |
| DeepSeek Messages | `Disabled`, `Toggle`, `Effort` |

`LlmWireRequest` defaults to `Effort(Medium)`. That default is valid for
Responses, Chat Completions, and both DeepSeek encoders. Supply a Messages-valid
control when you call `encodeMessagesWireRequest`:

```cangjie
let request = LlmWireRequest(
    "messages-model",
    [LlmWireMessage(
        LlmWireRole.User,
        [LlmWireBlock(LlmWireBlockKind.Text, text: "hello")]
    )],
    thinking: LlmWireThinkingControl.Budget(8192)
)
let payload = encodeMessagesWireRequest(request)
```

## Tools and structured output

Represent tool input schemas and structured-output schemas with
`yjson.JsonNode`. Each encoder maps the shared model to the provider's field
names. In Messages and Chat Completions requests, a tool result must use the call
ID produced by an earlier tool-call block. Those encoders omit orphan tool
results.

Responses reply decoding preserves opaque reasoning and function-call items in
`LlmWireOpaqueState`. Pass that state back in a later request when the provider
requires its original item.

## Provider errors

Pass a provider name to a reply or stream decoder when you want it copied into a
structured error:

```cangjie
let reply = decodeMessagesWireReply(
    "{\"id\":\"m1\",\"content\":[],\"stop_reason\":\"end_turn\"}",
    provider: "anthropic"
)
```

Provider error payloads become `LlmTransportError` values. Inspect `provider`,
`providerErrorCode`, and `providerErrorType` without parsing the provider JSON a
second time.
