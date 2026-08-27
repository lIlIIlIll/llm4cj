# Tools、thinking 与 structured output

thinking 控制分为 `ProviderDefault`、`Disabled`、`Enabled`、`Effort`、`Budget` 和 `Adaptive`。默认值不发送字段；显式值必须同时得到 capability 和 dialect 映射支持。Anthropic adaptive effort 写入 `output_config.effort`，不会错误地嵌入 `thinking`。DeepSeek Responses 把关闭和开启分别编码为 `reasoning.effort=none` 与 `reasoning.effort=high`；DeepSeek Chat 的显式 effort 会同时写入 `thinking.type=enabled` 和 `reasoning_effort`。

校验始终严格：tool call 必须属于 assistant，tool result 必须属于 user；call ID 必须非空且唯一，result 只能匹配此前尚未消费的 call，并且发送前不能留下未解决 call。非法、孤立或未来匹配的数据会失败，不提供会删改历史的 lenient 模式。

Messages 的 provider-native `thinking` 与 `redacted_thinking` 使用 `LlmWireNativeReplayBlock`，snapshot 包含 protocol、dialect ID、native type、schema version、model constraint、scope、turn/order 与 completeness。DeepSeek Chat 工具续接中的 `reasoning_content` 也使用 dialect-bound native replay，并保持在原 assistant turn。只有完成且 replay metadata 匹配的 state 才能回放。未知 native semantic block 返回带有界诊断的 `Unsupported`，不会进入 canonical reply；`LlmWireOpaqueBlock` 仅供显式诊断对象使用，永远不能进入请求。用于显示的 `LlmWireReasoningBlock` 同样不能编码为请求文本。

restore 只接受 schema version 1、assistant-turn scope 和当前实现明确允许的组合：Anthropic/DeepSeek Messages 的 `thinking`、`redacted_thinking`，OpenAI/DeepSeek Responses 的 `reasoning`，以及 DeepSeek Chat 的 `reasoning_content`。`tool_use`、`function_call` 和 `function_call_output` 必须走 canonical ToolCall/ToolResult，不得伪装成 NativeReplay 绕过会话校验。每个允许类型还会校验其必需字符串字段。

tools、parallel tool calls、prompt cache 和 structured output 都需要对应 capability。OpenAI 风格的 `JsonSchema` 携带 name、description 与 strict；Anthropic 使用不携带这些元数据的 `JsonSchemaDocument`。无法由目标 dialect 精确表达的 schema 形式会被拒绝，而不是静默丢字段。Anthropic 的显式 cache breakpoint 属于 content/tool block 级 native state，通用 automatic cache 选项会被拒绝；库不会生成不可靠的顶层 `cache_control`。模型目录属于上层应用，本库不会根据 model 字符串猜能力。
