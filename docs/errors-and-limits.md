# 错误与限制

`LlmTransportErrorKind` 区分 `InvalidWire`、`InvalidRequest`、`Unsupported`、`InvalidState`、`Http`、`BodyLimit`、`Sse`、`Cancelled`、`Deadline` 与 `Transport`。wire-valid provider failure 进入 `LlmWireTerminal.Failed(LlmWireFailure)`，不会伪装成 JSON 或传输异常。错误码是稳定诊断键，消息用于人类阅读。

已知字段缺失、类型不符、整数非法或溢出会失败；未知事件类型可忽略以保持前向兼容。这两类行为不可混用。

默认 JSON 与字符串上限是 8 MiB，深度上限是 256。默认 SSE 单事件上限是 8 MiB，buffer 上限是 16 MiB。HTTP body 必须由调用方传入正数上限。达到 deadline 或取消后，应用应停止网络读取；本库不拥有 socket 生命周期。

当前 Beta 只承诺 Linux x64 CI。provider endpoint、鉴权、重试和速率限制策略不在库边界内。
