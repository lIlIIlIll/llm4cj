# llm4cj

[![Tests passing](https://github.com/lIlIIlIll/llm4cj/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/lIlIIlIll/llm4cj/actions/workflows/ci.yml)
[![Coverage](https://codecov.io/gh/lIlIIlIll/llm4cj/branch/main/graph/badge.svg)](https://codecov.io/gh/lIlIIlIll/llm4cj)
[![Release](https://img.shields.io/github/v/release/lIlIIlIll/llm4cj)](https://github.com/lIlIIlIll/llm4cj/releases)
[![Cangjie](https://img.shields.io/badge/Cangjie-%3E%3D%201.1.0-f25c2a)](https://cangjie-lang.cn/)
[![License](https://img.shields.io/github/license/lIlIIlIll/llm4cj)](LICENSE)

`llm4cj` 是仓颉的 LLM wire codec 与有界流式传输基础库。它把统一请求映射到明确的协议和 provider dialect，并把固定响应或增量 SSE 事件还原为统一、可验证的状态。

当前成熟度是 **Beta**：适合已经固定 endpoint、dialect、model capability 并拥有回归样本的集成。它不承诺任意 “OpenAI-compatible” 或 “Anthropic-compatible” endpoint 都可直接替换。

本库不管理 API key、endpoint、HTTP client、retry policy、model catalog 或 agent loop。应用负责网络与策略；`llm4cj` 只负责协议边界。

## 快速开始

当前 `main` 是 `v0.1.1` 候选源码，尚未发布对应 tag；manifest 要求 Cangjie `>= 1.1.0`。在 tag 发布前，从相邻 checkout 以固定本地路径验证：

```toml
[dependencies]
llm4cj = { path = "../llm4cj" }
```

下面的完整程序完全离线。它从推荐的 Responses dialect 开始，编码请求、解码成功终态并打印文本。

```cj
package llm4cj_external_consumer

import llm4cj.*
import std.convert.*

main(): Int64 {
    let codec = openAiResponsesCodec(openAiResponsesModelProfile("demo-model"))
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

输出：

```text
你好，仓颉！
```

## 设计要点

- `LlmWireCodec` 同时绑定 protocol、dialect、model capabilities 和 provider 名称；请求始终严格校验，避免只看 envelope 就猜 provider 语义。
- `newRequestBuilder` 复用 codec 与 model profile，字段 setter 立即拒绝局部非法值，`build` 再验证完整请求。system 与 developer instructions 按添加顺序编码；是否启用 streaming 由 `encodeRequest(..., streaming: true)` 决定，不保存在可复用请求中。
- thinking 默认是 `ProviderDefault`，不会主动发送字段；显式能力若未声明或 dialect 无法表达，会直接报错。
- global terminal 区分 `Completed`、`ProviderFailed` 与 `Cancelled`；每个 choice 再区分 completed、incomplete 和 refused，避免把生成截断或拒绝误当成传输失败。
- Messages 的已知 `thinking` 与 `redacted_thinking` 以 dialect-bound native state 完整保存，只能在同一 dialect 中回放；未知语义 block 返回 `Unsupported`，不会伪装成成功结果。
- public stream decoder 直接接收网络字节，统一拥有 UTF-8、SSE framing、协议状态机和 canonical assembler；底层 SSE 支持 CR、LF、CRLF、BOM、空 `data`、持久 `id`/`retry`、完整事件限额和 EOF 丢弃未结束事件。
- tool arguments 区分完整对象、非法 JSON、非法 shape 与流式 partial；只有完整 JSON object 能进入成功终态或 continuation。严格校验还拒绝孤立、重复、未来匹配、不完整批次，以及 pending call 后的普通对话。
- canonical message 不允许为空；工具结果 turn 只能包含完整闭合当前 pending calls 的 ToolResult，不能与普通文本交错。ToolResult content 是有序的 text 或 image 列表。ToolCall name 与工具定义使用同一语法。
- Responses 流维护 `item_id` 到 `call_id`/name 的状态映射；DeepSeek Chat 将 provider-native `reasoning_content` 与同一 assistant message 的 text/tool calls 一起回放。

内置 dialect：`openai.responses.v1`、`openai.chat.v1`、`anthropic.messages.v1`、`deepseek.responses.v1`、`deepseek.chat.v1`、`deepseek.messages.v1`。稳定包只通过六个 model-profile/codec 工厂创建 codec。自定义声明式 dialect、cache pre-warm、custom tool 和 grammar 位于 `llm4cj.experimental`，不享有 v0.1.1 稳定兼容承诺。model 是否真正支持 thinking、tools 或 structured output，仍应由调用方提供 capability。

## 文档

- [安装与首个程序](docs/getting-started.md)
- [实验 API](docs/experimental.md)
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
