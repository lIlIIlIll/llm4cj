# 错误与限制

`LlmWireErrorKind` 区分 `InvalidWire`、`InvalidRequest`、`Unsupported`、`InvalidState`、`Http`、`BodyLimit`、`LimitExceeded`、`Sse`、`Cancelled`、`Deadline` 与 `Transport`。wire-valid provider failure 进入 `LlmWireTerminal.ProviderFailed(LlmWireFailure)`，不会伪装成 JSON 或传输异常。错误码是稳定诊断键，消息用于人类阅读。

已知字段缺失、类型不符、整数非法、溢出或非法事件顺序属于 `InvalidWire`。合法 provider 数据若包含库无法安全表示的未知语义 block/event，则属于 `Unsupported`；decoder 不会返回丢失语义的 `Completed`。只有明确标记为不影响回答语义的 metadata 事件可以忽略。

`LlmWireError` 可携带 phase、protocol、dialect ID、HTTP status、provider request ID、event type、block index 和 tool call ID。`LlmWireFailure` 为 provider outcome 保留 HTTP status、`Retry-After`、request ID 和 retryable 标记。未知语义的 diagnostic 只保存结构化上下文；原始片段最多保留 2 KiB，超出时只记录长度和 `truncated=true`。库不会自动复制 Authorization、cookie、完整 prompt、tool result 或完整 provider body。

流式 transport EOF 未产生协议终态时，`llm.stream_terminal_missing` 附带 `diagnosticJson` 证据：顶层 `reason=transport_ended_before_terminal`，Messages 协议另附 `stream` 摘要（`message_start_seen`、`stop_reason_seen`、`open_content_blocks`；tool_use block 含 `tool_call_id`、`name` 与未解析参数字节数）。工具参数不可执行的 wire 错误附带 `toolCallId`。两者共同区分「模型输出坏 JSON」与「流被提前截断」。

`llm.tool_arguments_schema_violation` 表示 wire 合法的 tool arguments 违反声明 schema（`type`/`properties`/`required`/`additionalProperties`/`items`/`enum` 子集），诊断携带 `tool_name`、`schema_path`、`instance_path`、`violation` 与有界 `expected`/`actual`；`llm.tool_schema_unsupported` 表示 schema 使用了验证子集之外的 feature（Strict 模式），不支持的 feature 名随诊断返回。两者与 `llm.tool_arguments_not_executable` 永久分离。

默认 JSON 与字符串上限是 8 MiB，深度上限是 256。默认 SSE 单事件上限是 8 MiB，buffer 与单次 push 输出上限是 16 MiB；CRLF 的两个原始字节都计入事件上限。协议流另由 `LlmWireStreamLimits` 限制累计语义字节、文本、reasoning、tool arguments、block、tool call 和输入 provider event 数量。HTTP body 必须由调用方传入正数上限。达到 deadline 或取消后，应用应停止网络读取；本库不拥有 socket 生命周期。

协议流还通过 `maxRetainedStateBytes` 限制 decoder 实际保留的 metadata、native payload 与累计内容。终态完整 body 或 done-only arguments 不得绕过更小的 text/tool/total semantic limit。

未知 Messages streamed block 采用 start-only diagnostic：首次未知 `content_block_start` 立即返回 `Unsupported`，保留最多 2 KiB 的该 start event，随后 decoder poisoned。库不会继续读取并保存未知 block 的后续 delta，因为那会延迟错误并扩大不可信 retained state。

当前 Beta 只承诺 Linux x64 CI。provider endpoint、鉴权、重试和速率限制策略不在库边界内。public stream decoder 的幂等 `cancel` 建立 `Cancelled` terminal；拥有网络 reader 的 adapter 仍负责关闭连接，并建立 deadline 与 transport failure。decoder 不会把 EOF 猜测成这些结果，也不会把缺少 terminal evidence 的 EOF 判为成功。
