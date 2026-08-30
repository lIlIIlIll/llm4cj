package llm4cj_protocol_probe

import llm4cj.*
import std.env.*
import std.fs.*
import std.io.*

func codecFor(name: String): LlmWireCodec {
    match (name) {
        case "openai-responses" => openAiResponsesCodec(openAiResponsesModelProfile("probe-model"), provider: name)
        case "openai-chat" => openAiChatCodec(openAiChatModelProfile("probe-model"), provider: name)
        case "anthropic-messages" => anthropicMessagesCodec(anthropicMessagesModelProfile("probe-model"), provider: name)
        case "deepseek-responses" => deepSeekResponsesCodec(deepSeekResponsesModelProfile("probe-model"), provider: name)
        case "deepseek-chat" => deepSeekChatCodec(deepSeekChatModelProfile("probe-model"), provider: name)
        case "deepseek-messages" => deepSeekMessagesCodec(deepSeekMessagesModelProfile("probe-model"), provider: name)
        case _ => throw IllegalArgumentException("unknown dialect: " + name)
    }
}

main(): Int64 {
    let arguments = getCommandLine()
    if (arguments.size != 3) {
        println("usage: llm4cj_protocol_probe <dialect> <response.json>")
        return 2
    }
    let file = File(arguments[2], OpenMode.Read)
    let response = String.fromUtf8(readToEnd(file))
    file.close()
    let decoded = codecFor(arguments[1]).decodeResponse(LlmWireHttpResponse(200, [], response.toArray()))
    match (decoded) {
        case LlmWireResult.Err(error) => println("protocol probe failed: " + error.code); 1
        case LlmWireResult.Ok(LlmWireResponseState.Terminal(LlmWireTerminal.Completed(_))) => println("protocol probe passed: " + arguments[1]); 0
        case LlmWireResult.Ok(LlmWireResponseState.Terminal(LlmWireTerminal.ProviderFailed(failure))) => println("protocol probe received provider failure: " + failure.providerErrorType); 1
        case LlmWireResult.Ok(LlmWireResponseState.Terminal(LlmWireTerminal.Cancelled(_))) => println("protocol probe received cancellation"); 1
        case LlmWireResult.Ok(LlmWireResponseState.Pending(_)) => println("protocol probe received a pending response"); 1
    }
}
