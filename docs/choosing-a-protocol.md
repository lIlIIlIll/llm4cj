# 协议与 dialect

protocol 定义 envelope；dialect 定义 provider 对同一 envelope 的字段语义。codec 构造时冻结 protocol、compatibility ID、contract、profile 和 transcript capability identity。

| protocol | 内置 dialect | profile/codec 工厂 |
| --- | --- | --- |
| Responses | `openai.responses.v1` | `openAiResponsesModelProfile` / `openAiResponsesCodec` |
| Responses | `deepseek.responses.v1` | `deepSeekResponsesModelProfile` / `deepSeekResponsesCodec` |
| Chat Completions | `openai.chat.v1` | `openAiChatModelProfile` / `openAiChatCodec` |
| Chat Completions | `deepseek.chat.v1` | `deepSeekChatModelProfile` / `deepSeekChatCodec` |
| Chat Completions | `kimi.chat.v1` | `kimiChatModelProfile` / `kimiChatCodec` |
| Messages | `anthropic.messages.v1` | `anthropicMessagesModelProfile` / `anthropicMessagesCodec` |
| Messages | `deepseek.messages.v1` | `deepSeekMessagesModelProfile` / `deepSeekMessagesCodec` |

不要因为两个 provider 共享 envelope 就复用错误的 encoder。Kimi Chat 不是 Kimi Messages/Responses；Kimi 的 max_completion_tokens、thinking、tool grammar、MFJS schema 和 reasoning replay 都由独立 contract 管理。

## Capability selection

未提供 model capability 时，只能使用 contract 允许的基础文本和 ProviderDefault controls。动态 transcript operation 必须同时满足 profile endpoint ID、contract version、model gate 和 operation encoding。缓存 capability 只表示 wire 可表达；它不证明 provider 的实时命中率。

应用负责 endpoint、凭据、retry 和 model catalog。库不根据 URL 或 provider 名称猜测能力，也不在不同 protocol 之间 fallback。
