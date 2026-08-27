# 架构

```text
model -> validation -> dialect -> codec -> protocol stream state
                                      ^
network bytes -> bounded body / SSE --+
```

- `model.cj`：统一请求、block、usage 与终态；
- `dialect.cj`：内置 dialect、capabilities 与 codec 入口；
- `validation.cj`：严格字段和会话历史校验；
- `codec.cj`：三种协议的请求与固定响应；
- `stream.cj`：三种协议的增量状态机；
- `transport.cj`：字节 SSE、Retry-After 与有界 body；
- `json_support.cj`：重复键拒绝、数字字面量保留及 JSON limits。

协议 envelope、provider dialect、model capability 和 agent 语义是四个边界。只有前三者进入本库；agent loop 留在 consumer。
