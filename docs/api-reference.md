# API reference

本页列出 v0.2.0 的 public declaration。字段和构造参数以源码为准；语义见主题文档。

## Codec 与 dialect

`LlmWireCodec`、`LlmWireCapabilities`、`LlmWireDialect`、`LlmWireDialectContract`、`LlmWireBuiltinDialect`、`LlmWireStandardDialect`、`LlmWireRequestStyle`、`LlmWireOutputTokenField`、`LlmWireStructuredOutputMode`、`LlmWireParallelToolStyle`、`LlmWirePromptCacheStyle`、`openAiResponsesDialect`、`openAiChatDialect`、`anthropicMessagesDialect`、`deepSeekResponsesDialect`、`deepSeekChatDialect`、`deepSeekMessagesDialect`。

`LlmWireEncodedRequest` 同时携带 JSON body、必需 header 和待解析的 feature requirement。transport 必须先调用 `validateForSend`，再用 `mergeHeaders` 合并调用方 header；仅发送 `body` 不构成完整请求。

## 请求、block 与响应

`LlmWireProtocol`、`LlmWireRole`、`LlmWireImageSourceKind`、`LlmWireImageDetail`、`LlmWireThinkingLevel`、`LlmWireThinkingControl`、`LlmWireServiceTier`、`LlmWireGenerationSpeed`、`LlmWirePromptCacheLifetime`、`LlmWirePromptCache`、`LlmWireToolChoice`、`LlmWireOpaqueCompletion`、`LlmWireNativeReplayScope`、`LlmWireImageBlock`、`LlmWireTextBlock`、`LlmWireReasoningBlock`、`LlmWireToolArguments`、`LlmWireToolCallBlock`、`LlmWireToolResultBlock`、`LlmWireRefusalBlock`、`LlmWireNativeReplayBlock`、`LlmWireOpaqueBlock`、`LlmWireBlock`、`LlmWireMessage`、`LlmWireTool`、`LlmWireJsonSchema`、`LlmWireStructuredOutput`、`LlmWireRequest`、`LlmWireUsage`、`LlmWireReply`、`LlmWirePendingReply`、`LlmWireIncompleteReason`、`LlmWireFailureKind`、`LlmWireFailure`、`LlmWireTerminal`、`LlmWireResponseState`。

请求计划与 header 协调 API 为 `LlmWireHeader`、`LlmWireFeatureRequirement`、`LlmWireRequirementState`、`LlmWireRequirementResolver`、`LlmWireEncodedRequest`。

## 流式

`LlmWireEventKind`、`LlmWireEvent`、`LlmWireStreamUpdate`、`LlmWireStreamDecoder`。

## 传输

`LlmTransportErrorKind`、`LlmTransportError`、`LlmResult`、`SseEvent`、`SseDecoder`、`parseSseRetryMillis`、`parseRetryAfterMillis`、`extractRetryAfterMillis`、`sseDataLine`、`readLlmHttpBody`。
