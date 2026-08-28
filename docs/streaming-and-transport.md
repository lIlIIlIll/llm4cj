# 流式与传输

先把网络字节分片送给 `SseDecoder.push`，再把产生的每个 `SseEvent` 送给 `codec.newStreamDecoder().push`。网络 EOF 后调用两个层级各自的 finish 方法：SSE 的 `finish` 丢弃未用空行结束的尾部事件；协议 decoder 的 `finishTransport` 要求已经观察到合法终态。任一 decoder 首次失败后进入 poisoned state，后续调用稳定返回 failed-state 错误。

`LlmWireEvent` 分开保存 `blockIndex`、`outputIndex`、`contentIndex`、`summaryIndex`、`choiceIndex`、`toolCallIndex`、`itemId` 与 `callId`；usage 事件通过 `usage: Option<LlmWireUsage>` 携带可消费的累计值，不使用数值 sentinel。Responses decoder 通过 `response.output_item.added` 建立 `itemId -> callId/name` 映射；后续 argument delta 必须匹配相同 `outputIndex`。OpenAI/DeepSeek 的 reasoning、refusal 与 content-part 事件保留各自索引。Chat 与 Messages 分别按 tool-call index 和 block index 聚合。

SSE parser 接受 CR、LF、CRLF 与首行 BOM，保留空 `data`，并让 `id` 与 `retry` 跨事件生效。`maxEventBytes`、`maxLineBytes`、`maxBufferedBytes`、`maxEventsPerPush` 与 `maxOutputBytesPerPush` 是互相独立的限额；超限属于 `LimitExceeded`。响应体另由 `readLlmHttpBody` 做总量限制。

`codec.newStreamDecoder(limits: LlmWireStreamLimits(...))` 对跨多个小事件累计的语义数据设置总量、文本、reasoning、tool arguments、block、tool call 与事件数上限。首次超限会 poison decoder，后续 feed 不再继续消费。

stream decoder 是同步、单消费者对象，不承诺线程安全，也不创建 callback queue。每次 `push` 完成后才返回，因此 backpressure 由调用方的读取循环自然传递；若 adapter 另建队列，该队列必须自行有界。拥有 HTTP reader 的 adapter 负责在取消、deadline 或 consumer 提前退出时关闭连接，并保证取消后不再调用 decoder。llm4cj 不拥有 socket、连接池或重试生命周期。

Chat 的 `finish_reason` 只结束 choice；usage-only 尾块仍可在 `[DONE]` 前更新 usage。固定和流式 Chat 都只接受单个 index 0 choice。tool call 的 id/name 首次建立后不可变，最终按 tool-call index 排序。Messages 按 message phase、block index 与 native block type 校验 delta；Responses 分开保存 `item_id` 与 `call_id`，并在 arguments done 时协调 name 与完整参数。

Chat 在 id/name 都建立前有界累计 arguments，不会发出空 identity 的 delta；建立 identity 时先发 `ToolCallStarted`，再按原序发缓冲片段。Messages 接受一个或多个 `message_delta`，累计 usage 采用 monotonic merge，非空 stop reason 不得变化，且进入 message-delta phase 后不能再操作 content block。block index 必须从 0 连续递增。

Responses 只发出一次 `StreamStarted`。output item、content/summary part、delta、done 和 terminal 形成显式生命周期；item ID、output/content index、类型、function identity、arguments 与 terminal body 必须一致。legacy Chat `function_call` 不进入成功终态，而是明确返回 `Unsupported`。

usage 的流式值不能被统一求和。`LlmWireDialectContract.usageMergeStyle` 明确选择 present-field replacement、monotonic absolute counters 或 delta accumulation；monotonic 回退、负数和溢出都会失败。固定与流式终态最终都通过同一 canonical assembler，内置六种 dialect 有逐字段等价回归。

`parseRetryAfterMillis` 支持 delta-seconds、IMF-fixdate、RFC 850 和 asctime；多个 `Retry-After` 由 `extractRetryAfterMillis` 选择较大的有效值。

`LlmWireStreamLimits.maxRetainedStateBytes` 约束 ID、model、native payload 和累计语义等 decoder 保留状态。done-only tool arguments 与 terminal-only canonical output 同样计入调用方配置的 semantic limits。SSE `retry` 只接受原始字段值中的 ASCII 数字，不修剪额外空白；RFC850 两位年份相对调用方传入的当前时间应用 50 年规则。
