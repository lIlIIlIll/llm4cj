# API reference

本页覆盖 `llm4cj` 当前全部 public declaration。`JsonNode` 来自 `yjson`。

## Wire model

### Enums

- `LlmWireProtocol`: `Responses | ChatCompletions | Messages`。
- `LlmWireRole`: `User | Assistant`。
- `LlmWireBlockKind`: `Text | Image | Reasoning | ToolCall | ToolResult | Refusal | Error | Unknown`。
- `LlmWireImageSourceKind`: `Url | Base64`。
- `LlmWireImageDetail`: `Auto | Low | High`。
- `LlmWireThinkingLevel`: `Off | Minimal | Low | Medium | High | XHigh | Max`。
- `LlmWireThinkingControl`: `Disabled | Toggle(Bool) | Effort(LlmWireThinkingLevel) | Budget(Int64) | Adaptive(?LlmWireThinkingLevel)`。
- `LlmWireCachePolicy`: `Default | StablePrefix`。
- `LlmWireToolChoice`: `Auto | NoTools | Required`。
- `LlmWireEventKind`: `StreamStarted | ContentBlockStarted | TextDelta | ReasoningDelta | ToolCallStarted | ToolArgumentsDelta | ContentBlockCompleted | MessageTerminalObserved | UsageDelta | UsageCompleted | ProviderError | StreamTransportClosed | Completed`。

### Data classes

- `LlmWireImage(sourceKind, data, mediaType = "", detail = Auto)`: fields `sourceKind`, `data`, `mediaType`, `detail`。
- `LlmWireOpaqueState(protocol, payload, itemId = "")`: fields `protocol`, `payload`, `itemId`。
- `LlmWireBlock(kind, text = "", callId = "", name = "", arguments = empty object, isError = false, image = None, opaqueState = None)`: fields match parameters。
- `LlmWireMessage(role, blocks)`: one conversation turn。
- `LlmWireTool(name, description, inputSchema)`: tool schema declaration。
- `LlmWireStructuredOutput(name, schema, description = "", strict = true)`: structured output declaration。
- `LlmWireRequest(model, messages, system = "", tools = [], thinking = Effort(Medium), maxOutputTokens = 2000, streaming = false, parallelToolCalls = true, serviceTier = "", cachePolicy = Default, cacheKey = "", toolChoice = Auto, structuredOutput = None)`: unified request。
- `LlmWireUsage(inputTokens = 0, outputTokens = 0, reasoningTokens = 0, cacheReadTokens = 0, cacheWriteTokens = 0)`: token counters。
- `LlmWireReply(blocks, stopReason = "", usage = LlmWireUsage(), responseId = "")`: decoded terminal reply。
- `LlmWireEvent(kind, text = "", callId = "", inputTokens = 0, outputTokens = 0, blockIndex = -1, blockKind = "", terminalEventKind = "", rawStopReason = "")`: incremental fact。
- `LlmWireStreamResult(terminalSource, events)`: validated terminal source plus ordered events。

## Codec functions

- `encodeLlmWireRequest(protocol, request): String`: protocol-dispatched encoder。
- `encodeResponsesWireRequest(request): String`。
- `encodeChatCompletionsWireRequest(request): String`。
- `encodeMessagesWireRequest(request): String`。
- `encodeDeepSeekChatWireRequest(request): String`。
- `encodeDeepSeekMessagesWireRequest(request): String`。
- `decodeLlmWireReply(protocol, source, provider = ""): LlmWireReply`: protocol-dispatched reply decoder。
- `decodeResponsesWireReply(source, provider = ""): LlmWireReply`。
- `decodeChatCompletionsWireReply(source, provider = ""): LlmWireReply`。
- `decodeMessagesWireReply(source, provider = ""): LlmWireReply`。
- `decodeLlmWireEventFrame(protocol, payload): Array<LlmWireEvent>`: stateless single-frame projection；空字符串和 `[DONE]` 返回空数组。
- `decodeLlmWireEventStream(protocol, source, provider = ""): LlmWireStreamResult`: stateful complete-stream decode。

## Transport

- `LlmTransportErrorKind`: `InvalidWire | Http | BodyLimit | Sse | Cancelled | Deadline | Transport`。
- `LlmTransportError(kind, code, message, retryable = false, httpStatus = None, retryAfterMillis = 0, provider = "", providerErrorCode = "", providerErrorType = "")`: 继承 `Exception`，同名参数均为 public field。
- `LlmResult<T>`: `Ok(T) | Err(LlmTransportError)`；`isOk()` 判断 variant。
- `SseEvent(event, data, id, retryMillis)`: decoded SSE fields。
- `SseDecoder(maxEventBytes = 8388608, maxBufferedBytes = 16777216)`: limits 非法时抛 `IllegalArgumentException`；`push(chunk)` 与 `finish()` 返回 `LlmResult<Array<SseEvent>>`。
- `parseRetryAfterMillis(value): Int64`: integer seconds 转 milliseconds。
- `extractRetryAfterMillis(headers): Int64`: case-insensitive 提取最大 `Retry-After`。
- `sseDataLine(line): ?String`: 提取 `data:` 后内容并移除一个可选空格。
- `readLlmHttpBody(stream, declaredSize, maxBytes): LlmResult<Array<Byte>>`: 有界读取 `InputStream`。

## 完整程序

```cj
package api_reference_demo

import llm4cj.*

main(): Int64 {
    let decoder = SseDecoder(maxEventBytes: 1024, maxBufferedBytes: 2048)
    match (decoder.push("event: token\ndata: hello\n\n")) {
        case LlmResult.Ok(events) => println(events[0].data)
        case LlmResult.Err(error) => println(error.code)
    }
    0
}
```
