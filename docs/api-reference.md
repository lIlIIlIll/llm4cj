# API reference

本页列出 v0.3.0 候选的 public declaration。字段和构造参数以源码为准；语义见主题文档。

## Codec 与 dialect

`LlmWireCodec`、`LlmWireCapabilities`、`LlmWireDialect`、`LlmWireDialectContract`、`LlmWireBuiltinDialect`、`LlmWireRequestStyle`、`LlmWireOutputTokenField`、`LlmWireStructuredOutputMode`、`LlmWireParallelToolStyle`、`LlmWireToolErrorStyle`、`LlmWirePromptCacheStyle`、`LlmWireUsageMergeStyle`、`openAiResponsesDialect`、`openAiCodexResponsesDialect`、`openAiChatDialect`、`anthropicMessagesDialect`、`deepSeekResponsesDialect`、`deepSeekChatDialect`、`deepSeekMessagesDialect`。

`LlmWireCodec.encodeRequest` 返回 opaque `LlmWirePreparedRequest`。调用 `materialize` 后才得到 `LlmWireMaterializedRequest`。后者公开 UTF-8 `body` bytes 和合并后的 headers。未解析的 feature requirement、冲突 header 或不安全 header 会返回 `LlmWireResult.Err`。

`LlmWireHttpResponse` 保存 status、headers 和有界读取后的 body bytes。`decodeResponse(LlmWireHttpResponse)` 返回 `LlmWireResult<LlmWireResponseState>`。2xx body 进入协议 decoder；非 2xx provider 错误保持为 `Terminal(ProviderFailed)`，并保留 status、`Retry-After` 和 provider request ID。

## 请求、block 与响应

`LlmWireToolDefinition` 为 `Function(LlmWireTool)` / `Custom(LlmWireCustomTool)` tagged 定义，公共 `name`、`description` 和 `LlmWireToolKind` 投影用于有序声明池。`LlmWireCustomTool` 使用 `LlmWireCustomToolFormat.Text` 或 Grammar(`LlmWireGrammar`)，`LlmWireGrammarSyntax` 为 Regex / Lark；`LlmWireCustomToolFormatKind` 用于 dialect 与模型 capability。custom 输入使用 `LlmWireToolArguments.Text` / PartialText，result 与 stream identity 保留 kind。格式、能力门禁和迁移见 [custom tools](custom-tools.md)。

`LlmWireProtocol`、`LlmWireRole`、`LlmWireInstructionRole`、`LlmWireInstruction`、`LlmWireInputModality`、`LlmWireImageSourceKind`、`LlmWireImageDetail`、`LlmWireReasoningEffort`、`LlmWireThinkingMode`、`LlmWireServiceTier`、`LlmWireGenerationSpeed`、`LlmWirePromptCacheLifetime`、`LlmWirePromptCache`、`LlmWireToolChoice`、`LlmWireOpaqueCompletion`、`LlmWireNativeReplayScope`、`LlmWireImageBlock`、`LlmWireTextBlock`、`LlmWireReasoningBlock`、`LlmWireToolArguments`、`LlmWireToolCallBlock`、`LlmWireToolResultContent`、`LlmWireToolResultBlock`、`LlmWireRefusalBlock`、`LlmWireNativeReplayBlock`、`LlmWireOpaqueBlock`、`LlmWireBlock`、`LlmWireOutputBlock`、`LlmWireOutputPhase`、`LlmWireCitation`、`LlmWireCitationKind`、`LlmWireAnnotation`、`LlmWireTokenLogprob`、`LlmWireTokenLogprobCandidate`、`LlmWireMessage`、`LlmWireTool`、`LlmWireJson`、`LlmWireJsonSchema`、`LlmWireStructuredOutput`、`LlmWireRequest`、`LlmWireRequestBuilder`、`LlmWireUsage`、`LlmWireChoice`、`LlmWireChoiceOutcome`、`LlmWireReply`、`LlmWirePendingReply`、`LlmWireIncompleteReason`、`LlmWireFailureKind`、`LlmWireFailure`、`LlmWireTerminal`、`LlmWireResponseState`。

