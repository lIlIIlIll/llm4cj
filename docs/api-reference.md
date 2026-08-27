# API reference

本页列出 v0.2.0 的 public declaration。字段和构造参数以源码为准；语义见主题文档。

## Codec 与 dialect

`LlmWireCodec`、`LlmWireCapabilities`、`LlmWireDialect`、`LlmWireBuiltinDialect`、`LlmWireStandardDialect`、`openAiResponsesDialect`、`openAiChatDialect`、`anthropicMessagesDialect`、`deepSeekResponsesDialect`、`deepSeekChatDialect`、`deepSeekMessagesDialect`。

## 请求、block 与响应

`LlmWireProtocol`、`LlmWireRole`、`LlmWireImageSourceKind`、`LlmWireImageDetail`、`LlmWireThinkingLevel`、`LlmWireThinkingControl`、`LlmWireCachePolicy`、`LlmWireToolChoice`、`LlmWireValidationPolicy`、`LlmWireOpaqueCompletion`、`LlmWireImageBlock`、`LlmWireTextBlock`、`LlmWireReasoningBlock`、`LlmWireToolArguments`、`LlmWireToolCallBlock`、`LlmWireToolResultBlock`、`LlmWireRefusalBlock`、`LlmWireOpaqueBlock`、`LlmWireBlock`、`LlmWireMessage`、`LlmWireTool`、`LlmWireStructuredOutput`、`LlmWireRequest`、`LlmWireUsage`、`LlmWireReply`、`LlmWirePendingReply`、`LlmWireIncompleteReason`、`LlmWireFailureKind`、`LlmWireFailure`、`LlmWireTerminal`、`LlmWireResponseState`。

## 流式

`LlmWireEventKind`、`LlmWireEvent`、`LlmWireStreamUpdate`、`LlmWireStreamDecoder`。

## 传输

`LlmTransportErrorKind`、`LlmTransportError`、`LlmResult`、`SseEvent`、`SseDecoder`、`parseSseRetryMillis`、`parseRetryAfterMillis`、`extractRetryAfterMillis`、`sseDataLine`、`readLlmHttpBody`。
