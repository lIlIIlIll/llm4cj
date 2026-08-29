# 架构

```text
model -> validation -> dialect -> protocol codec -> canonical assembler
                                            ^                 ^
network bytes -> bounded body / SSE -> wire state machine ----+
```

- `model.cj`：统一请求、block、usage 与终态；
- `dialect.cj`：内置 dialect、capabilities 与 codec 入口；
- `validation.cj`：严格字段和会话历史校验；
- `codec.cj`：三种协议的请求与固定响应；
- `stream.cj`：三种协议的增量 wire 状态机；
- `assembler.cj`：固定与流式路径共享的 canonical reply、usage 与 fail-closed 规则；
- `transport.cj`：字节 SSE、Retry-After 与有界 body；
- `json_support.cj`：重复键拒绝、数字字面量保留及 JSON limits。

协议 envelope、provider dialect、model capability 和 agent 语义是四个边界。只有前三者进入本库；agent loop 留在 consumer。Dialect 只能通过经过交叉校验的声明式 contract 描述现有 Responses、Chat Completions 或 Messages 协议族差异，不能替换 JSON/SSE parser、conversation validation、terminal evidence 或 canonical assembler。新协议族必须作为新的核心 codec 加入。
