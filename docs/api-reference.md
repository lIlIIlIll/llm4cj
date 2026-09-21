# API reference

本页描述 v0.2.0 public declaration。参数和字段以源码与 `contract/public-api.txt` 为准；语义见主题文档。

## 请求与 transcript

`LlmWireRequest` 的固定构造入口是 `LlmWireRequest(model, transcript, ...)`。`LlmWireTranscript` 包含 `LlmWireInitialContext` 和有序 `LlmWireInputItem`；工具相关 item 使用精确的 `LlmWireToolRef`。`LlmWireTranscriptBuilder` 只追加不可变 item，`build()` 返回完整语义校验结果。`snapshot()`/`restore()` 使用严格 version 1 canonical JSON。

`LlmWireTool` 的 version 只用于本地身份；`LlmWireToolDeclaration` 还保存 `Active` 或 `Deferred` visibility。`effectiveTools()` 是 transcript 末端 active view，不能由调用者独立赋值。

## Profile、dialect 与 prepared request

codec 工厂包括 Responses、Chat Completions、Anthropic Messages、DeepSeek 三个 dialect，以及独立的 Kimi Chat。每个 model profile 都要求 `LlmWireTranscriptCapabilities`，其中 endpoint profile ID、contract version 和 operation encoding 必须一致。`LlmWireDialectContract` 还冻结 required headers 和 `LlmWireToolNameGrammar`。

`encodeRequest()` 先验证完整 transcript，再返回 `LlmWirePreparedRequest`。`materialize()` 才产生 `LlmWireMaterializedRequest.body` 与 headers；未解决 requirement、header 冲突、未知 model capability 或不可表达的时序操作均不产生 sendable bytes。

## Usage、failure 与流式

`LlmWireUsage` 的计数使用 Option 语义；`LlmWireUsageSource` 记录 protocol、dialect ID 和 provider field path。`LlmWireFailure.usage` 在 provider error、insufficient resource、cancel 和后续 validation failure 中保留已观测 usage。

固定 response、HTTP failure 和 `LlmWireStreamDecoder` 共享 `LlmWireResponseState`/`LlmWireTerminal`。SSE framing、event、body、retained state、semantic block、tool-call 和 diagnostic 都有独立上限。

## Public declarations

- `LlmWireCacheCapabilities`
- `LlmWireCapabilities`
- `LlmWireChoice`
- `LlmWireCitation`
- `LlmWireCodec`
- `LlmWireDialectContract`
- `LlmWireError`
- `LlmWireEventIdentity`
- `LlmWireFailure`
- `LlmWireFeatureRequirement`
- `LlmWireHeader`
- `LlmWireHttpResponse`
- `LlmWireImageBlock`
- `LlmWireInitialContext`
- `LlmWireInputCapabilities`
- `LlmWireInstruction`
- `LlmWireJson`
- `LlmWireJsonField`
- `LlmWireJsonSchema`
- `LlmWireMaterializedRequest`
- `LlmWireMessage`
- `LlmWireModelProfile`
- `LlmWireNativeReplayBlock`
- `LlmWireOpaqueBlock`
- `LlmWireOutputCapabilities`
- `LlmWirePreparedRequest`
- `LlmWireReasoningBlock`
- `LlmWireRefusalBlock`
- `LlmWireReply`
- `LlmWireRequest`
- `LlmWireSseLimits`
- `LlmWireStreamDecoder`
- `LlmWireStreamLimits`
- `LlmWireStreamUpdate`
- `LlmWireTextBlock`
- `LlmWireThinkingCapabilities`
- `LlmWireTokenLogprob`
- `LlmWireTokenLogprobCandidate`
- `LlmWireTool`
- `LlmWireToolCallBlock`
- `LlmWireToolCapabilities`
- `LlmWireToolDeclaration`
- `LlmWireToolIdentity`
- `LlmWireToolRef`
- `LlmWireToolResultBlock`
- `LlmWireTranscript`
- `LlmWireTranscriptBuilder`
- `LlmWireTranscriptCapabilities`
- `LlmWireTranscriptCapability`
- `LlmWireUsage`
- `LlmWireUsageSource`
- `SseDecoder`
- `SseEvent`
- `LlmTransportPhase`
- `LlmWireAnnotation`
- `LlmWireBlock`
- `LlmWireBuiltinDialect`
- `LlmWireChoiceOutcome`
- `LlmWireCitationKind`
- `LlmWireErrorKind`
- `LlmWireEvent`
- `LlmWireFailureKind`
- `LlmWireGenerationSpeed`
- `LlmWireImageDetail`
- `LlmWireImageSourceKind`
- `LlmWireIncompleteReason`
- `LlmWireInputItem`
- `LlmWireInputModality`
- `LlmWireInstructionRole`
- `LlmWireJsonKind`
- `LlmWireNativeReplayScope`
- `LlmWireOpaqueCompletion`
- `LlmWireOutputBlock`
- `LlmWireOutputPhase`
- `LlmWireOutputTokenField`
- `LlmWireParallelToolStyle`
- `LlmWirePendingReply`
- `LlmWirePromptCache`
- `LlmWirePromptCacheLifetime`
- `LlmWirePromptCacheStyle`
- `LlmWireProtocol`
- `LlmWireReasoningEffort`
- `LlmWireRequestStyle`
- `LlmWireRequirementState`
- `LlmWireResponseState`
- `LlmWireResult`
- `LlmWireRole`
- `LlmWireServiceTier`
- `LlmWireStreamBlockKind`
- `LlmWireStructuredOutput`
- `LlmWireStructuredOutputMode`
- `LlmWireTerminal`
- `LlmWireThinkingMode`
- `LlmWireToolArguments`
- `LlmWireToolChoice`
- `LlmWireToolErrorStyle`
- `LlmWireToolInputValidationMode`
- `LlmWireToolNameGrammar`
- `LlmWireToolResultContent`
- `LlmWireToolVisibility`
- `LlmWireTranscriptEncoding`
- `LlmWireTranscriptOperation`
- `LlmWireUsageMergeStyle`
- `anthropicMessagesCodec`
- `anthropicMessagesDialect`
- `anthropicMessagesModelProfile`
- `deepSeekChatCodec`
- `deepSeekChatDialect`
- `deepSeekChatModelProfile`
- `deepSeekMessagesCodec`
- `deepSeekMessagesDialect`
- `deepSeekMessagesModelProfile`
- `deepSeekResponsesCodec`
- `deepSeekResponsesDialect`
- `deepSeekResponsesModelProfile`
- `extractRetryAfterMillis`
- `kimiChatCodec`
- `kimiChatDialect`
- `kimiChatModelProfile`
- `openAiChatCodec`
- `openAiChatDialect`
- `openAiChatModelProfile`
- `openAiResponsesCodec`
- `openAiResponsesDialect`
- `openAiResponsesModelProfile`
- `parseRetryAfterMillis`
- `parseSseRetryMillis`
- `readLlmHttpBody`
- `sseDataLine`
- `validateReplyToolInputs`
- `LlmWireDialect`
- `LlmWireRequirementResolver`
