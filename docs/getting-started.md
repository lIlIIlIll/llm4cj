# 安装与首个程序

在 `cjpm.toml` 中固定发布 tag：

```toml
[dependencies]
llm4cj = { git = "https://github.com/lIlIIlIll/llm4cj.git", tag = "v0.2.0" }
```

下面是离线、确定性的完整程序，也是 release external-consumer gate 使用的源码。

```cj
package llm4cj_external_consumer

import llm4cj.*

main(): Int64 {
    let codec = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect())
    let request = LlmWireRequest(
        "demo-model",
        [LlmWireMessage(
            LlmWireRole.User,
            [LlmWireBlock.Text(LlmWireTextBlock("你好"))]
        )]
    )
    let payload = codec.encodeRequest(request)
    if (!payload.contains("demo-model")) { return 1 }

    let state = codec.decodeResponse(
        "{\"id\":\"resp_demo\",\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"你好，仓颉！\"}]}],\"usage\":{}}"
    )
    match (state) {
        case LlmWireResponseState.Terminal(LlmWireTerminal.Succeeded(reply)) =>
            for (block in reply.blocks) {
                match (block) {
                    case LlmWireBlock.Text(text) => println(text.text)
                    case _ => ()
                }
            }
            0
        case _ => 1
    }
}
```

预期输出是 `你好，仓颉！`。程序不创建 HTTP client；把 `payload` 交给应用自己的传输层，再把响应体交回 codec。
