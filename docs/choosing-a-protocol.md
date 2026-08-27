# 协议与 dialect

protocol 定义 envelope；dialect 定义 provider 对同一 envelope 的字段语义。两者必须匹配，否则 `LlmWireCodec` 构造失败。

| protocol | 首选内置 dialect | 其他内置 dialect |
| --- | --- | --- |
| Responses | `openai.responses.v1` | `deepseek.responses.v1` |
| Chat Completions | `openai.chat.v1` | `deepseek.chat.v1` |
| Messages | `anthropic.messages.v1` | `deepseek.messages.v1` |

新集成优先 Responses。只有 endpoint 明确要求 Chat Completions 或 Messages 时才切换。兼容名称不是行为承诺；调用方还必须根据具体模型提供 `LlmWireCapabilities`。

未提供 capability 时，仅保证基础文本和 `ProviderDefault` thinking。任何显式 thinking、tools、structured output、parallel tool calls、service tier 或 stable cache 选项都必须先声明支持。
