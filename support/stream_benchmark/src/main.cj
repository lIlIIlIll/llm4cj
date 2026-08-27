package llm4cj_stream_benchmark

import llm4cj.*
import std.time.*

func repeatedAscii(size: Int64): String {
    let value = StringBuilder()
    for (_ in 0..size) { value.append("a") }
    value.toString()
}

func benchmark(name: String, fragmentBytes: Int64, totalBytes: Int64): Unit {
    let decoder = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect()).newStreamDecoder()
    let fragment = repeatedAscii(fragmentBytes)
    let count = totalBytes / fragmentBytes
    let start = MonoTime.now()
    let _ = decoder.push(SseEvent("message", "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"call\",\"name\":\"bench\"}}", "", None))
    for (_ in 0..count) {
        let _ = decoder.push(SseEvent("message", "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"" + fragment + "\"}}", "", None))
    }
    let _ = decoder.push(SseEvent("message", "{\"type\":\"content_block_stop\",\"index\":0}", "", None))
    let _ = decoder.push(SseEvent("message", "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"}}", "", None))
    let terminal = decoder.push(SseEvent("message", "{\"type\":\"message_stop\"}", "", None))
    match (terminal.terminal) {
        case Some(LlmWireTerminal.Succeeded(reply)) => if (reply.blocks.size != 1) { throw Exception("benchmark lost tool call") }
        case _ => throw Exception("benchmark did not reach success")
    }
    let elapsed = (MonoTime.now() - start).toNanoseconds()
    println("{\"scenario\":\"" + name + "\",\"fragment_bytes\":" + fragmentBytes.toString() + ",\"total_bytes\":" + totalBytes.toString() + ",\"elapsed_ns\":" + elapsed.toString() + "}")
}

main(): Int64 {
    benchmark("token-sized", 4, 1048576)
    benchmark("4-kib", 4096, 1048576)
    benchmark("long-tool-call", 4096, 8388608)
    0
}
