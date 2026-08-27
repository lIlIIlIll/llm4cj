# 从 v0.1 迁移

v0.2.0 是一次有意的 breaking release，不提供旧 API shim。

| v0.1 | v0.2 |
| --- | --- |
| 仅传 `LlmWireProtocol` 的自由函数 | 构造绑定 protocol/dialect/capability 的 `LlmWireCodec` |
| 默认 medium thinking | 默认 `ProviderDefault`，不发送 thinking 字段 |
| `LlmWireBlockKind` 加可选字段 | 封闭的 `LlmWireBlock` payload enum |
| 普通 reasoning 文本可重建 thinking | provider-native thinking 使用不可伪造的 opaque replay |
| 固定 reply 或单一 Completed | `Pending`、`Succeeded`、`Incomplete`、`Failed` |
| 无状态 frame decoder | `newStreamDecoder` 返回可增量推进的协议状态机 |
| tool arguments 字符串 | `Complete`、`InvalidJson`、`InvalidShape`、`Partial` |
| 可回放 reasoning/opaque | display-only `Reasoning`、dialect-bound `NativeReplay`、diagnostic-only `Opaque` |
| usage 缺失时为 0 | `Option<Int64>` 区分缺失与明确的零 |
| request encoder 返回 JSON 字符串 | `LlmWireEncodedRequest` 同时携带 body、required headers 与 feature requirements |
| 仅有 SSE event 大小限制 | `LlmWireStreamLimits` 同时限制跨事件累计的语义输出 |

迁移时先为每个 endpoint 选择内置或自定义 dialect，再从真实 model catalog 构造 capability。不要为了通过校验把所有 capability 都设为 true。把所有终态 match 改为穷尽处理，且仅将完整 native replay block 回放给原 dialect。Anthropic structured output 应迁移为 `JsonSchemaDocument`；OpenAI 风格的命名 schema 继续使用 `JsonSchema`。
