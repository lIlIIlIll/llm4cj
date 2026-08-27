# 流式与传输

先把网络字节分片送给 `SseDecoder.push`，再把产生的每个 `SseEvent` 送给 `codec.newStreamDecoder().push`。网络 EOF 后调用两个层级各自的 finish 方法：SSE 的 `finish` 丢弃未用空行结束的尾部事件；协议 decoder 的 `finishTransport` 要求已经观察到合法终态。任一 decoder 首次失败后进入 poisoned state，后续调用稳定返回 failed-state 错误。

`LlmWireEvent` 分开保存 `blockIndex`、`outputIndex`、`contentIndex`、`summaryIndex`、`choiceIndex`、`toolCallIndex`、`itemId` 与 `callId`。Responses decoder 通过 `response.output_item.added` 建立 `itemId -> callId/name` 映射；后续 argument delta 必须匹配相同 `outputIndex`。OpenAI/DeepSeek 的 reasoning、refusal 与 content-part 事件保留各自索引。Chat 与 Messages 分别按 tool-call index 和 block index 聚合。

SSE parser 接受 CR、LF、CRLF 与首行 BOM，保留空 `data`，并让 `id` 与 `retry` 跨事件生效。`maxEventBytes`、`maxLineBytes`、`maxBufferedBytes`、`maxEventsPerPush` 与 `maxOutputBytesPerPush` 是互相独立的限额；超限属于 `LimitExceeded`。响应体另由 `readLlmHttpBody` 做总量限制。

`codec.newStreamDecoder(limits: LlmWireStreamLimits(...))` 对跨多个小事件累计的语义数据设置总量、文本、reasoning、tool arguments、block、tool call 与事件数上限。首次超限会 poison decoder，后续 feed 不再继续消费。

Chat 的 `finish_reason` 只结束 choice；usage-only 尾块仍可在 `[DONE]` 前更新 usage。固定和流式 Chat 都只接受单个 index 0 choice。tool call 的 id/name 首次建立后不可变，最终按 tool-call index 排序。Messages 按 message phase、block index 与 native block type 校验 delta；Responses 分开保存 `item_id` 与 `call_id`，并在 arguments done 时协调 name 与完整参数。

`parseRetryAfterMillis` 支持 delta-seconds、IMF-fixdate、RFC 850 和 asctime；多个 `Retry-After` 由 `extractRetryAfterMillis` 选择较大的有效值。