`LlmWireRequest.transcript` 保存单一输入事实。`LlmWireInitialContext` 保留初始 system/developer instruction 和工具池；`LlmWireInputItem` 有序联合保存 Message、InstructionUpdate、ToolDeclaration、ToolActivation 和 ToolDeactivation。`LlmWireToolDeclaration` 绑定完整工具、version、deferred；其 identity 为 `LlmWireToolDefinitionIdentity`。`LlmWireTranscript` 的 append 返回新快照，effectiveTools 是顺序重放的只读派生视图。snapshot 为旧语义写 llm4cj.transcript version 2，为 custom、显式 cache 或 typed audio 语义写 version 3；restore 读 version 1、2 和 3，两者返回 Result；version 1 中未保存的消息边界保持缺失。Messages dialect 不表示 developer role，因此构建请求时返回 `Unsupported`。`LlmWireToolResultBlock.content` 是 `LlmWireToolResultContent` 数组，每个元素是 text 或 image。

`LlmWireCachePosition` 使用 InitialTool、InitialInstruction、MessageBlock 和 Item 指定原始 transcript 位置。`LlmWireCacheBreakpoint` 绑定位置与 lifetime；transcript 和 builder 保留独立的 cacheBreakpoints 数组。显式断点需要内置 Anthropic contract 和 `LlmWireCacheCapabilities.explicitBreakpoints`，按 tools → system → messages 校验目标、槽位和 TTL，不会移动断点。显式 metadata 随 snapshot v3 保存，可与 custom 语义共存；旧语义继续写 v2。详见[显式缓存断点](prompt-cache-breakpoints.md)。

`LlmWireAssistantMessageSpan(blockStart, blockCount, phase:)` 保存 Responses assistant message 在 blocks 中的范围。`LlmWireChoice.messageSpans` 和 `LlmWireMessage.messageSpans` 返回独立数组，continuation 投影保留 span。OpenAI Responses/Codex 的缺失或 null phase 对应 `Unspecified`，`commentary` 对应 `Commentary`，`final_answer` 对应 `Final`；其他 wire phase 拒绝。span 有序、不重叠、覆盖 message content，并且不能包含 function call 或 native replay 等独立 wire item。

`LlmWireContextUpdateStyle`、`LlmWireContextUpdateContract` 与 `LlmWireContextUpdateCapabilities` 区分各原生更新及延迟池能力。`LlmWireEndpointProfile` 绑定 profileId/model/dialectId/endpoint/contractVersion/capabilities/evidenceSource/checkedAt；`LlmWireCapabilityEvidence.CallerDeclared` 明确表明其为调用方声明。缺少能力/绑定不匹配时编码前失败，不提供兼容回退。内置契约矩阵见[有序 transcript](ordered-transcript.md)。

usage 来源以 `LlmWireUsageSource.Unknown` 或 ProviderReported(provider, dialectId) 表示。cacheReadAvailability/cacheWriteAvailability 使用 `LlmWireUsageAvailability.Unknown`/Reported；None 与 Some(0) 保持区分。`LlmWireError.usage` 和 `LlmWireFailure.usage` 保留失败前已观测计数。

`LlmWireDialectContract.toolErrorStyle` 声明工具失败语义的编码策略：`NativeField`（Anthropic Messages，发送原生 `is_error` 字段）、`ContentMarker`（DeepSeek Messages，失败结果在 `content` 前插入固定 text block `[tool_error]`，并不再发送被 provider 忽略的 `is_error`，属于有损兼容）或 `Unsupported`（Messages dialect 默认，`isError=true` 会以 `llm.tool_result_error_semantics_unsupported` 拒绝）。

`validateReplyToolInputs(reply, transcript, mode:, limits:)` 在 wire-valid reply 与工具执行之间提供协议无关的输入契约屏障。它始终拒绝末端未声明或未激活工具。`LlmWireToolInputValidationMode.Disabled` 仅关闭 schema 检查。`Strict` 预检所有 schema 分支，遇到未知规则或不支持的形式返回 `llm.tool_schema_unsupported`。`ValidateSupportedSubset` 可报告已知约束证明的违例，但只要仍有未知规则，就不能返回成功。

除 `type`、`properties`、`required`、`additionalProperties`、`items`、`enum` 外，还支持 `const`、四种数值范围、字符串长度、数组项数、对象属性数，以及 `allOf`、`anyOf`、`oneOf`。schema 子位置接受 object 或 boolean；`additionalProperties` 也接受 schema。数值比较保持精确，字符串长度按 Unicode code point 计算。`pattern`、`$ref` 等未实现规则明确 Unsupported。

