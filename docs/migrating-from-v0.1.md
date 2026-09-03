# 从 v0.1 迁移

v0.1.1 是一次有意的 breaking release，不提供旧 API shim。

| v0.1.0 | v0.1.1 |
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
| request encoder 返回 JSON 字符串 | `LlmWirePreparedRequest.materialize` 返回 UTF-8 body 与已协调 headers |
| system 字符串与 request 内 streaming 开关 | 有序 `LlmWireInstruction`，streaming 在 `encodeRequest` 调用时选择 |
| ToolResult 保存单个字符串 | `LlmWireToolResultContent` 的有序 text/image 数组 |
| 仅有 SSE event 大小限制 | `LlmWireStreamLimits` 同时限制跨事件累计的语义输出和输入 provider event 数 |

迁移时为每个 endpoint 选择六个内置 model-profile/codec 工厂，再从真实 model catalog 构造 capability。稳定包不再公开自由 codec 构造器。自定义 `LlmWireStandardDialect` 已移动到 `llm4cj.experimental`，只能使用非保留 compatibility ID、`ProviderDefault` thinking，且不提供 native replay schema。不要为了通过校验把所有 capability 都设为 true。把所有终态 match 改为穷尽处理，且仅将 schema version 1、assistant-turn scope、allowlist 类型的完整 native replay block 回放给原内置 dialect。Anthropic structured output 应迁移为 `JsonSchemaDocument`；OpenAI 风格的命名 schema 继续使用 `JsonSchema`。

图片输入现在必须通过 `LlmWireCapabilities(input: LlmWireInputCapabilities(modalities: [Text, Image]))` 按模型显式开启。thinking mode 与 reasoning effort 也迁移到独立字段和 `LlmWireThinkingCapabilities`。`LlmWireImageSourceKind.File` 表示 Files API `file_id`；Messages 编码会产生所需 beta header。OpenAI automatic cache 的显式 lifetime 已从 deprecated 24h retention 迁移为 `prompt_cache_options.ttl=30m`。

公共 JSON 参数从 `yjson.JsonNode` 迁移为 `LlmWireJson`。推荐使用六个 `*ModelProfile` 与 `*Codec` 工厂，让 codec 在构造后持续验证 model、dialect 和 capability 的绑定关系。

重复构造同类请求时，改用 `codec.newRequestBuilder()`。setter 会检查局部值，`build()` 返回 `LlmWireResult<LlmWireRequest>`。同一个请求既可用于固定响应，也可通过 `encodeRequest(request, streaming: true)` 用于流式响应。

v0.1.1 候选期将 dialect/capability 的公开可变 `Array` 字段改为返回 defensive copy 的只读 property，并为 `LlmWireEvent` 增加了显式 identity/usage 字段。这是有意的 source/ABI/行为不兼容变更：调用方不能再通过修改返回数组改变 codec 行为，应在构造 contract/capability 时传入最终值并重新编译。
