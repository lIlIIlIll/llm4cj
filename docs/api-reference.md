# API reference

本页列出 v0.2.0 的 public declaration。字段和构造参数以源码为准；语义见主题文档。

## Codec 与 dialect

`LlmWireCodec`、`LlmWireCapabilities`、`LlmWireDialect`、`LlmWireDialectContract`、`LlmWireBuiltinDialect`、`LlmWireStandardDialect`、`LlmWireRequestStyle`、`LlmWireOutputTokenField`、`LlmWireStructuredOutputMode`、`LlmWireParallelToolStyle`、`LlmWirePromptCacheStyle`、`LlmWireUsageMergeStyle`、`openAiResponsesDialect`、`openAiChatDialect`、`anthropicMessagesDialect`、`deepSeekResponsesDialect`、`deepSeekChatDialect`、`deepSeekMessagesDialect`。

`LlmWireEncodedRequest` 同时携带 JSON body、必需 header 和待解析的 feature requirement。transport 必须先调用 `validateForSend`，再用 `mergeHeaders` 合并调用方 header；仅发送 `body` 不构成完整请求。

## 请求、block 与响应

`LlmWireProtocol`、`LlmWireRole`、`LlmWireInputModality`、`LlmWireImageSourceKind`、`LlmWireImageDetail`、`LlmWireThinkingLevel`、`LlmWireThinkingControl`、`LlmWireServiceTier`、`LlmWireGenerationSpeed`、`LlmWirePromptCacheLifetime`、`LlmWirePromptCache`、`LlmWireToolChoice`、`LlmWireOpaqueCompletion`、`LlmWireNativeReplayScope`、`LlmWireImageBlock`、`LlmWireTextBlock`、`LlmWireReasoningBlock`、`LlmWireToolArguments`、`LlmWireToolCallBlock`、`LlmWireToolResultBlock`、`LlmWireRefusalBlock`、`LlmWireNativeReplayBlock`、`LlmWireOpaqueBlock`、`LlmWireBlock`、`LlmWireMessage`、`LlmWireTool`、`LlmWireJsonSchema`、`LlmWireStructuredOutput`、`LlmWireRequest`、`LlmWireUsage`、`LlmWireReply`、`LlmWirePendingReply`、`LlmWireIncompleteReason`、`LlmWireFailureKind`、`LlmWireFailure`、`LlmWireTerminal`、`LlmWireResponseState`。

`LlmWireCapabilities.inputModalities` 默认为仅 `Text`。图片 source 支持 `Url`、`Base64` 与 `File`；是否可用由具体模型 capability 决定。

请求计划与 header 协调 API 为 `LlmWireHeader`、`LlmWireFeatureRequirement`、`LlmWireRequirementState`、`LlmWireRequirementResolver`、`LlmWireEncodedRequest`。

## 流式

`LlmWireEventKind`、`LlmWireEvent`、`LlmWireStreamLimits`、`LlmWireStreamUpdate`、`LlmWireStreamDecoder`。

`LlmWireStreamLimits` 分别限制 total semantic、text、reasoning、tool arguments、retained state、block、tool call 与输入 provider event 数量；这些值在 decoder 构造后不可变。`maxEvents` 在每次协议 decoder `push` 时计数，即使该 provider event 不产生 public semantic event。

## 传输

`LlmTransportErrorKind`、`LlmTransportPhase`、`LlmTransportError`、`LlmResult`、`SseEvent`、`SseDecoder`、`parseSseRetryMillis`、`parseRetryAfterMillis`、`extractRetryAfterMillis`、`sseDataLine`、`readLlmHttpBody`。