`LlmWireSchemaValidationLimits` 的默认上限为 `maxDepth=256`、`maxWork=67108864`，调用方只能降低。整个调用共享预检、比较、组合分支和诊断的工作预算，超限返回 `llm.schema_validation_limit`。违例使用 `llm.tool_arguments_schema_violation`，携带有界路径和证据；超长值保留字节数标记。参数不是完整 JSON object 的调用仍由 wire 层处理。

`LlmWireCapabilities` 由 `input`、`thinking`、`tools`、`output`、`cache` 和 `audio` 六个不可变能力对象组成。`input.modalities` 默认为仅 `Text`。图片 source 支持 `Url`、`Base64` 与 `File`；是否可用由具体 model profile 决定。

对应类型是 `LlmWireInputCapabilities`、`LlmWireThinkingCapabilities`、`LlmWireToolCapabilities`、`LlmWireOutputCapabilities` 和 `LlmWireCacheCapabilities`。

`LlmWireModelProfile` 把模型名、dialect compatibility ID 和模型能力绑定在一起。工厂为 `openAiResponsesModelProfile`、`openAiCodexResponsesModelProfile`、`openAiChatModelProfile`、`anthropicMessagesModelProfile`、`deepSeekResponsesModelProfile`、`deepSeekChatModelProfile`、`deepSeekMessagesModelProfile` 和 `kimiChatModelProfile`。对应 codec 入口为 `openAiResponsesCodec`、`openAiCodexResponsesCodec`、`openAiChatCodec`、`anthropicMessagesCodec`、`deepSeekResponsesCodec`、`deepSeekChatCodec`、`deepSeekMessagesCodec` 和 `kimiChatCodec`；Kimi dialect 入口为 `kimiChatDialect`。codec 会拒绝与 profile 不一致的模型名或 dialect。原生更新支持的 model-profile 工厂还接受显式 endpoint/endpointProfile。

`LlmWireCodec` 的构造器不是稳定 public API；稳定调用方使用上述工厂。自定义 dialect 与 cache pre-warm 见[实验 API](experimental.md)；稳定 custom tool 与 grammar 见 [custom tools](custom-tools.md)。

调用 `codec.newRequestBuilder()` 可复用 profile 中的模型和 codec 校验。builder 的 setter 检查局部输入，`build()` 返回 `LlmWireResult<LlmWireRequest>` 并执行完整请求校验。调用 `codec.encodeRequest(request, streaming: true)` 才会发送 streaming 字段；同一个 request 可用于固定响应和流式响应。

