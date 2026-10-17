package llm4cj_builder_benchmark

import llm4cj.*
import std.convert.*
import std.time.*

func emit(stage: String, count: Int64, start: MonoTime): Unit {
    let elapsed = (MonoTime.now() - start).toNanoseconds()
    println("{\"stage\":\"" + stage + "\",\"items\":" + count.toString() + ",\"elapsed_ns\":" + elapsed.toString() + "}")
}

main(args: Array<String>): Int64 {
    if (args.size != 2 || (args[1] != "append" && args[1] != "all")) { return 2 }
    let count = Int64.parse(args[0])
    if (count <= 0) { return 2 }
    let codec = openAiResponsesCodec(openAiResponsesModelProfile("model"))
    let builder = codec.newRequestBuilder()
    let input = LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock("benchmark input"))])
    let appendStart = MonoTime.now()
    for (_ in 0..count) { builder.appendMessage(input) }
    emit("append", count, appendStart)
    if (args[1] == "append") { return 0 }
    let buildStart = MonoTime.now()
    let request = match (builder.build()) {
        case LlmWireResult.Ok(value) => value
        case LlmWireResult.Err(error) => throw error
    }
    emit("build", count, buildStart)
    let encodeStart = MonoTime.now()
    let encoded = codec.encodeRequest(request)
    emit("encode", count, encodeStart)
    let materialized = match (encoded.materialize()) {
        case LlmWireResult.Ok(value) => value
        case LlmWireResult.Err(error) => throw error
    }
    if (request.transcript.items.size != count || materialized.body.isEmpty()) { return 1 }
    0
}
