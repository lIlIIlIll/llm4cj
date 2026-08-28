# 协议与 dialect

protocol 定义 envelope；dialect 定义 provider 对同一 envelope 的字段语义。两者必须匹配，否则 `LlmWireCodec` 构造失败。

`LlmWireStandardDialect` 只扩展现有三种协议族。自定义 contract 不能使用六个内置 compatibility ID；generation speed、structured output、cache、tool choice 等声明若没有对应 request-style 映射，会在 contract 构造或请求校验阶段失败，不能成为静默 no-op。新 envelope、JSON/SSE parser 或 terminal 规则不属于 dialect 扩展面。

codec 构造时会冻结 dialect contract、protocol 与 compatibility identity；后续修改自定义 `LlmWireDialect` 实现不会改变既有 codec。provider-native reasoning replay 仅对六个内置 dialect 开放；`LlmWireStandardDialect` 因此只能声明 `ProviderDefault` thinking，带 thinking control 或 effort level 的自定义 contract 会在 dialect 构造时失败。直接实现 `LlmWireDialect` 也不能绕过该限制或冒用内置 compatibility ID，codec 构造会再次 fail-closed，避免出现请求可编码、响应却无法安全续轮的半闭合扩展。

请求还会执行 dialect 组合校验。Anthropic 的手动 budget thinking 不允许 `Required` tool choice；adaptive thinking 不受该限制。DeepSeek Chat 显式启用 thinking 或 effort 时不得同时发送显式 `tool_choice`。DeepSeek Responses 的 tool choice 能力独立处理，不套用 Chat 限制。

| protocol | 首选内置 dialect | 其他内置 dialect |
| --- | --- | --- |
| Responses | `openai.responses.v1` | `deepseek.responses.v1` |
| Chat Completions | `openai.chat.v1` | `deepseek.chat.v1` |
| Messages | `anthropic.messages.v1` | `deepseek.messages.v1` |

新集成优先 Responses。只有 endpoint 明确要求 Chat Completions 或 Messages 时才切换。兼容名称不是行为承诺；调用方还必须根据具体模型提供 `LlmWireCapabilities`。

未提供 capability 时，仅保证基础文本和 `ProviderDefault` thinking。任何图片、显式 thinking、tools、structured output、parallel tool calls、service tier 或 cache 选项都必须先声明支持。

图片能力按模型声明，不按 provider 一刀切。`deepseek-v4-flash-vision-exp` 可在 Chat、Responses 与 Messages 中使用 URL、JPEG/PNG/GIF/WebP base64 或 Files API `file_id`；调用方必须在 `LlmWireCapabilities.inputModalities` 中声明 `Image`。未声明时统一返回 `llm.image_input_unsupported`。Messages 的 file source 会自动加入 `anthropic-beta: files-api-2025-04-14`。普通 DeepSeek Flash/Pro 不应声明该能力。

Chat Files API 的 wire shape 属于 dialect：OpenAI Chat 使用嵌套的 `{"type":"file","file":{"file_id":"..."}}`，DeepSeek Chat 使用 `{"type":"file","file_id":"..."}`。codec 不会因为两者共享 Chat envelope 而混用内容块结构。

Anthropic Messages 的 automatic prompt cache 编码为顶层 `cache_control`。`ProviderDefault` 与 `FiveMinutes` 使用默认 5 分钟 TTL，`OneHour` 显式写入 `ttl: "1h"`；其他 lifetime 在发送前拒绝。automatic cache 请求允许 `maxOutputTokens=0` 用于 cache prewarm，其他 dialect 或未启用 cache 的零输出上限仍是非法请求。

DeepSeek Messages compatibility 仍不支持 `redacted_thinking`；合法但无法安全回放的响应返回 `Unsupported`。
