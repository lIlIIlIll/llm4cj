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

当前 `main` 是 `v0.2.0` 候选源码，尚未发布对应 tag；manifest 要求 Cangjie `>= 1.1.0`。在 tag 发布前，从相邻 checkout 以固定本地路径验证：

```toml
[dependencies]
llm4cj = { path = "../llm4cj" }
```

下面的完整程序完全离线。它从推荐的 Responses dialect 开始，编码请求、解码成功终态并打印文本。

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
    if (!payload.body.contains("demo-model")) { return 1 }

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

输出：

```text
你好，仓颉！
```

## 设计要点

- `LlmWireCodec` 同时绑定 protocol、dialect、capabilities、provider 名称和校验策略，避免只看 envelope 就猜 provider 语义。
- thinking 默认是 `ProviderDefault`，不会主动发送字段；显式能力若未声明或 dialect 无法表达，会直接报错。
- 固定响应和流式响应都区分 `Succeeded`、`Incomplete` 与 `Failed`。
- Messages 的 `thinking`、`redacted_thinking` 及未知原生 block 以 opaque 数据完整保存，只能在同一 dialect 中回放。
- SSE 以字节为输入，支持 CR、LF、CRLF、BOM、空 `data`、持久 `id`/`retry`、完整事件限额和 EOF 丢弃未结束事件。
- tool arguments 区分完整对象、非法 JSON、非法 shape 与流式 partial；严格模式拒绝孤立、重复和未来匹配的 tool result。
- Responses 流维护 `item_id` 到 `call_id`/name 的状态映射；DeepSeek Chat 将 provider-native `reasoning_content` 与同一 assistant message 的 text/tool calls 一起回放。

内置 dialect：`openai.responses.v1`、`openai.chat.v1`、`anthropic.messages.v1`、`deepseek.responses.v1`、`deepseek.chat.v1`、`deepseek.messages.v1`。model 是否真正支持 thinking、tools 或 structured output，仍应由调用方提供 capability。

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
