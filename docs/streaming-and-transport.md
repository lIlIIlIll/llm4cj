# 流式与传输

把 HTTP body 的任意字节分片直接送给 `codec.newStreamDecoder().push`，网络 EOF 后调用 `finish`。公开 decoder 同时拥有 UTF-8、SSE framing、协议状态机和 canonical assembler；尾 CR 等只能在 EOF 判断的 framing 状态不会被 adapter 丢失。`newHttpStreamDecoder` 还接收 HTTP status、headers 和当前时间，非 2xx body 在有界缓存后统一生成 provider failure。任一层首次失败都会 poison decoder，后续调用稳定返回 `llm.stream_failed`。

`LlmWireEvent` 是带 payload 的封闭 enum。位置由 `LlmWireEventIdentity` 保存可选的 block、output、content、summary、choice 与 tool-call index，不使用数值 sentinel；工具 identity 由 `LlmWireToolIdentity` 绑定位置、call ID 和 name。usage、citation、refusal details、choice completion、provider failure 与 terminal 都有可直接消费的 payload。delta 在 terminal 验证前是 provisional observation；只有 `TerminalObserved(Completed(...))` 中的 canonical reply 是已提交结果。

SSE parser 接受 CR、LF、CRLF 与首行 BOM，保留空 `data`，并让 `id` 与 `retry` 跨事件生效。`maxEventBytes` 按实际输入字节计数，CRLF 的两个字节都计入；chunk 末尾的 CR 会保留到下一字节或 `finish` 后再确定行终止。`maxEventBytes`、`maxLineBytes`、`maxBufferedBytes`、`maxEventsPerPush` 与 `maxOutputBytesPerPush` 是互相独立的限额；超限属于 `LimitExceeded`。响应体另由 `readLlmHttpBody` 做总量限制。

SSE retained-byte 限额由增量计数维护，不会在每个输入字节上重新遍历全部 `data:` 行。Messages 的 `citations_delta` 与 streaming refusal details 会进入 typed event 和最终 canonical reply。Responses terminal body 中的 annotations、logprobs 与 phase 由固定 decoder 类型化，并与已观察到的文本生命周期协调；无法安全表示的新增语义仍返回 `Unsupported`。

`codec.newStreamDecoder(limits: LlmWireStreamLimits(...))` 对跨多个小事件累计的语义数据设置总量、文本、reasoning、tool arguments、block、tool call 与输入 provider event 数上限。`maxEvents` 在每次 `push` 时增加，因此 heartbeat、空 choice 或重复 metadata 事件不能绕过 CPU 工作量上限。首次超限会 poison decoder，后续 feed 不再继续消费。

stream decoder 是同步、单消费者对象，不承诺线程安全，也不创建 callback queue。每次 `push` 完成后才返回，因此 backpressure 由调用方的读取循环自然传递；若 adapter 另建队列，该队列必须自行有界。拥有 HTTP reader 的 adapter 负责在取消、deadline 或 consumer 提前退出时关闭连接，并保证取消后不再调用 decoder。llm4cj 不拥有 socket、连接池或重试生命周期。

Chat 的 `finish_reason` 只结束对应 choice；usage-only 尾块仍可在 `[DONE]` 前更新 usage，只有 `[DONE]` 建立内置 Chat transport terminal。`finish_reason` 后直接 EOF 属于截断。fixed 与 stream 都要求 choice index 从 0 连续递增，并分别保存每个 choice 的 blocks 与 outcome；tool call identity 也按 choice 隔离。Messages 按 message phase、block index 与 native block type 校验 delta；Responses 分开保存 `item_id` 与 `call_id`，并在 arguments done 时协调 name 与完整参数。

Chat 在 id/name 都建立前用一个有界 builder 累计 arguments，不会发出空 identity 的 delta；建立 identity 时先发 `ToolCallStarted`，再发一个合并后的 `ToolArgumentsDelta`，避免按片段批量分配事件。Messages 接受一个或多个 `message_delta`，累计 usage 采用 monotonic merge，非空 stop reason 不得变化，且进入 message-delta phase 后不能再操作 content block。block index 必须从 0 连续递增；streamed `tool_use` 起始 input 必须是空对象，thinking start 中已有的 signature 会进入 replay state。

Responses 只发出一次 `StreamStarted`，重复 `response.created`/`response.in_progress` 会失败。output item、content/summary part、value done、part done、item done 和 terminal 形成显式生命周期；delta 不能出现在 value done 后，value done 不得重复，part done 必须晚于对应 value done。item ID、output/content index、类型、function identity、arguments 与 terminal body 必须一致。legacy Chat `function_call` 不进入成功终态，而是明确返回 `Unsupported`。

Responses 只有 completed choice 强制所有 item、part 与 function arguments 在 terminal 前闭合；`LlmWireChoiceOutcome.Incomplete` 可以保留 partial tool arguments，global `ProviderFailed` 不套用成功不变量。非成功 terminal 仍会校验 event/status、response identity，以及 terminal body 中实际提供的 streamed output，避免把 provider 明确失败误报成坏 wire。global terminal 只有 `Completed`、`ProviderFailed` 和 `Cancelled`；生成截断与拒绝属于 choice outcome。

usage 的流式值不能被统一求和。`LlmWireDialectContract.usageMergeStyle` 明确选择 present-field replacement、monotonic absolute counters 或 delta accumulation；monotonic 回退、负数和溢出都会失败。固定与流式终态最终都通过同一 canonical assembler，内置六种 dialect 有逐字段等价回归。

`parseRetryAfterMillis` 支持 delta-seconds、IMF-fixdate、RFC 850 和 asctime；多个 `Retry-After` 由 `extractRetryAfterMillis` 选择较大的有效值。RFC850 当前年份使用常数时间 civil-date 换算，任意 `Int64` 时间输入不会触发逐年循环。

`LlmWireStreamLimits.maxRetainedStateBytes` 约束 ID、model、native payload 和累计语义等 decoder 保留状态。done-only tool arguments 与 terminal-only canonical output 同样计入调用方配置的 semantic limits。SSE `retry` 只接受原始字段值中的 ASCII 数字，不修剪额外空白；RFC850 两位年份相对调用方传入的当前时间应用 50 年规则。
