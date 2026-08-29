package llm4cj_protocol_probe

import llm4cj.*
import std.env.*
import std.fs.*
import std.io.*

func codecFor(name: String): LlmWireCodec {
    match (name) {
        case "openai-responses" => LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect(), provider: name)
        case "openai-chat" => LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect(), provider: name)
        case "anthropic-messages" => LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect(), provider: name)
        case "deepseek-responses" => LlmWireCodec(LlmWireProtocol.Responses, deepSeekResponsesDialect(), provider: name)
        case "deepseek-chat" => LlmWireCodec(LlmWireProtocol.ChatCompletions, deepSeekChatDialect(), provider: name)
        case "deepseek-messages" => LlmWireCodec(LlmWireProtocol.Messages, deepSeekMessagesDialect(), provider: name)
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