公开 JSON 值使用不可变的 `LlmWireJson`，其类型由 `LlmWireJsonKind` 表示，对象工厂接收 `LlmWireJsonField`。parse、number、string、array、object 返回 `LlmWireResult<LlmWireJson>`；boolean 与 nullValue 直接返回值。输入、转义后的完整输出及容器组合均受 8 MiB/256 层限制。私有已验证 DOM 用于读取，getter 不暴露可变 provider JSON。numberLiteral 保留原数值词法，schema integer 与 enum 使用精确十进制值比较。迁移代码见[迁移指南](migrating-from-v0.2.md#处理可失败的-json-构造)。

请求计划与 header 协调 API 为 `LlmWireHeader`、`LlmWireFeatureRequirement`、`LlmWireRequirementState`、`LlmWireRequirementResolver`、`LlmWirePreparedRequest` 和 `LlmWireMaterializedRequest`。

## 结构化输出提取

`extractStructuredOutput(reply, request, choiceIndex:, mode:, limits:, maxTextBytes:)` 是解码后的显式校验入口。结果类型 `LlmWireStructuredOutputResult` 保留 `choiceIndex`、可选原始 `rawText` 和 `LlmWireStructuredOutputOutcome`，通过 `LlmWireResult` 返回。六种 outcome 为 Valid、InvalidJson、SchemaViolation、UnsupportedSchema、Incomplete、Refused；拒绝和截断不返回候选文本，也不会因合法 JSON 被升级为成功。

多 choice 按显式 index 选择；只提取唯一 Final message，没有 Final 时接受唯一 Unspecified message。候选内部按顺序拼接文本，不修复 JSON 或移除代码围栏。默认文本上限为 8 MiB，schema 使用同一 `LlmWireSchemaValidationLimits`。Disabled、Text 和 ProviderDefault 格式不适用。完成的混合 tool/audio choice 会明确拒绝；语法错误仅包含安全消息、choice 和已知的 UTF-8 字节位置。用法见[结构化输出](structured-output.md)。

## Transcript 分支

`LlmWireTranscript.forkAt(itemIndex: Int64)` 返回 `[0, itemIndex)` 的闭合前缀；边界允许零和完整 item 数量。`appendContinuation(reply: LlmWireReply)` 要求单个 choice，`appendContinuation(reply: LlmWireReply, choiceIndex: Int64)` 按公开 choice index 选择。三个方法返回 `LlmWireResult<LlmWireTranscript>`，失败保持输入不变。工具闭合、replay 完整性及缓存断点规则见[安全分支与续接](transcript-branching.md)。

## 音频

`LlmWireAudioFormat`、`LlmWireAudioVoice`、`LlmWireAudioCompletion`、`LlmWireAudioInputBlock`、`LlmWireAudioOutputOptions`、`LlmWireAudioCapabilities`、`LlmWireResponseContext`、`LlmWireAudioOutputBlock`、`LlmWireAssistantAudioReplayBlock`、`LlmWireAudioChunk`。

`LlmWireAudioInputBlock.fromBytes(format, bytes)` 返回 Result，复制非空 WAV/MP3 bytes。`LlmWireRequest.audioOutput` 或 builder 的 `setAudioOutput` 显式选择输出 format/voice。capability 分别声明 inputFormats、fixedOutputFormats、streamOutputFormats、voices 和 assistantReplay。支持范围和限额见[音频接入](audio.md)。

`LlmWirePreparedRequest.responseContext` 只读绑定请求协议、dialect、provider、model 与可选 requestedAudioFormat。两个 `decodeResponse` 入口、`newStreamDecoder` 和 `newHttpStreamDecoder` 的 `responseContext` named 参数默认为 None；遇到音频时必须提供 prepared context。`LlmWireAudioOutputBlock` 与 replay token 只能由 decoder 或经过校验的 snapshot 恢复产生，bytes getter 返回独立数组。`LlmWireUsage.audioInputTokens` / `audioOutputTokens` 保留 None 与 Some(0)。

`materialize(nowEpochSeconds: Some(now))` 对每个 audio replay 验证 `0 <= now < expiresAtEpochSeconds`。缺少时钟或已过期返回 Result.Err。无 audio replay 的请求不需要此参数。音频流事件为 `AudioIdObserved`、`AudioDataDelta`、`AudioTranscriptDelta`、`AudioExpiryObserved`，沿用带 identity 的 ContentBlockStarted/Completed。

## 流式

`LlmWireStreamBlockKind`、`LlmWireEventIdentity`、`LlmWireToolIdentity`、`LlmWireEvent`、`LlmWireStreamLimits`、`LlmWireSseLimits`、`LlmWireStreamUpdate`、`LlmWireStreamDecoder`。

`LlmWireStreamDecoder.push` 接收 `String` 或 `Array<Byte>`，返回 `LlmWireResult<LlmWireStreamUpdate>`；`finish` 处理 EOF 并要求协议终态，`cancel` 幂等返回 `Cancelled`。`LlmWireEvent` 是 payload enum，包含 text/reasoning/refusal delta、tool identity、citation、usage、choice completion 与 terminal。

`LlmWireStreamLimits` 分别限制 total semantic、text、reasoning、tool arguments、retained state、block、tool call 与输入 provider event 数量；`LlmWireSseLimits` 限制 framing 与非 2xx error body。所有值在 decoder 构造后不可变。`maxEvents` 在每次 provider event 消费时计数，即使该事件不产生 public semantic event。

`LlmWireResponsesWebSocketSession` 由 Codex codec 的 `newResponsesWebSocketSession(limits:)` 创建。`prepare(request)` 返回 `LlmWirePreparedWebSocketEvent`，其 body 是 UTF-8 JSON bytes；`push(Array<Byte>)` 接收一条完整 text message，返回 `LlmWireResult<LlmWireStreamUpdate>`。应用自行重组 WebSocket frame，处理 ping/pong 并管理连接。session 保证一条活动响应，只有已验证终态后才保存同连接 continuation 检查点。`finish()` 处理提前关闭，`cancel()` 建立取消终态。详情见[Codex 示例](codex-subscription.md)。

## 传输

`LlmWireErrorKind`、`LlmTransportPhase`、`LlmWireError`、`LlmWireResult`、`SseEvent`、`SseDecoder`、`parseSseRetryMillis`、`parseRetryAfterMillis`、`extractRetryAfterMillis`、`sseDataLine`、`readLlmHttpBody`。
