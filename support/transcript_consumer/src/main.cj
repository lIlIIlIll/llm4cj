package llm4cj_transcript_consumer

import llm4cj.*

func json(source: String): LlmWireJson {
    match (LlmWireJson.parse(source)) { case LlmWireResult.Ok(value) => value; case LlmWireResult.Err(error) => throw error }
}
func completed(value: LlmWireTerminal): LlmWireReply {
    match (value) { case LlmWireTerminal.Completed(reply) => reply; case _ => throw IllegalStateException("fixture must complete") }
}
func admitted(reply: LlmWireReply, transcript: LlmWireTranscript, expected: Bool): Unit {
    match (validateReplyToolInputs(reply, transcript)) {
        case LlmWireResult.Ok(_) => if (!expected) { throw IllegalStateException("inactive generated tool accepted") }
        case LlmWireResult.Err(error) => if (expected || error.code != "llm.tool_not_active") { throw error }
    }
}

main(): Int64 {
    let definition = LlmWireToolDeclaration(LlmWireTool("lookup", "fixture tool", json("{}")), version: "1")
    let before = LlmWireTranscript(LlmWireInitialContext(tools: [definition]), items: [
        LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.Assistant, [
            LlmWireBlock.ToolCall(LlmWireToolCallBlock("old", "lookup", LlmWireToolArguments.Complete(json("{}"))))
        ])),
        LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [
            LlmWireBlock.ToolResult(LlmWireToolResultBlock("old", [LlmWireToolResultContent.Text(LlmWireTextBlock("old result"))]))
        ]))
    ])
    let prefix = match (before.forkAt(0)) { case LlmWireResult.Ok(value) => value; case LlmWireResult.Err(error) => throw error }
    let next = LlmWireReply(choices: [LlmWireChoice(7, [LlmWireOutputBlock.ToolCall(LlmWireToolCallBlock("branch", "lookup", LlmWireToolArguments.Complete(json("{}"))))], LlmWireChoiceOutcome.Completed)])
    let waiting = match (prefix.appendContinuation(next, 7)) { case LlmWireResult.Ok(value) => value; case LlmWireResult.Err(error) => throw error }
    let closed = waiting.append(LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.ToolResult(LlmWireToolResultBlock("branch", [LlmWireToolResultContent.Text(LlmWireTextBlock("branch result"))]))])))
    let forked = match (closed.forkAt(2)) { case LlmWireResult.Ok(value) => value; case LlmWireResult.Err(error) => throw error }
    if (before.items.size != 2 || prefix.items.size != 0 || waiting.items.size != 1 || forked.items.size != 2) { return 1 }
    let after = before.append(LlmWireInputItem.ToolDeactivation(LlmWireToolDefinitionIdentity("lookup", version: "1")))
    if (before.effectiveTools.size != 1 || after.effectiveTools.size != 0) { return 1 }
    let endpoint = "https://fixture.invalid/v1/messages"
    let profile = LlmWireEndpointProfile("fixture.messages.removal", "fixture", "anthropic.messages.v1", endpoint, 1,
        LlmWireContextUpdateCapabilities(toolDeactivation: true), "offline fixture", "2026-10-02")
    let codec = anthropicMessagesCodec(anthropicMessagesModelProfile("fixture", endpoint: endpoint,
        capabilities: LlmWireCapabilities(tools: LlmWireToolCapabilities(enabled: true)), endpointProfile: Some(profile)))
    let snapshot = match (after.snapshot()) { case LlmWireResult.Ok(value) => value; case LlmWireResult.Err(error) => throw error }
    let restored = match (LlmWireTranscript.restore(snapshot)) { case LlmWireResult.Ok(value) => value; case LlmWireResult.Err(error) => throw error }
    let materialized = match (codec.encodeRequest(LlmWireRequest("fixture", restored, maxOutputTokens: Some(1024))).materialize()) {
        case LlmWireResult.Ok(value) => value
        case LlmWireResult.Err(error) => throw error
    }
    let body = String.fromUtf8(materialized.body)
    if (!body.contains("old result") || !body.contains("tool_removal")) { return 1 }
    let fixed = "{\"id\":\"new\",\"model\":\"fixture\",\"content\":[{\"type\":\"tool_use\",\"id\":\"new-call\",\"name\":\"lookup\",\"input\":{}}],\"stop_reason\":\"tool_use\",\"usage\":{\"input_tokens\":1,\"output_tokens\":2}}"
    let reply = completed(match (codec.decodeResponse(fixed)) { case LlmWireResponseState.Terminal(value) => value; case _ => throw IllegalStateException("fixed fixture must terminate") })
    admitted(reply, before, true); admitted(reply, restored, false)
    if (reply.usage.cacheReadTokens.isSome() || reply.usage.cacheWriteTokens.isSome()) { return 1 }
    let stream = "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"new\",\"model\":\"fixture\",\"content\":[],\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}}\n\n" +
        "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"new-call\",\"name\":\"lookup\",\"input\":{}}}\n\n" +
        "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}\n\n" +
        "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n" +
        "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":2}}\n\n" +
        "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
    let decoder = codec.newStreamDecoder()
    match (decoder.push(stream.toArray())) { case LlmWireResult.Ok(_) => (); case LlmWireResult.Err(error) => throw error }
    let streamed = match (decoder.finish()) { case LlmWireResult.Ok(value) => completed(value.terminal.getOrThrow()); case LlmWireResult.Err(error) => throw error }
    admitted(streamed, before, true); admitted(streamed, restored, false)
    if (streamed.usage.cacheReadTokens.isSome() || streamed.usage.cacheWriteTokens.isSome()) { return 1 }
    println("transcript consumer contract passed")
    0
}
