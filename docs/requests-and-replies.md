# 请求与响应

`LlmWireRequest` 包含 model、message、system、tool、thinking、token limit、streaming、cache、service tier、tool choice 和 structured output。默认值包括 `Effort(Medium)`、`maxOutputTokens = 2000`、`streaming = false`、`parallelToolCalls = true`。

`LlmWireReply` 返回有序 `blocks`、provider 的原始 `stopReason`、`usage` 与 `responseId`。应用应按 `LlmWireBlockKind` 分派，不要假设 reply 只有文本。

## 完整程序

```cj
package request_reply

import llm4cj.*

main(): Int64 {
    let request = LlmWireRequest(
        "demo",
        [LlmWireMessage(LlmWireRole.User, [LlmWireBlock(LlmWireBlockKind.Text, text: "ping")])],
        system: "简洁回答",
        maxOutputTokens: 128
    )
    println(encodeResponsesWireRequest(request))
    let reply = decodeResponsesWireReply(
        "{\"id\":\"r1\",\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"pong\"}]}],\"usage\":{\"input_tokens\":3,\"output_tokens\":1}}"
    )
    println(reply.blocks[0].text)
    println(reply.usage.outputTokens)
    0
}
```

图片使用 `LlmWireImage`：URL 图片传 `Url`；base64 图片传 `Base64`、media type 和原始 base64 数据。缺失 image payload 会抛出 `llm.image_missing`。

`LlmWireOpaqueState` 保存无法无损投影到统一字段的 provider 数据。把含 reasoning 或 tool call 的 reply 再编码回原协议时，应保留 block 上的 opaque state。

`LlmWireUsage` 分别记录 input、output、reasoning、cache read 与 cache write token。字段不存在时为 `0`。Messages 的 `inputTokens` 包含 cache read/write token。
