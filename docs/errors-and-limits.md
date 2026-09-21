# 错误与限制

`LlmWireErrorKind` 区分 InvalidWire、InvalidRequest、Unsupported、InvalidState、Http、BodyLimit、LimitExceeded、Sse、Cancelled、Deadline 与 Transport。wire-valid provider failure 进入 `LlmWireTerminal.ProviderFailed(LlmWireFailure)`，不会伪装成 JSON 或 transport exception。

## Transcript errors

- `llm.tool_reference_invalid`、`llm.tool_reference_unknown`、`llm.tool_state_invalid`：ref 缺失、未知或在当前 active view 中状态不合法。
- `llm.tool_definition_conflict`、`llm.tool_replacement_unsupported`：同名定义改变却没有合法 replacement mapping，或 provider 没有 replacement primitive。
- `llm.context_update_position_invalid`、`llm.context_update_unsupported`：时序位置或 profile capability 不允许更新。
- `llm.transcript_snapshot_invalid`、`llm.transcript_version_unsupported`：snapshot 缺失字段、unknown field/tag 或不支持的 version。
- `llm.transcript_limit_exceeded`：provider-controlled item/block/tool/diagnostic/JSON bytes 超过边界。

## Bounds and diagnostics

默认 JSON/depth/SSE limits 仍按 contract 执行；transcript snapshot v1 额外限制 65,536 items、65,536 message/tool-result blocks、4,096 unique tool definitions 和 2,048-byte diagnostic context。计数在 typed allocation 前完成。diagnostic 不保存 raw schema、prompt、URL、credential 或完整 provider body。

usage counter 使用 Option：None 是 provider 未返回，Some(0) 是明确零。`LlmWireFailure.usage` 保留失败前已观测值；来源字段只包含 protocol、dialect ID 和稳定 field path。

库不会自动 retry、换 model/protocol、删除非法历史、把 partial stream 猜成 success 或把未知 provider semantic block 丢掉。应用负责停止网络读取并管理 socket/deadline。
