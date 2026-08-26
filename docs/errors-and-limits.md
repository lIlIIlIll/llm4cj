# 错误与限制

`LlmTransportError` 是统一失败类型。`kind` 给出大类，稳定机器判断应优先使用 `code`；`message` 面向诊断。HTTP/provider adapter 可补充 status、retry-after、provider 与 provider error fields。

## 完整程序

```cj
package error_demo

import llm4cj.*

main(): Int64 {
    try {
        decodeResponsesWireReply("{\"output\":[],\"output\":[]}")
        return 1
    } catch (error: LlmTransportError) {
        println(error.code)
        0
    }
}
```

重复 JSON key 会产生 `llm.json_duplicate_key`。Malformed/invalid reply 分别映射到 `llm.payload_malformed` 与 `llm.payload_invalid`；stream 对应 `llm.stream_payload_malformed` 与 `llm.stream_payload_invalid`。缺少 terminal evidence 使用 `llm.responses_terminal_missing`、`llm.chat_terminal_missing` 或 `llm.messages_terminal_missing`。

## 容量边界

| 边界 | 默认或行为 |
| --- | --- |
| JSON 输入 | 8 MiB UTF-8 bytes |
| JSON 字符串 | 8 MiB UTF-8 bytes |
| JSON nesting | 256 levels |
| SSE event | 8 MiB |
| SSE buffered data | 16 MiB |
| HTTP body | 调用者必须传正数 `maxBytes` |

JSON 保留 number literal 文本并拒绝 duplicate key。`readLlmHttpBody` 会在已声明长度或增量读取超过上限时返回 `llm.body_too_large`。不要为绕过限制而把无限 body 一次性读成字符串。

库不拥有 retry、timeout scheduling 或 cancellation source。`retryable` 是事实字段，不是自动重试指令。
