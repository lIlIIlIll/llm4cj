package llm4cj_provider_probe

import llm4cj.*
import std.collection.*
import std.convert.*
import std.fs.*

func codecFor(name: String, model!: String = "probe-model"): LlmWireCodec {
    match (name) {
        case "openai-responses" => openAiResponsesCodec(openAiResponsesModelProfile(model))
        case "openai-chat" => openAiChatCodec(openAiChatModelProfile(model))
        case "anthropic-messages" => anthropicMessagesCodec(anthropicMessagesModelProfile(model))
        case "deepseek-responses" => deepSeekResponsesCodec(deepSeekResponsesModelProfile(model))
        case "deepseek-chat" => deepSeekChatCodec(deepSeekChatModelProfile(model))
        case "deepseek-messages" => deepSeekMessagesCodec(deepSeekMessagesModelProfile(model))
        case _ => throw IllegalArgumentException("unknown dialect")
    }
}

func encode(name: String, model: String, streaming: Bool): Int64 {
    let codec = codecFor(name, model: model)
    let request = LlmWireRequest(
        model,
        [LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock("hello"))])],
        maxOutputTokens: Some(256)
    )
    let prepared = codec.encodeRequest(request, streaming: streaming)
    let materialized = match (prepared.materialize()) {
        case LlmWireResult.Ok(value) => value
        case LlmWireResult.Err(_) => return 3
    }
    let body = match (LlmWireJson.parse(String.fromUtf8(materialized.body))) {
        case LlmWireResult.Ok(value) => value
        case LlmWireResult.Err(_) => return 3
    }
    let headers = ArrayList<LlmWireJson>()
    for (header in materialized.headers) {
        let encodedHeader = match (LlmWireJson.object([
            LlmWireJsonField("name", LlmWireJson.string(header.name)),
            LlmWireJsonField("value", LlmWireJson.string(header.value))
        ])) {
            case LlmWireResult.Ok(value) => value
            case LlmWireResult.Err(_) => return 3
        }
        headers.add(encodedHeader)
    }
    let output = match (LlmWireJson.object([
        LlmWireJsonField("body", body),
        LlmWireJsonField("headers", LlmWireJson.array(headers.toArray()))
    ])) {
        case LlmWireResult.Ok(value) => value
        case LlmWireResult.Err(_) => return 3
    }
    println(output.stringify())
    0
}

func decodeStream(name: String, path: String, chunkBytes: Int64): Int64 {
    if (chunkBytes < 1 || chunkBytes > 65536) { return 2 }
    let decoder = codecFor(name).newStreamDecoder(sseLimits: LlmWireSseLimits(
        maxEventBytes: 8388608, maxLineBytes: 1048576, maxBufferedBytes: 16777216,
        maxEventsPerPush: 4096, maxOutputBytesPerPush: 16777216
    ))
    let file = File(path, OpenMode.Read)
    let buffer = Array<Byte>(chunkBytes, repeat: 0)
    while (true) {
        let count = file.read(buffer)
        if (count <= 0) { break }
        let chunk = ArrayList<Byte>()
        for (index in 0..count) { chunk.add(buffer[index]) }
        match (decoder.push(chunk.toArray())) { case LlmWireResult.Ok(_) => (); case LlmWireResult.Err(_) => file.close(); return 4 }
    }
    file.close()
    match (decoder.finish()) {
        case LlmWireResult.Ok(update) => match (update.terminal) {
            case Some(LlmWireTerminal.Completed(_)) => println("ok"); 0
            case Some(LlmWireTerminal.ProviderFailed(_)) | Some(LlmWireTerminal.Cancelled(_)) => 6
            case None => 5
        }
        case LlmWireResult.Err(_) => 5
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
