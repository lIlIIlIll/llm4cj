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
    let argumentEnvelopeBytes: Int64 = 12
    let payloadBytes = if (totalBytes > argumentEnvelopeBytes) { totalBytes - argumentEnvelopeBytes } else { 0 }
    let count = payloadBytes / fragmentBytes
    let start = MonoTime.now()
    pushEvent(decoder, "{\"type\":\"message_start\",\"message\":{\"id\":\"bench\",\"model\":\"claude\"}}")
    pushEvent(decoder, "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"call\",\"name\":\"bench\",\"input\":{}}}")
    pushEvent(decoder, "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"value\\\":\\\"\"}}")
    for (_ in 0..count) {
        pushEvent(decoder, "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"" + fragment + "\"}}")
    }
    pushEvent(decoder, "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"\\\"}\"}}")
    pushEvent(decoder, "{\"type\":\"content_block_stop\",\"index\":0}")
    pushEvent(decoder, "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"}}")
    let terminal = pushEvent(decoder, "{\"type\":\"message_stop\"}")
    match (terminal.terminal) {
        case Some(LlmWireTerminal.Completed(reply)) => if (reply.blocks.size != 1) { throw Exception("benchmark lost tool call") }
        case _ => throw Exception("benchmark did not reach success")
    }
    let elapsed = (MonoTime.now() - start).toNanoseconds()
    println("{\"scenario\":\"" + name + "\",\"fragment_bytes\":" + fragmentBytes.toString() + ",\"total_bytes\":" + totalBytes.toString() + ",\"elapsed_ns\":" + elapsed.toString() + "}")
}

func pushEvent(decoder: LlmWireStreamDecoder, payload: String): LlmWireStreamUpdate {
    match (decoder.push("data: " + payload + "\n\n")) {
        case LlmWireResult.Ok(value) => value
        case LlmWireResult.Err(error) => throw error
    }
}

main(): Int64 {
    benchmark("token-sized", 4, 1048576)
    benchmark("4-kib", 4096, 1048576)
    benchmark("long-tool-call", 4096, 8388608)
    0
}
