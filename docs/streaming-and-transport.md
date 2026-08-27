# 流式与传输

先把网络字节分片送给 `SseDecoder.push`，再把产生的每个 `SseEvent` 送给 `codec.newStreamDecoder().push`。网络 EOF 后调用两个层级各自的 finish 方法：SSE 的 `finish` 丢弃未用空行结束的尾部事件；协议 decoder 的 `finishTransport` 要求已经观察到合法终态。

`LlmWireEvent` 分开保存 `blockIndex`、`outputIndex`、`choiceIndex`、`toolCallIndex`、`itemId` 与 `callId`，因此并行 tool call 不依赖缺失或混用的 ID。

SSE parser 接受 CR、LF、CRLF 与首行 BOM，保留空 `data`，并让 `id` 与 `retry` 跨事件生效。`maxEventBytes` 限制整个事件块，包括 comment、未知字段、`id` 和 `event`。响应体另由 `readLlmHttpBody` 做总量限制。

`parseRetryAfterMillis` 支持 delta-seconds、IMF-fixdate、RFC 850 和 asctime；多个 `Retry-After` 由 `extractRetryAfterMillis` 选择较大的有效值。
