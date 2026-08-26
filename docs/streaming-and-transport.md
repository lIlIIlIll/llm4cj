# 流式与传输

`llm4cj` 不发送 HTTP 请求。应用读取 response body 后，把受限字节流交给 `readLlmHttpBody`，把 SSE chunk 交给 `SseDecoder`，再把事件 data 交给协议 decoder。

## 完整程序

```cj
package streaming_demo

import llm4cj.*

main(): Int64 {
    let source = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"hi\"}\n\n" +
        "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"r1\",\"status\":\"completed\",\"output\":[],\"usage\":{}}}\n\n"
    let result = decodeLlmWireEventStream(LlmWireProtocol.Responses, source)
    for (event in result.events) {
        if (let LlmWireEventKind.TextDelta <- event.kind) { println(event.text) }
    }
    println(result.terminalSource)
    0
}
```

## 两种 event API

- `decodeLlmWireEventFrame` 是无状态低延迟投影。它不重建最终 reply，也不证明 stream 完整。
- `decodeLlmWireEventStream` 读取完整 SSE 字符串，必须观察到协议终止证据才返回 `LlmWireStreamResult`，并在最后加入 `Completed`。

`MessageTerminalObserved` 只表示 provider 发出了协议终止标记；`Completed` 表示 decoder 已重建并验证可用终态。transport close 不能替代 provider terminal evidence。

## SSE framing

`SseDecoder.push` 可接收任意切片边界并返回零个或多个 `SseEvent`；结束输入后必须调用 `finish`。默认单事件上限 8 MiB，累计缓冲上限 16 MiB。`retry` 字段保存在 event 中，但重试策略属于应用。

`parseRetryAfterMillis` 与 `extractRetryAfterMillis` 只解析整数秒；无效或非正值返回 `0`，溢出饱和到 `Int64.Max`。
