# 安装与首个程序

## 前提

- Cangjie `1.1.0` 或更高版本。
- `cjpm` 可用。
- 当前持续验证平台为 Linux x64。

## 安装稳定版本

在应用的 `cjpm.toml` 中加入：

```toml
[dependencies]
llm4cj = { git = "https://github.com/lIlIIlIll/llm4cj.git", tag = "v0.1.0" }
```

`v0.1.0` 是稳定 tag。若显式改用 `branch = "main"`，你使用的是开发分支。

## 运行离线示例

将下面内容保存为 `src/main.cj`。程序不发起 HTTP 请求，因此输出是确定的。

```cj
package llm4cj_external_consumer

import llm4cj.*

main(): Int64 {
    let request = LlmWireRequest(
        "demo-model",
        [LlmWireMessage(
            LlmWireRole.User,
            [LlmWireBlock(LlmWireBlockKind.Text, text: "你好")]
        )]
    )
    let payload = encodeLlmWireRequest(LlmWireProtocol.Responses, request)
    if (!payload.contains("demo-model")) { return 1 }

    let reply = decodeLlmWireReply(
        LlmWireProtocol.Responses,
        "{\"id\":\"resp_demo\",\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"你好，仓颉！\"}]}],\"usage\":{}}"
    )
    for (block in reply.blocks) {
        if (let LlmWireBlockKind.Text <- block.kind) { println(block.text) }
    }
    0
}
```

执行 `cjpm run`，预期输出 `你好，仓颉！`。真实集成只需在 encoder 与 decoder 之间加入应用自己的 HTTP client，并保持响应大小限制。

下一步阅读[协议选择](choosing-a-protocol.md)和[请求与响应](requests-and-replies.md)。
