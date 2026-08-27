# 请求与响应

请求由 `LlmWireRequest`、按顺序排列的 `LlmWireMessage` 和封闭的 `LlmWireBlock` 组成。可选 provider 字段默认不发送。

固定响应返回 `LlmWireResponseState`：

- `Pending`：provider 仍处于 queued 或 in-progress；
- `Terminal(Succeeded)`：结构合法且成功完成；
- `Terminal(Incomplete)`：保留可用输出，并给出 token/length 等原因；
- `Terminal(Failed)`：provider 失败、取消或资源失败。

provider 的合法错误响应属于 wire outcome，不会伪装成 JSON 或 transport exception。格式错误、错误字段类型和溢出才抛出 `LlmTransportError`。

tool arguments 不再被压成一个字符串状态：`Complete` 保存对象与原始 JSON，`InvalidJson` 保存非法文本，`InvalidShape` 保存非对象 JSON，`Partial` 只用于尚未完成的流。
