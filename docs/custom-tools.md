# Responses custom tools

未发布的 0.3.0 支持 Responses 原生 custom tools。输入是原始字符串，例如代码、SQL 或自然语言，`"{}"` 仍是 `LlmWireToolArguments.Text("{}")`，不会被转换成 JSON 参数。库负责 wire、关联和回放；应用负责执行工具与 grammar 校验。

```cangjie
import llm4cj.*

let grammar = LlmWireGrammar(LlmWireGrammarSyntax.Regex, "[a-z]+")
let definition = LlmWireToolDefinition.Custom(LlmWireCustomTool(
    "emit_word", format: LlmWireCustomToolFormat.Grammar(grammar)
))
let declaration = LlmWireToolDeclaration(definition)
let capabilities = LlmWireCapabilities(tools: LlmWireToolCapabilities(
    enabled: true, customFormats: [LlmWireCustomToolFormatKind.Regex]
))
let codec = openAiResponsesCodec(openAiResponsesModelProfile(
    "application-selected-model", capabilities: capabilities
))
```

把 `declaration` 放入 `LlmWireInitialContext.tools`，或在对应 endpoint profile 明确允许时按顺序追加 `LlmWireInputItem.ToolDeclaration`。函数和 custom 定义共用一个池；同名定义不能改变 kind、version、description、schema 或 grammar 字节。工具名使用本库的 `[A-Za-z0-9_-]{1,64}` 规则。

`LlmWireCustomToolFormat.Text` 编码为 `{"type":"text"}`；`Grammar` 编码为 `{"type":"grammar","syntax":"regex"|"lark","definition":...}`。custom 定义不携带函数的 `parameters` 或 `strict`。grammar 不得为空。普通 OpenAI Responses 将初始工具放在顶层 `tools`；Codex subscription 使用 `additional_tools` input。动态声明仍要求独立的 context-update capability，不从 custom 支持推断。

内置 OpenAI Responses 与 Codex Responses 声明 Text、Regex、Lark wire 格式。模型还必须通过 `LlmWireToolCapabilities.customFormats` 明确声明该格式；默认列表为空。Chat、Messages 与 DeepSeek Responses 内置 contract 没有 custom tool 支持，不能只通过启用模型 capability 绕过。库不会通过 model 名称猜测能力。

固定响应、SSE 与 Codex WebSocket 的 `custom_tool_call` 都映射到 `LlmWireToolCallBlock`。`call.kind` 从参数 tag 推导；`ToolCallStarted` 和 `ToolArgumentsDelta` 的 identity 带有相同 kind，delta 是原始输入片段。SSE 的 input done 字段是 `input`，不是 `arguments`。每个 item 都必须保持 `item_id`、`output_index`、`call_id`、name 和 kind 一致；正常完成必须包含 input done、output item done 与终态响应，终态单帧响应也可独立解码。

只有成功终态、明确 `status: "completed"` 或已关联的 input done 证据才产生 `Text`。仍在生成或截断的输入是 `PartialText`，不会因为内容恰好构成 JSON 或合法代码而升级。`PartialText` 可用于诊断与持久化，但 continuation、请求编码和工具执行屏障都会拒绝它。已完成的 custom 输入可以在整体 reply 不完整时保留完成证据。

结果必须使用 `LlmWireToolResultBlock(callId, content, kind: LlmWireToolKind.Custom)`，否则会与待处理调用 kind 不符。一个 text part 编码成 `custom_tool_call_output.output` 字符串；多个 text/image part 编码成内容数组。空字符串和空数组均保留。image 仍要求对应 input capability；file 和 audio 结果没有此路径的 canonical 表示，不能注入为原生 JSON。Responses 不支持 `isError: true`。

调用 `validateReplyToolInputs(reply, transcript, mode:)` 时，所有模式都会检查 active 定义、kind、身份与 custom 输入完整性。无 grammar 的完整 Text 可通过 `Strict` 与 `ValidateSupportedSubset`。Regex 使用 provider 的 Rust regex 语义，Lark 使用 provider 的 grammar 子集；本库没有实现这两个引擎，因此有 grammar 时这两种模式都返回 `llm.tool_grammar_validation_unsupported`，而不是声称校验成功。`Disabled` 显式跳过 grammar/schema 检查，仍不能绕过工具身份和可执行性检查。

namespace、program caller 和异步 custom 调用尚无完整 canonical 语义，解码会以 `Unsupported` 拒绝；扁平 direct 同步调用受支持。缺少必要字段、错误类型、冲突与错误事件关联返回确定性错误。请求 JSON 写入在追加前受 8 MiB/256 深度限制；stream 自定义输入与函数参数共用 `maxToolArgumentsBytes`，同时计入总语义和保留状态预算。

快照只在 custom 定义、Text/PartialText 调用或 custom 结果存在时写 v3；旧语义继续写出相同的 v2。restore 接受 v1/v2/v3，旧版本的 `Partial` 或 `InvalidJson` 仍属于函数工具，不会猜测成 custom 输入。v3 保留 kind、格式和原始文本，恢复后仍要经过请求与完整会话校验。原 experimental 类型现从稳定包导入；`LlmWireToolDeclaration.tool` 与 `effectiveTools` 变为 tagged definition，函数 schema 需通过 `Function(value)` 分支访问。原 `LlmWireToolDeclaration(LlmWireTool(...))` 构造重载保留。

协议依据为 [custom tools guide](https://developers.openai.com/api/docs/guides/function-calling#custom-tools)、[Responses streaming events](https://developers.openai.com/api/reference/resources/responses/streaming-events) 和 [Codex SIWC requirements](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations#responses-api-requirements)，checked 2026-10-18。离线 schema-derived fixtures 不能证明实时模型或账号支持；本轮 live provider 为 `not_run`。

0.3.0 的请求预算统一适用于 Responses、Chat Completions 与 Messages，包括工具定义、完整历史和协议 envelope。序列化在追加前限制为 8 MiB 和 256 层；单独合法的 JSON schema 加上请求包装后仍可能超限。普通协议统一抛出 `BodyLimit` / `llm.request_too_large`，Codex 保留 `llm.codex_request_too_large` 及原消息。Chat/Messages 调用方不能再依赖超出该预算的编码结果；拒绝后可以用同一 codec 编码更小的独立请求。
