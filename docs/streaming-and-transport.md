# 流式与传输

先把网络字节分片送给 `SseDecoder.push`，再把产生的每个 `SseEvent` 送给 `codec.newStreamDecoder().push`。网络 EOF 后调用两个层级各自的 finish 方法：SSE 的 `finish` 丢弃未用空行结束的尾部事件；协议 decoder 的 `finishTransport` 要求已经观察到合法终态。任一 decoder 首次失败后进入 poisoned state，后续调用稳定返回 failed-state 错误。

`LlmWireEvent` 分开保存 `blockIndex`、`outputIndex`、`contentIndex`、`summaryIndex`、`choiceIndex`、`toolCallIndex`、`itemId` 与 `callId`；usage 事件通过 `usage: Option<LlmWireUsage>` 携带可消费的累计值，不使用数值 sentinel。Responses decoder 通过 `response.output_item.added` 建立 `itemId -> callId/name` 映射；后续 argument delta 必须匹配相同 `outputIndex`。OpenAI/DeepSeek 的 reasoning、refusal 与 content-part 事件保留各自索引。Chat 与 Messages 分别按 tool-call index 和 block index 聚合。

SSE parser 接受 CR、LF、CRLF 与首行 BOM，保留空 `data`，并让 `id` 与 `retry` 跨事件生效。`maxEventBytes` 按实际输入字节计数，CRLF 的两个字节都计入；chunk 末尾的 CR 会保留到下一字节或 `finish` 后再确定行终止。`maxEventBytes`、`maxLineBytes`、`maxBufferedBytes`、`maxEventsPerPush` 与 `maxOutputBytesPerPush` 是互相独立的限额；超限属于 `LimitExceeded`。响应体另由 `readLlmHttpBody` 做总量限制。

SSE retained-byte 限额由增量计数维护，不会在每个输入字节上重新遍历全部 `data:` 行。Messages 的 `citations_delta`、streaming refusal details，以及 Responses 的 annotations/logprobs/phase 在 canonical event API 能无损承载前返回 `Unsupported`；固定与流式路径使用相同的 fail-closed 规则。

`codec.newStreamDecoder(limits: LlmWireStreamLimits(...))` 对跨多个小事件累计的语义数据设置总量、文本、reasoning、tool arguments、block、tool call 与输入 provider event 数上限。`maxEvents` 在每次 `push` 时增加，因此 heartbeat、空 choice 或重复 metadata 事件不能绕过 CPU 工作量上限。首次超限会 poison decoder，后续 feed 不再继续消费。

stream decoder 是同步、单消费者对象，不承诺线程安全，也不创建 callback queue。每次 `push` 完成后才返回，因此 backpressure 由调用方的读取循环自然传递；若 adapter 另建队列，该队列必须自行有界。拥有 HTTP reader 的 adapter 负责在取消、deadline 或 consumer 提前退出时关闭连接，并保证取消后不再调用 decoder。llm4cj 不拥有 socket、连接池或重试生命周期。

Chat 的 `finish_reason` 只结束 choice；usage-only 尾块仍可在 `[DONE]` 前更新 usage，只有 `[DONE]` 建立内置 Chat transport terminal。`finish_reason` 后直接 EOF 属于截断。固定和流式 Chat 都只接受单个 index 0 choice。tool call 的 id/name 首次建立后不可变，最终按 tool-call index 排序。Messages 按 message phase、block index 与 native block type 校验 delta；Responses 分开保存 `item_id` 与 `call_id`，并在 arguments done 时协调 name 与完整参数。

Chat 在 id/name 都建立前用一个有界 builder 累计 arguments，不会发出空 identity 的 delta；建立 identity 时先发 `ToolCallStarted`，再发一个合并后的 `ToolArgumentsDelta`，避免按片段批量分配事件。Messages 接受一个或多个 `message_delta`，累计 usage 采用 monotonic merge，非空 stop reason 不得变化，且进入 message-delta phase 后不能再操作 content block。block index 必须从 0 连续递增；streamed `tool_use` 起始 input 必须是空对象，thinking start 中已有的 signature 会进入 replay state。

Responses 只发出一次 `StreamStarted`，重复 `response.created`/`response.in_progress` 会失败。output item、content/summary part、value done、part done、item done 和 terminal 形成显式生命周期；delta 不能出现在 value done 后，value done 不得重复，part done 必须晚于对应 value done。item ID、output/content index、类型、function identity、arguments 与 terminal body 必须一致。legacy Chat `function_call` 不进入成功终态，而是明确返回 `Unsupported`。

Responses 只有 `Succeeded` 强制所有 item、part 与 function arguments 在 terminal 前闭合；`Incomplete` 可以保留 partial tool arguments，`Failed` 不套用成功不变量。非成功 terminal 仍会校验 event/status、response identity，以及 terminal body 中实际提供的 streamed output，避免把 provider 明确失败误报成坏 wire。

usage 的流式值不能被统一求和。`LlmWireDialectContract.usageMergeStyle` 明确选择 present-field replacement、monotonic absolute counters 或 delta accumulation；monotonic 回退、负数和溢出都会失败。固定与流式终态最终都通过同一 canonical assembler，内置六种 dialect 有逐字段等价回归。

`parseRetryAfterMillis` 支持 delta-seconds、IMF-fixdate、RFC 850 和 asctime；多个 `Retry-After` 由 `extractRetryAfterMillis` 选择较大的有效值。RFC850 当前年份使用常数时间 civil-date 换算，任意 `Int64` 时间输入不会触发逐年循环。

`LlmWireStreamLimits.maxRetainedStateBytes` 约束 ID、model、native payload 和累计语义等 decoder 保留状态。done-only tool arguments 与 terminal-only canonical output 同样计入调用方配置的 semantic limits。SSE `retry` 只接受原始字段值中的 ASCII 数字，不修剪额外空白；RFC850 两位年份相对调用方传入的当前时间应用 50 年规则。
