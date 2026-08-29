# API reference

本页列出 v0.2.0 的 public declaration。字段和构造参数以源码为准；语义见主题文档。

## Codec 与 dialect

`LlmWireCodec`、`LlmWireCapabilities`、`LlmWireDialect`、`LlmWireDialectContract`、`LlmWireBuiltinDialect`、`LlmWireStandardDialect`、`LlmWireRequestStyle`、`LlmWireOutputTokenField`、`LlmWireStructuredOutputMode`、`LlmWireParallelToolStyle`、`LlmWirePromptCacheStyle`、`LlmWireUsageMergeStyle`、`openAiResponsesDialect`、`openAiChatDialect`、`anthropicMessagesDialect`、`deepSeekResponsesDialect`、`deepSeekChatDialect`、`deepSeekMessagesDialect`。

`LlmWireEncodedRequest` 同时携带 JSON body、必需 header 和待解析的 feature requirement。transport 必须先调用 `validateForSend`，再用 `mergeHeaders` 合并调用方 header；仅发送 `body` 不构成完整请求。

## 请求、block 与响应

`LlmWireProtocol`、`LlmWireRole`、`LlmWireInputModality`、`LlmWireImageSourceKind`、`LlmWireImageDetail`、`LlmWireReasoningEffort`、`LlmWireThinkingMode`、`LlmWireServiceTier`、`LlmWireGenerationSpeed`、`LlmWirePromptCacheLifetime`、`LlmWirePromptCache`、`LlmWireToolChoice`、`LlmWireOpaqueCompletion`、`LlmWireNativeReplayScope`、`LlmWireImageBlock`、`LlmWireTextBlock`、`LlmWireReasoningBlock`、`LlmWireToolArguments`、`LlmWireToolCallBlock`、`LlmWireToolResultBlock`、`LlmWireRefusalBlock`、`LlmWireNativeReplayBlock`、`LlmWireOpaqueBlock`、`LlmWireBlock`、`LlmWireMessage`、`LlmWireTool`、`LlmWireJson`、`LlmWireJsonSchema`、`LlmWireStructuredOutput`、`LlmWireRequest`、`LlmWireUsage`、`LlmWireReply`、`LlmWirePendingReply`、`LlmWireIncompleteReason`、`LlmWireFailureKind`、`LlmWireFailure`、`LlmWireTerminal`、`LlmWireResponseState`。

`LlmWireCapabilities` 由 `input`、`thinking`、`tools`、`output` 和 `cache` 五个不可变能力对象组成。`input.modalities` 默认为仅 `Text`。图片 source 支持 `Url`、`Base64` 与 `File`；是否可用由具体 model profile 决定。

对应类型是 `LlmWireInputCapabilities`、`LlmWireThinkingCapabilities`、`LlmWireToolCapabilities`、`LlmWireOutputCapabilities` 和 `LlmWireCacheCapabilities`。

`LlmWireModelProfile` 把模型名、dialect compatibility ID 和模型能力绑定在一起。工厂为 `openAiResponsesModelProfile`、`openAiChatModelProfile`、`anthropicMessagesModelProfile`、`deepSeekResponsesModelProfile`、`deepSeekChatModelProfile` 和 `deepSeekMessagesModelProfile`。对应的推荐 codec 入口为 `openAiResponsesCodec`、`openAiChatCodec`、`anthropicMessagesCodec`、`deepSeekResponsesCodec`、`deepSeekChatCodec` 和 `deepSeekMessagesCodec`。codec 会拒绝与 profile 不一致的模型名或 dialect。

公开 JSON 值使用不可变的 `LlmWireJson`，其类型由 `LlmWireJsonKind` 表示，对象工厂接收 `LlmWireJsonField`。它保留 canonical JSON 文本，并提供 object、array、number、string、boolean 和 null 工厂；`yjson.JsonNode` 不再出现在 public API 中。

请求计划与 header 协调 API 为 `LlmWireHeader`、`LlmWireFeatureRequirement`、`LlmWireRequirementState`、`LlmWireRequirementResolver`、`LlmWireEncodedRequest`。

## 流式

`LlmWireEventKind`、`LlmWireEvent`、`LlmWireStreamLimits`、`LlmWireStreamUpdate`、`LlmWireStreamDecoder`。

`LlmWireStreamLimits` 分别限制 total semantic、text、reasoning、tool arguments、retained state、block、tool call 与输入 provider event 数量；这些值在 decoder 构造后不可变。`maxEvents` 在每次协议 decoder `push` 时计数，即使该 provider event 不产生 public semantic event。

## 传输

`LlmWireErrorKind`、`LlmTransportPhase`、`LlmWireError`、`LlmWireResult`、`SseEvent`、`SseDecoder`、`parseSseRetryMillis`、`parseRetryAfterMillis`、`extractRetryAfterMillis`、`sseDataLine`、`readLlmHttpBody`。
