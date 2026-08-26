# Process streaming responses safely

Use the transport helpers after your HTTP client receives provider data. The
helpers bound memory use and translate SSE or provider failures into
`LlmTransportError`. They do not open a connection, cancel a request, or choose
a retry policy.

## Bound the response body

Pass the response stream, its declared content length when available, and an
application limit to `readLlmHttpBody`. The complete example below reads five
bytes from an in-memory stream and then decodes one fragmented SSE event:

```cangjie
package llm4cj_transport_example

import llm4cj.*
import std.io.*

main(): Int64 {
    let body = ByteBuffer()
    body.write("hello".toArray())
    match (readLlmHttpBody(body, Some(5), 8)) {
        case LlmResult.Ok(bytes) =>
            if (bytes.size != 5) { return 1 }
        case LlmResult.Err(_) => return 1
    }

    let decoder = SseDecoder(maxEventBytes: 1024)
    match (decoder.push("event: delta\ndata: hel")) {
        case LlmResult.Ok(events) =>
            if (events.size != 0) { return 1 }
        case LlmResult.Err(_) => return 1
    }
    match (decoder.push("lo\n\n")) {
        case LlmResult.Ok(events) =>
            if (events.size != 1 || events[0].data != "hello") { return 1 }
        case LlmResult.Err(_) => return 1
    }
    if (decoder.finish().isOk()) { 0 } else { 1 }
}
```

The function rejects a non-positive limit, a declared size above the limit, and
a streamed body that grows past the limit. It returns `BodyLimit` or `Transport`
errors instead of throwing read failures.

## Frame incremental SSE data

Create one `SseDecoder` per response stream. Feed each decoded text chunk to the
same instance, then call `finish` once at end of input. The example above uses a
1,024-byte event limit. The constructor defaults are 8 MiB per event and 16 MiB
of buffered text.

`push` accepts fragmented events and can return several complete events. The
decoder joins repeated `data:` lines with newline characters and ignores SSE
comments. `finish` processes a final event even when the stream omits the last
blank line.

## Decode provider events

Use `decodeLlmWireEventFrame` for one provider JSON event when the application
needs low-latency deltas. Use `decodeLlmWireEventStream` when the complete SSE
text is available and the caller needs terminal reconstruction and validation.

The complete decoder rejects a partial stream when the provider protocol has
not supplied enough terminal evidence. `MessageTerminalObserved` records a
provider terminal marker. `Completed` records that the decoder assembled a
usable terminal reply. Do not treat these events as interchangeable.

## Apply retry metadata

`extractRetryAfterMillis` reads integer `Retry-After` seconds from raw headers.
It returns the largest valid value when the header occurs more than once and
returns `0` when no positive integer is present.

The value is metadata. Your application decides whether an operation is safe to
retry and how the delay interacts with deadlines, cancellation, and retry
budgets.
