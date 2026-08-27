# Tools、thinking 与 structured output

thinking 控制分为 `ProviderDefault`、`Disabled`、`Enabled`、`Effort`、`Budget` 和 `Adaptive`。默认值不发送字段；显式值必须同时得到 capability 和 dialect 映射支持。Anthropic adaptive effort 写入 `output_config.effort`，不会错误地嵌入 `thinking`。

校验始终严格：tool call 必须属于 assistant，tool result 必须属于 user；call ID 必须非空且唯一，result 只能匹配此前尚未消费的 call，并且发送前不能留下未解决 call。非法、孤立或未来匹配的数据会失败，不提供会删改历史的 lenient 模式。

Messages 的 provider-native `thinking` 与 `redacted_thinking` 使用 `LlmWireNativeReplayBlock`，snapshot 包含 protocol、dialect ID、native type、schema version、model constraint、scope、turn/order 与 completeness。只有完成且 replay metadata 匹配的 state 才能回放。未知 native block 使用 `LlmWireOpaqueBlock` 保存为诊断数据，永远不能进入请求。用于显示的 `LlmWireReasoningBlock` 同样不能编码为请求文本。

tools、parallel tool calls、prompt cache 和 structured output 都需要对应 capability。Anthropic 的显式 cache breakpoint 属于 content/tool block 级 native state，通用 automatic cache 选项会被拒绝；库不会生成不可靠的顶层 `cache_control`。模型目录属于上层应用，本库不会根据 model 字符串猜能力。
