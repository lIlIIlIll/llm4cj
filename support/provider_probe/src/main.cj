package llm4cj_provider_probe

import llm4cj.*

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

func encode(name: String, model: String): Int64 {
    let codec = codecFor(name)
    let maximum = if (codec.protocol == LlmWireProtocol.Messages) { Some(1024) } else { Some(64) }
    let request = LlmWireRequest(
        model,
        [LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock("Reply with OK."))])],
        maxOutputTokens: maximum,
        streaming: Some(true)
    )
    let encoded = codec.encodeRequest(request)
    if (!encoded.requiredHeaders.isEmpty() || !encoded.featureRequirements.isEmpty()) { return 3 }
    println(encoded.body)
    0
}

func decodeStream(name: String, source: String): Int64 {
    let framing = SseDecoder(maxEventBytes: 8388608, maxLineBytes: 1048576, maxBufferedBytes: 16777216, maxEventsPerPush: 4096)
    let events = match (framing.push(source)) { case LlmResult.Ok(value) => value; case LlmResult.Err(_) => return 4 }
    let decoder = codecFor(name).newStreamDecoder()
    for (value in events) { let _ = decoder.push(value) }
    match (framing.finish()) { case LlmResult.Ok(_) => (); case LlmResult.Err(_) => return 5 }
    match (decoder.finishTransport()) {
        case LlmWireTerminal.Succeeded(_) | LlmWireTerminal.Incomplete(_, _) => println("ok"); 0
        case LlmWireTerminal.Failed(_) => 6
    }
}

main(args: Array<String>): Int64 {
    if (args.size < 3) { return 2 }
    match (args[0]) {
        case "encode" => encode(args[1], args[2])
        case "decode-stream" => decodeStream(args[1], args[2])
        case _ => 2
    }
}
