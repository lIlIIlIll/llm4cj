# 安装与首个程序

当前源码版本是 **v0.2.0**，要求 Cangjie `>= 1.1.0`。开发验证可使用相邻 checkout 的固定路径：

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
    let codec = openAiResponsesCodec(openAiResponsesModelProfile("demo-model", transcriptCapabilities: LlmWireTranscriptCapabilities("openai.responses.v1", "1")))
    let request = LlmWireRequest(
        "demo-model",
        LlmWireTranscript(LlmWireInitialContext(), items: [LlmWireInputItem.Message(LlmWireMessage(
            LlmWireRole.User,
            [LlmWireBlock.Text(LlmWireTextBlock("你好"))]
        ))])
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

预期输出是 `你好，仓颉！`。程序不创建 HTTP client：`payload.body` 是 UTF-8 bytes，`payload.headers` 包含 codec 要求的全部 header。应用把这两个值交给自己的传输层，再把响应交回 codec。

profile 工厂必须显式绑定 transcript capability identity：

- 静态请求使用 `LlmWireTranscriptCapabilities("openai.responses.v1", "1")`。
- Responses、Anthropic 和 Kimi 的动态更新必须在 profile entries 中声明对应 operation/encoding。
- 不要用 provider 名称、URL 子串或 `tools: true` 推导动态能力。
