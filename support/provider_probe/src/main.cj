package llm4cj_provider_probe

import llm4cj.*
import std.collection.*
import std.convert.*

func providerJsonValue<T>(result: LlmWireResult<T>): T {
    match (result) { case LlmWireResult.Ok(value) => value; case LlmWireResult.Err(error) => throw error }
}

func messageItems(messages: Array<LlmWireMessage>): Array<LlmWireInputItem> {
    messages.map({message: LlmWireMessage => LlmWireInputItem.Message(message)})
}

func codecFor(name: String, model!: String = "probe-model", tools!: Bool = false): LlmWireCodec {
    let capabilities = LlmWireCapabilities(tools: LlmWireToolCapabilities(enabled: tools,
        customFormats: if (tools) { [LlmWireCustomToolFormatKind.Text, LlmWireCustomToolFormatKind.Regex, LlmWireCustomToolFormatKind.Lark] } else { [] }))
    match (name) {
        case "openai-responses" => openAiResponsesCodec(openAiResponsesModelProfile(model, capabilities: capabilities))
        case "openai-codex-responses" => openAiCodexResponsesCodec(openAiCodexResponsesModelProfile(model, capabilities: capabilities))
        case "openai-chat" => openAiChatCodec(openAiChatModelProfile(model, capabilities: capabilities))
        case "anthropic-messages" => anthropicMessagesCodec(anthropicMessagesModelProfile(model, capabilities: capabilities))
        case "deepseek-responses" => deepSeekResponsesCodec(deepSeekResponsesModelProfile(model, capabilities: capabilities))
        case "deepseek-chat" => deepSeekChatCodec(deepSeekChatModelProfile(model, capabilities: capabilities))
        case "deepseek-messages" => deepSeekMessagesCodec(deepSeekMessagesModelProfile(model, capabilities: capabilities))
        case "kimi-chat" => kimiChatCodec(kimiChatModelProfile(model, capabilities: capabilities))
        case _ => throw IllegalArgumentException("unknown dialect")
    }
}

func encode(name: String, model: String, streaming: Bool): Int64 {
    let codec = codecFor(name, model: model)
    let request = probeRequest(name, LlmWireTranscript(items: messageItems([userMessage("hello")])), model: model)
    let prepared = codec.encodeRequest(request, streaming: streaming || name == "openai-codex-responses")
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
            LlmWireJsonField("name", providerJsonValue(LlmWireJson.string(header.name))),
            LlmWireJsonField("value", providerJsonValue(LlmWireJson.string(header.value)))
        ])) {
            case LlmWireResult.Ok(value) => value
            case LlmWireResult.Err(_) => return 3
        }
        headers.add(encodedHeader)
    }
    let output = match (LlmWireJson.object([
        LlmWireJsonField("body", body),
        LlmWireJsonField("headers", providerJsonValue(LlmWireJson.array(headers.toArray())))
    ])) {
        case LlmWireResult.Ok(value) => value
        case LlmWireResult.Err(_) => return 3
    }
    println(output.stringify())
    0
}

func decodeStream(name: String, path: String, chunkBytes: Int64): Int64 {
    if (chunkBytes < 1 || chunkBytes > 65536) { return 2 }
    let decoded = decodeSse(codecFor(name), readBytes(path), chunkBytes, false)
    match (decoded.result) {
        case LlmWireResult.Ok(LlmWireTerminal.Completed(_)) => println("ok"); 0
        case LlmWireResult.Ok(_) => 6
        case LlmWireResult.Err(_) => if (decoded.pushFailed) { 4 } else { 5 }
    }
}

func encodeCustomFixture(name: String, formatName: String): Int64 {
    let format = match (formatName) {
        case "text" => LlmWireCustomToolFormat.Text
        case "regex" => LlmWireCustomToolFormat.Grammar(LlmWireGrammar(LlmWireGrammarSyntax.Regex, "[a-z]+"))
        case "lark" => LlmWireCustomToolFormat.Grammar(LlmWireGrammar(LlmWireGrammarSyntax.Lark, "start: \"hello\""))
        case _ => return 2
    }
    let declaration = LlmWireToolDeclaration(LlmWireToolDefinition.Custom(LlmWireCustomTool("emit", description: "Emit text", format: format)))
    let transcript = LlmWireTranscript(LlmWireInitialContext(tools: [declaration]), items: messageItems([userMessage("hello")]))
    let request = probeRequest(name, transcript)
    println(materializedJson(probeValue(inspectionCodecFor(name, tools: true).encodeRequest(request, streaming: name == "openai-codex-responses").materialize())).stringify())
    0
}

main(args: Array<String>): Int64 {
    if (args.size == 2 && args[0] == "check-schema") { return checkSchemaFixture(args[1]) }
    if (args.size == 2 && args[0] == "check-structured") { return checkStructuredFixture(args[1]) }
    if (args.size < 3) { return 2 }
    match (args[0]) {
        case "encode" => encode(args[1], args[2], true)
        case "encode-fixture" => encode(args[1], args[2], false)
        case "encode-custom-fixture" => encodeCustomFixture(args[1], args[2])
        case "decode-stream" => if (args.size == 4) { decodeStream(args[1], args[2], Int64.parse(args[3])) } else { 2 }
        case "decode-websocket" => inspectWebSocket(args[1], args[2], true)
        case "inspect-fixed" => inspectFixed(args[1], args[2])
        case "inspect-stream" | "inspect-cancel" => if (args.size == 4) { inspectStream(args[1], args[2], Int64.parse(args[3]), args[0] == "inspect-cancel") } else { 2 }
        case "inspect-websocket" => inspectWebSocket(args[1], args[2], false)
        case _ => 2
    }
}
