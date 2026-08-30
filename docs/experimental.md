# 实验 API

`llm4cj.experimental` 包含尚未进入 v0.2 稳定兼容承诺的协议功能。它与稳定包一起构建和测试，但其声明、错误码和行为可以在 minor release 中调整；稳定 API/ABI 快照不会包含本包。

## 自定义 dialect

`LlmWireStandardDialect` 和 `customDialectCodec` 允许在 Responses、Chat Completions 或 Messages 现有 envelope 内复用声明式 request style。实验 dialect：

- 必须使用非保留 compatibility ID；
- 只能使用核心已有的字段映射；
- 只能使用 `ProviderDefault` thinking，不能声明 reasoning effort；
- 不能替换 JSON/SSE parser、流生命周期、terminal evidence 或 canonical assembler；
- 不具备 provider-native reasoning replay 能力。

新的协议族应作为核心 codec 模块实现并提供 conformance suite，而不是通过 custom dialect 绕过核心不变量。

## Anthropic cache pre-warm

`prepareAnthropicCachePrewarm` 返回 `LlmWireResult<LlmWireCachePrewarmExchange>`。exchange 同时持有准备发送的 `request` 和 request-aware `decodeResponse`，避免把预热成功误当成普通生成截断。

预热请求必须满足：

- 使用 Anthropic Messages request style；
- `maxOutputTokens` 为 `0`；
- 使用 automatic prompt cache；
- 不启用 streaming、thinking、reasoning effort 或 structured output；
- 不使用 `Required` tool choice。

调用方先对 `exchange.request` 执行 `materialize`，再把有界 HTTP 响应交给 `exchange.decodeResponse`。只有单 choice、空 content、`stop_reason: "max_tokens"` 的完成响应才返回 usage；其他响应 fail closed。

## Custom tool 与 grammar

`LlmWireCustomTool`、`LlmWireCustomToolFormat`、`LlmWireGrammar` 和 `LlmWireGrammarSyntax` 只描述实验语义，目前不会被稳定 request encoder 自动发送。构造器会拒绝空名称或空 grammar；使用方必须把它们视为实验配置，而不是稳定 provider 能力声明。
