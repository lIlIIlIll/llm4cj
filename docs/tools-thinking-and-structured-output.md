# Tools、thinking 与 structured output

函数工具使用 `LlmWireToolDefinition.Function` 和 JSON object 参数；[custom tools](custom-tools.md) 使用 `LlmWireToolDefinition.Custom` 和原始文本输入。两者共享有序声明池、调用 ID 和结果匹配规则。有 grammar 的 custom 输入在 `Strict` 与 `ValidateSupportedSubset` 下都返回 `llm.tool_grammar_validation_unsupported`；`Disabled` 显式跳过 grammar/schema 检查，仍保留身份、kind、active 定义和完整性检查。

thinking mode 与 reasoning effort 是两个独立维度。mode 包含 `ProviderDefault`、`Disabled`、`Enabled`、`Budget` 和 `Adaptive`；effort 包含 `ProviderDefault`、`Minimal`、`Low`、`Medium`、`High`、`XHigh` 和 `Max`。显式值必须同时得到 model profile 和 dialect 支持，非法组合会在编码前失败。Anthropic 只有 adaptive mode 可携带 effort；DeepSeek Chat/Messages 只有 enabled mode 可携带 effort。DeepSeek Responses 把关闭和开启分别编码为 `reasoning.effort=none` 与默认 `high`。

校验始终严格：tool call 必须属于 assistant，tool result 必须属于 user；call ID 必须非空且唯一，result 只能匹配此前尚未消费的 call，并且发送前不能留下未解决 call。非法、孤立或未来匹配的数据会失败，不提供会删改历史的 lenient 模式。

工具池和 active 视图从 transcript 顺序重放得到。历史调用使用所在位置的 active 定义；撤销不会使更早的合法调用失效。新 reply 参数校验使用 transcript 末端有效工具视图。首次声明、激活预声明定义、撤销与指令更新各自要求明确能力和 endpoint 绑定，不能从 tools 或 cache 支持推断。Responses 的 additional_tools、Anthropic reference contract 与 Kimi system.tools 的差异见[有序 transcript](ordered-transcript.md)。

工具失败语义由 dialect contract 的 `LlmWireToolErrorStyle` 显式声明。`NativeField`（Anthropic Messages）发送原生 `is_error`，成功与失败都保留该字段。`ContentMarker`（DeepSeek Messages）面向忽略 `is_error` 的 DeepSeek Anthropic 兼容端点：`isError=true` 的 tool result 会在 content 前插入固定 text block `{"type":"text","text":"[tool_error]"}`，并不再发送 `is_error` 字段；这是有损兼容，provider 无法区分该标记与巧合相同的内容，canonical `LlmWireToolResultBlock.isError` 仍是唯一权威。`Unsupported`（默认）保持 fail-closed，`isError=true` 以 `llm.tool_result_error_semantics_unsupported` 拒绝。Chat 与 Responses wire 本身没有 tool-result 错误位，canonical `isError` 在这些协议上不产生额外字段。

Tool Input Contract Validation 是 wire 校验之上的独立屏障。`validateReplyToolInputs(reply, transcript, mode:, limits:)` 按请求末端有效定义的 `inputSchema` 校验完整参数，所有模式都拒绝 unknown/inactive 工具。`ValidateSupportedSubset`（默认）可以报告已知约束证明的失败，但未知规则不能产生成功；`Strict` 先预检整棵 schema，未知规则返回 `llm.tool_schema_unsupported`。`Disabled` 只关闭 schema 检查。`llm.tool_arguments_not_executable` 与 `llm.tool_arguments_schema_violation` 分别表示参数不可执行和 schema 违例。超长诊断证据以字节数标记替代，整次调用共享工作预算。关键词、组合器及迁移行为见 [Schema 校验](schema-validation.md)。

支持子集中的 `integer` 按精确数值判断，因此 `1.0`、`1e0` 与 `10e-1` 都符合 integer，`1e-1` 不符合。`enum` 使用 JSON 值相等：对象忽略键顺序，数组保序，`1` 与 `1.0` 相等，`true` 与 `1` 不相等。任意长度的合法十进制整数及指数都按词法归一化比较，不转浮点数，也不展开指数对应的零。该语义适用于 `ValidateSupportedSubset` 与 `Strict`；`Disabled` 不运行 schema 检查。

Messages 的 provider-native `thinking` 与 `redacted_thinking` 使用 `LlmWireNativeReplayBlock`，snapshot 包含 protocol、dialect ID、native type、schema version、model constraint、scope、turn/order 与 completeness。DeepSeek Chat 和 Kimi 工具续接中的 `reasoning_content` 也使用 dialect-bound native replay，并保持在原 assistant turn。只有完成且 replay metadata 匹配的 state 才能回放。未知 native semantic block 返回带有界诊断的 `Unsupported`，不会进入 canonical reply；`LlmWireOpaqueBlock` 仅供显式诊断对象使用，永远不能进入请求。用于显示的 `LlmWireReasoningBlock` 同样不能编码为请求文本。

native replay restore 只接受其 schema version 1、assistant-turn scope 和当前实现明确允许的组合：Anthropic/DeepSeek Messages 的 `thinking`、`redacted_thinking`，OpenAI/Codex/DeepSeek Responses 的 `reasoning`，以及 DeepSeek Chat/Kimi 的 `reasoning_content`。此 schema version 与 transcript snapshot 的 version 2 是独立格式。`tool_use`、`function_call` 和 `function_call_output` 必须走 canonical ToolCall/ToolResult，不得伪装成 NativeReplay 绕过会话校验。每个允许类型还会校验其必需字符串字段。

tools、parallel tool calls、prompt cache 和 structured output 都需要对应 capability。OpenAI 风格的 `JsonSchema` 携带 name、description 与 strict；Anthropic 使用不携带这些元数据的 `JsonSchemaDocument`。无法由目标 dialect 精确表达的 schema 形式会被拒绝，而不是静默丢字段。OpenAI 当前 automatic cache lifetime 使用 `prompt_cache_options.ttl`，内置 contract 只声明当前可表达的 `30m`；不再生成 deprecated `prompt_cache_retention`。Anthropic automatic cache 使用顶层 `cache_control`，支持默认 5 分钟和显式 1 小时 TTL。[显式缓存断点](prompt-cache-breakpoints.md)通过 transcript 的类型化原始位置指定，需单独的 explicitBreakpoints capability；thinking NativeReplay 不接受隐藏的 cache_control。初始上下文和历史片段确定性编码不会被后续更新改写；这不是服务器缓存命中保证。模型目录属于上层应用，本库不会根据 model 字符串猜能力。
