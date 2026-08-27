package llm4cj_provider_probe

import llm4cj.*
import std.collection.*
import std.convert.*
import std.fs.*

func codecFor(name: String): LlmWireCodec {
    match (name) {
        case "openai-responses" => LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect())
        case "openai-chat" => LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect())
        case "anthropic-messages" => LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect())
        case "deepseek-responses" => LlmWireCodec(LlmWireProtocol.Responses, deepSeekResponsesDialect())
        case "deepseek-chat" => LlmWireCodec(LlmWireProtocol.ChatCompletions, deepSeekChatDialect())
        case "deepseek-messages" => LlmWireCodec(LlmWireProtocol.Messages, deepSeekMessagesDialect())
        case _ => throw IllegalArgumentException("unknown dialect")
    }
}

func encode(name: String, model: String, streaming: Bool): Int64 {
    let codec = codecFor(name)
    let request = LlmWireRequest(
        model,
        [LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock("hello"))])],
        maxOutputTokens: Some(256),
        streaming: if (streaming) { Some(true) } else { None }
    )
    let encoded = codec.encodeRequest(request)
    if (!encoded.requiredHeaders.isEmpty() || !encoded.featureRequirements.isEmpty()) { return 3 }
    println(encoded.body)
    0
}

func decodeStream(name: String, path: String, chunkBytes: Int64): Int64 {
    if (chunkBytes < 1 || chunkBytes > 65536) { return 2 }
    let framing = SseDecoder(maxEventBytes: 8388608, maxLineBytes: 1048576, maxBufferedBytes: 16777216, maxEventsPerPush: 4096, maxOutputBytesPerPush: 16777216)
    let decoder = codecFor(name).newStreamDecoder()
    let file = File(path, OpenMode.Read)
    let buffer = Array<Byte>(chunkBytes, repeat: 0)
    while (true) {
        let count = file.read(buffer)
        if (count <= 0) { break }
        let chunk = ArrayList<Byte>()
        for (index in 0..count) { chunk.add(buffer[index]) }
        let events = match (framing.push(chunk.toArray())) { case LlmResult.Ok(value) => value; case LlmResult.Err(_) => file.close(); return 4 }
        for (value in events) { let _ = decoder.push(value) }
    }
    file.close()
    match (framing.finish()) { case LlmResult.Ok(_) => (); case LlmResult.Err(_) => return 5 }
    match (decoder.finishTransport()) {
        case LlmWireTerminal.Succeeded(_) | LlmWireTerminal.Incomplete(_, _) => println("ok"); 0
        case LlmWireTerminal.Failed(_) => 6
    }
}

main(args: Array<String>): Int64 {
    if (args.size < 3) { return 2 }
    match (args[0]) {
        case "encode" => encode(args[1], args[2], true)
        case "encode-fixture" => encode(args[1], args[2], false)
        case "decode-stream" => if (args.size == 4) { decodeStream(args[1], args[2], Int64.parse(args[3])) } else { 2 }
        case _ => 2
    }
}
