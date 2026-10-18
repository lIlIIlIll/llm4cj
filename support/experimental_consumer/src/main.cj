package llm4cj_experimental_consumer

import llm4cj.*
import std.convert.*

main(): Int64 {
    let grammar = LlmWireGrammar(LlmWireGrammarSyntax.Regex, "[a-z]+")
    let tool = LlmWireCustomTool(
        "emit_word",
        format: LlmWireCustomToolFormat.Grammar(grammar)
    )
    if (tool.name != "emit_word" || grammar.definition != "[a-z]+") { return 1 }
    let formats = [LlmWireCustomToolFormatKind.Text, LlmWireCustomToolFormatKind.Regex]
    let codec = openAiResponsesCodec(openAiResponsesModelProfile("demo-model", capabilities: LlmWireCapabilities(
        tools: LlmWireToolCapabilities(enabled: true, customFormats: formats))))
    let transcript = LlmWireTranscript(LlmWireInitialContext(tools: [LlmWireToolDeclaration(LlmWireToolDefinition.Custom(tool))]), items: [
        LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock("emit a word"))]))
    ])
    let body = match (codec.encodeRequest(LlmWireRequest("demo-model", transcript)).materialize()) {
        case LlmWireResult.Ok(value) => String.fromUtf8(value.body)
        case LlmWireResult.Err(_) => return 1
    }
    if (!body.contains("\"type\":\"custom\"") || !body.contains("\"syntax\":\"regex\"")) { return 1 }
    let snapshot = match (transcript.snapshot()) { case LlmWireResult.Ok(value) => value; case _ => return 1 }
    let restored = match (LlmWireTranscript.restore(snapshot)) { case LlmWireResult.Ok(value) => value; case _ => return 1 }
    if (restored.effectiveTools[0].kind != LlmWireToolKind.Custom) { return 1 }
    0
}
