# 安装与首个程序

当前 `main` 是 `v0.2.0` 候选源码，尚无对应 release tag。开发验证使用相邻 checkout 的固定路径：

```toml
[dependencies]
llm4cj = { path = "../llm4cj" }
```

下面是离线、确定性的完整程序，也是 release external-consumer gate 使用的源码。

```cj
package llm4cj_external_consumer

import llm4cj.*
import std.convert.*

main(): Int64 {
    let codec = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect())
    let request = LlmWireRequest(
        "demo-model",
        [LlmWireMessage(
            LlmWireRole.User,
            [LlmWireBlock.Text(LlmWireTextBlock("你好"))]
        )]
    )
    let payload = match (codec.encodeRequest(request).materialize()) {
        case LlmWireResult.Ok(value) => value
        case LlmWireResult.Err(_) => return 1
    }
    if (!String.fromUtf8(payload.body).contains("demo-model")) { return 1 }

    let state = match (codec.decodeResponse(LlmWireHttpResponse(
        200, [LlmWireHeader("x-request-id", "req_demo")],
        "{\"id\":\"resp_demo\",\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"你好，仓颉！\"}]}],\"usage\":{}}".toArray()
    ))) {
        case LlmWireResult.Ok(value) => value
        case LlmWireResult.Err(_) => return 1
    }
    match (state) {
        case LlmWireResponseState.Terminal(LlmWireTerminal.Completed(reply)) =>
            for (block in reply.blocks) {
                match (block) {
                    case LlmWireOutputBlock.Text(text) => println(text.text)
                    case _ => ()
                }
            }
            0
        case _ => 1
    }
}
```

预期输出是 `你好，仓颉！`。程序不创建 HTTP client。`payload.body` 是 UTF-8 bytes，`payload.headers` 包含 codec 要求的全部 header。把这两个值交给应用自己的传输层，再把响应交回 codec。
