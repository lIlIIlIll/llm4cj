# 选择协议

协议由 endpoint 的 wire contract 决定，不由模型名称决定。

| endpoint 文档要求 | `LlmWireProtocol` | 说明 |
| --- | --- | --- |
| Responses API | `Responses` | 新集成的默认选择 |
| OpenAI-compatible Chat Completions | `ChatCompletions` | 使用 `messages`/`choices` envelope |
| Anthropic-compatible Messages | `Messages` | 使用 content block 与 Messages SSE 事件 |

如果 provider 同时提供多个 endpoint，优先使用 `Responses`；如果 endpoint 只声明 Chat Completions 或 Messages，必须跟随 endpoint。

## 完整程序

```cj
package protocol_choice

import llm4cj.*

main(): Int64 {
    let request = LlmWireRequest(
        "demo",
        [LlmWireMessage(LlmWireRole.User, [LlmWireBlock(LlmWireBlockKind.Text, text: "ping")])]
    )
    println(encodeLlmWireRequest(LlmWireProtocol.Responses, request))
    println(encodeLlmWireRequest(LlmWireProtocol.ChatCompletions, request))
    println(encodeLlmWireRequest(LlmWireProtocol.Messages, request))
    0
}
```

## DeepSeek 差异

源码和测试已验证的 DeepSeek dialect 通过 `encodeDeepSeekChatWireRequest` 与 `encodeDeepSeekMessagesWireRequest` 显式提供。DeepSeek Messages 接受 toggle 或 effort thinking control，不接受 budget；`Minimal`/`Off` effort 会被拒绝。不要把这些规则外推到其他 provider。
