# llm4cj

[![Tests passing](https://github.com/lIlIIlIll/llm4cj/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/lIlIIlIll/llm4cj/actions/workflows/ci.yml)
[![Coverage](https://codecov.io/gh/lIlIIlIll/llm4cj/branch/main/graph/badge.svg)](https://codecov.io/gh/lIlIIlIll/gh/lIlIIlIll/llm4cj)
[![Release](https://img.shields.io/github/v/release/lIlIIlIll/llm4cj)](https://github.com/lIlIIlIll/llm4cj/releases)
[![Cangjie](https://img.shields.io/badge/Cangjie-%3E%3D%201.1.0-f25c2a)](https://cangjie-lang.cn/)
[![License](https://img.shields.io/github/license/lIlIIlIll/llm4cj)](LICENSE)

`llm4cj` 是仓颉的 provider-neutral LLM wire codec 与有界流式传输基础库。它把不可变的初始上下文和有序 transcript 映射到明确的 protocol、dialect、model profile，并把固定响应或增量 SSE 事件还原为统一、可验证的状态。

当前源码版本是 **v0.2.0**，包含一次有意的 breaking cutover。稳定 API 不再暴露 instructions/messages/tools 三个平行请求字段，也不保留 v0.1 的 builder 或兼容转发入口。

本库不管理 API key、endpoint、HTTP client、retry policy、model catalog 或 agent loop。应用负责网络与策略；`llm4cj` 负责 canonical wire semantics、严格编码/解码、时序工具状态、bounded framing 和确定性错误。

## 快速开始

下面的完整程序完全离线。它使用 transcript/profile API 编码请求、解码成功终态并打印文本；HTTP 请求由应用自己的传输层发送。

`cjpm.toml` 依赖示例：

```toml
[dependencies]
llm4cj = { path = "../llm4cj" }
```

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

输出：

```text
你好，仓颉！
```

## 核心契约

- `LlmWireRequest(model, transcript, ...)` 只接受 `LlmWireTranscript`；`LlmWireTranscript` 保存初始 instructions/tools 和按发生顺序排列的 `LlmWireInputItem`。
- `LlmWireTool` 的本地 `name/version/description/inputSchema` 共同形成定义身份；wire 不发送本地 version。`ToolActivation`、`ToolDeactivation` 和 `ToolReplacement` 都要求精确 ref 或显式 provider capability。
- transcript、模型数组、快照和公开 JSON 值都以 defensive copy/canonical representation 暴露。`snapshot()` 与 `restore()` 使用严格的 `llm4cj.transcript` version 1 格式。
- 固定响应和流式终态共享 usage 语义。缺失计数是 `None`，provider 明确返回零才是 `Some(0)`；cache read/write 还保留协议、dialect 和 field-path 来源。
- 无法表达的 provider 语义 fail closed：不会 collapse transcript、静默删除字段、换协议、伪造 tool-search 回合或把截断当成功。

内置 profile/dialect：`openai.responses.v1`、`openai.chat.v1`、`anthropic.messages.v1`、`deepseek.responses.v1`、`deepseek.chat.v1`、`deepseek.messages.v1`、`kimi.chat.v1`。每个 profile 都必须传入 `LlmWireTranscriptCapabilities(endpointProfileId, contractVersion, entries:)`；空 entries 只表示静态 transcript，不表示动态操作已获准。

Responses 的 `additional_tools`、Anthropic 的 system/tool reference 更新和 Kimi 的 tools-only system message 只在绑定的 endpoint/model profile 中开启。Anthropic required headers 由 dialect contract 产生；Kimi 使用独立 Chat contract 和 K3 schema/name grammar。真实 provider/cache 证据不由离线 fixture 冒充。

## 文档

- [安装与首个程序](docs/getting-started.md)
- [协议与 dialect](docs/choosing-a-protocol.md)
- [请求与响应](docs/requests-and-replies.md)
- [流式与传输](docs/streaming-and-transport.md)
- [Tools、thinking 与 structured output](docs/tools-thinking-and-structured-output.md)
- [错误与限制](docs/errors-and-limits.md)
- [从 v0.1 迁移](docs/migrating-from-v0.1.md)
- [API reference](docs/api-reference.md)
- [架构](docs/architecture.md)
- [测试与发布](docs/testing-and-releasing.md)

贡献前运行 `scripts/check.sh`。安全问题请按 [SECURITY.md](SECURITY.md) 私下报告。本项目使用 [Apache-2.0](LICENSE)。
