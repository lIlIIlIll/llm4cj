# Tools、thinking 与 structured output

## 完整程序

```cj
package advanced_request

import llm4cj.*
import yjson.*

main(): Int64 {
    let schema = YJson.parse("{\"type\":\"object\"}")
    let request = LlmWireRequest(
        "demo",
        [LlmWireMessage(LlmWireRole.User, [LlmWireBlock(LlmWireBlockKind.Text, text: "查天气")])],
        tools: [LlmWireTool("weather", "查询天气", schema)],
        thinking: LlmWireThinkingControl.Effort(LlmWireThinkingLevel.Low),
        toolChoice: LlmWireToolChoice.Auto,
        structuredOutput: Some(LlmWireStructuredOutput("answer", schema))
    )
    println(encodeResponsesWireRequest(request))
    0
}
```

`LlmWireTool` 的 `inputSchema` 和 `LlmWireStructuredOutput.schema` 是 `yjson.JsonNode`。consumer 若直接构造 schema，需要同时声明并导入 `yjson`。

Thinking 支持 `Disabled`、`Toggle`、`Effort`、`Budget` 与 `Adaptive`，但具体协议未必支持每个值。encoder 会拒绝不能安全映射的组合。`LlmWireCachePolicy.StablePrefix`、`serviceTier` 与 `parallelToolCalls` 同样由各协议 encoder 决定是否及如何投影。

Tool result 必须使用原 tool call 的 `callId`。Chat encoder 会忽略找不到对应 call 的孤立 tool result。应用负责执行工具、校验参数和控制副作用。
