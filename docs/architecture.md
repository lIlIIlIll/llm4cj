# 架构

```text
model -> validation -> dialect -> protocol codec -> canonical assembler
                                            ^                 ^
network bytes -> bounded body / SSE -> wire state machine ----+
```

- `model.cj`：统一请求、block、usage 与终态；
- `transcript`：不可变初始上下文、有序输入项、版本化快照与派生工具视图；
- `dialect.cj`：内置 dialect、capabilities 与 codec 入口；
- `validation.cj`：严格字段和会话历史校验；
- `codec.cj`：三种协议的请求与固定响应；
- `stream.cj`：三种协议的增量 wire 状态机；
- `assembler.cj`：固定与流式路径共享的 canonical reply、usage 与 fail-closed 规则；
- `transport.cj`：字节 SSE、Retry-After 与有界 body；
- `json_support.cj`：重复键拒绝、数字字面量保留及 JSON limits。

协议 envelope、provider dialect、model capability 和 agent 语义是四个边界。只有前三者进入本库；agent loop 留在 consumer。Dialect 只能通过经过交叉校验的声明式 contract 描述现有 Responses、Chat Completions 或 Messages 协议族差异，不能替换 JSON/SSE parser、conversation validation、terminal evidence 或 canonical assembler。新协议族必须作为新的核心 codec 加入。

动态输入另有显式 endpoint 绑定：dialect 的原生更新契约、model capability 与 endpoint profile 必须共同允许操作。transcript 在校验时逐项派生 active tools，encoder 按相同顺序映射原生项；不先折叠成最终工具集合。schema 参数验证、native replay 和错误/usage 通路继续共享原实现。决定见 [ADR 0002](adr/0002-ordered-transcript.md)。
