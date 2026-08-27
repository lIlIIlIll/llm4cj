# Tools、thinking 与 structured output

thinking 控制分为 `ProviderDefault`、`Disabled`、`Enabled`、`Effort`、`Budget` 和 `Adaptive`。默认值不发送字段；显式值必须同时得到 capability 和 dialect 映射支持。Anthropic adaptive effort 写入 `output_config.effort`，不会错误地嵌入 `thinking`。

严格校验是默认策略：tool call ID 必须非空且唯一，tool result 只能匹配此前尚未消费的 call。非法、孤立或未来匹配的数据会失败。`Lenient` 只用于明确接纳脏历史的场景，并按原 block 顺序编码，不会静默删除数据。

Messages 的 provider-native thinking state 使用 `LlmWireOpaqueBlock`。`thinking`、`redacted_thinking` 和未知 block 会保存完整原始对象；只有完成、protocol 相同且 dialect ID 相同的 opaque block 才能回放。用于显示的 reasoning 与回放数据彼此分离。

tools、parallel tool calls 和 structured output 都需要对应 capability。模型目录属于上层应用，本库不会根据 model 字符串猜能力。

DeepSeek Chat 的 `reasoning_content` 是 provider-native 续轮状态。decoder 在 `LlmWireReasoningBlock.replayDialectId` 记录来源；只有声明对应 Chat reasoning 字段的相同 dialect 能回放，并且 reasoning、可见 content 与 tool calls 保持在同一 assistant message 中。
