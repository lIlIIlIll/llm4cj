# 设置 Anthropic 显式缓存断点

用 transcript 的 cacheBreakpoints 指定缓存字段挂载到哪个原始项。此功能支持内置 anthropic.messages.v1，需要调用方在模型 capability 中声明 explicitBreakpoints: true 和所用 lifetime。库负责请求校验和编码；服务端是否命中缓存仍取决于实际模型、输入长度、前缀和请求时机。

~~~cj
let capabilities = LlmWireCapabilities(cache: LlmWireCacheCapabilities(
    lifetimes: [LlmWirePromptCacheLifetime.FiveMinutes, LlmWirePromptCacheLifetime.OneHour],
    explicitBreakpoints: true
))
let codec = anthropicMessagesCodec(anthropicMessagesModelProfile(
    "your-model", capabilities: capabilities
))
let transcript = LlmWireTranscript(
    LlmWireInitialContext(instructions: [
        LlmWireInstruction(LlmWireInstructionRole.System, "Stable instructions")
    ]),
    items: [LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [
        LlmWireBlock.Text(LlmWireTextBlock("Stable context")),
        LlmWireBlock.Text(LlmWireTextBlock("Current question"))
    ]))],
    cacheBreakpoints: [
        LlmWireCacheBreakpoint(LlmWireCachePosition.InitialInstruction(0),
            lifetime: LlmWirePromptCacheLifetime.OneHour),
        LlmWireCacheBreakpoint(LlmWireCachePosition.MessageBlock(0, 0))
    ]
)
let request = LlmWireRequest("your-model", transcript, maxOutputTokens: Some(256))
let prepared = codec.encodeRequest(request)
~~~

这里的 system block 写入 cache_control: {"type":"ephemeral","ttl":"1h"}，第一条用户文本写入默认显式 5m marker；当前问题保持在断点之后。显式断点不要求启用顶层 PromptCache.Automatic。

| 位置 | 指向 |
| --- | --- |
| InitialTool(index) | 初始工具数组中实际输出的非 deferred Function 工具定义 |
| InitialInstruction(index) | 初始 System 指令数组中的 text block |
| MessageBlock(itemIndex, blockIndex) | 原始 Message 项的顶层 Text、用户 Image、ToolCall 或整个 ToolResult |
| Item(itemIndex) | InstructionUpdate、ToolActivation 或 ToolDeactivation 的唯一顶层内容块 |

索引从零开始。Item 不推断消息的最后一块，也不接收不会输出 wire block 的重复 ToolDeclaration。ToolResult 内部的 text/image 子内容、thinking replay、Refusal 和诊断块不能直接指定断点。给 deferred 工具定义挂 marker 会失败；可在后续合法的 tool activation、text 或 result 上明确设置位置。工具操作仍需要相应的 endpoint profile 和 context capability。

Function 与 Custom 声明都保留原始工具数组的索引。Anthropic 不支持 OpenAI 的原始文本 Custom 工具；请求中含有这类声明时返回 Unsupported，不会先删除它再重新解释缓存位置。

构造 transcript 时检查索引范围、重复位置和最多四个 marker。编码时再检查实际输出目标、模型 capability 和 TTL。错误保留 inputItemIndex、blockIndex 等有界位置上下文，不携带 prompt 内容。

TTL 校验按照 Anthropic 的 tools → system → messages 顺序执行，与 metadata 数组顺序无关。1h 必须位于 5m 之前。显式断点支持 ProviderDefault、FiveMinutes、OneHour；ProviderDefault 使用协议规定的默认 5m，并省略 wire 的 ttl。30m 和 24h 会返回 Unsupported。

Automatic 与显式断点合用时，Automatic 占一个槽，最多保留三个显式 marker。即使最后一个显式 marker 与自动目标相同且 TTL 相同，四显式加 Automatic 仍会失败。自动目标与显式目标 TTL 不同时也会失败。库保留声明的位置，不合并或移动 marker。Automatic 本身仍采用服务端的最后一个合法缓存块规则。

append 保留已有 marker。builder 的 setTranscript、setCacheBreakpoints 和 build 复制元数据，reset 清空它们；失败的 setter 保持先前状态。若需改变缓存位置或 TTL，应创建新的 metadata 或调用 setCacheBreakpoints，并重新编码。

显式 marker 随 transcript snapshot v3 持久化；reader 支持 v1/v2/v3。Custom 工具与缓存 metadata 可同时保存在 v3 中；未使用任何 v3 语义的 transcript 继续写入原有 v2 形状。旧 snapshot 和未携带缓存字段的 custom-only v3 恢复后没有显式 marker。顶层 Automatic 仍属于 request 配置，不在 transcript snapshot 中。

实验包的 prepareAnthropicCachePrewarm 可使用显式稳定前缀，允许顶层 PromptCache.ProviderDefault。预热的其他零输出限制保持不变；传输、重试与预热时机由应用处理。

离线公共 consumer 验证命令：

~~~bash
python3 scripts/check_cache_fixtures.py
~~~

它分别校验直接构造、snapshot restore 和 builder 三条路径，先比较独立的完整请求/error oracle，再比较路径一致性。来源和 checked_at 固定在 fixtures/cache-requests.json，live provider 状态为 not_run。

协议依据：[Prompt caching](https://platform.claude.com/docs/en/build-with-claude/prompt-caching)、[Tool search 的 deferred 限制](https://platform.claude.com/docs/en/agents-and-tools/tool-use/tool-search-tool#prompt-caching)、[会话中的工具更新](https://platform.claude.com/docs/en/build-with-claude/mid-conversation-system-messages)。
