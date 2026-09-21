# Tools、thinking 与 structured output

工具定义必须是 `LlmWireTool(name, version, description, inputSchema)`。name grammar 绑定 dialect：标准 dialect 是有界 ASCII 名称，Kimi Chat 是独立的 1–128 ASCII grammar；version 是 1–64 ASCII identity。`LlmWireToolRef` 必须精确命中 name/version，禁止 name-only 或 wildcard 引用。

## Ordered tool updates

- OpenAI Responses 的 `ToolDeclaration` 使用 profile capability 编成一个有序 `additional_tools` developer item；`ToolActivation` 只对已声明的 initial deferred tool 开放。不会生成伪造的 tool-search call/output，deactivation/replacement 默认 Unsupported。
- Anthropic Messages 的 `InstructionUpdate(System)` 是同位置 system message；activation/deactivation 是 `tool_addition`/`tool_removal` reference。动态 profile 产生 required beta header；普通声明不能扩大 initial tool pool，replacement 不会伪装成 reference。
- Kimi Chat 的动态工具更新是 tools-only system message，不能同时拥有 content；每次请求重放仍 active 的完整 definitions。activation 只加载未修改的 initial deferred tool；deactivation/replacement 没有 wire primitive。

更新按 transcript 顺序编码，不合并、不排序、不把历史工具改写成末端列表。provider 不支持的操作在 sendable bytes 产生前返回 Unsupported。

## Thinking、replay 与 schema

thinking mode 与 reasoning effort 是独立维度；显式值必须同时通过 dialect contract 和 model capabilities。provider-native replay 必须匹配 protocol、dialect ID、schema version、model constraint、assistant turn、block order 和完整 payload。Kimi `reasoning_content` 只在明确的 Kimi Chat replay allowlist 中可回放。

Tool arguments 的 `Complete` 必须是 JSON object。`validateReplyToolInputs(reply, request, mode:)` 绑定请求 transcript 的末端 active tools；Disabled 也不跳过 identity/state/conversation checks，只跳过 schema keyword checks。Malformed JSON、非 object、partial 和 schema violation 使用不同错误通道。

structured output、parallel calls、prompt cache 和 image modality 都必须由 profile capability 明确声明。无法无损表示的 JSON Schema 或 provider control 被拒绝，不静默删除关键字。
