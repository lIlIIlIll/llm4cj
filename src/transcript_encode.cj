package llm4cj

import std.collection.*
import yjson.*

func initialTranscriptTools(transcript: LlmWireTranscript): Array<LlmWireTool> {
    let seen = HashSet<String>(); let output = ArrayList<LlmWireTool>()
    for (declaration in transcript.initialContext.tools) {
        if (seen.add(declaration.tool.name)) { output.add(declaration.tool) }
    }
    output.toArray()
}

func transcriptDeclaredNames(transcript: LlmWireTranscript): HashSet<String> {
    let names = HashSet<String>()
    for (declaration in transcript.initialContext.tools) { names.add(declaration.tool.name) }
    names
}

func responsesInstruction(instruction: LlmWireInstruction): JsonNode {
    wireJsonObject([
        WireJsonField("role", wireJsonString(instructionRoleName(instruction.role))),
        WireJsonField("content", wireJsonArray([wireJsonObject([WireJsonField("type", wireJsonString("input_text")), WireJsonField("text", wireJsonString(instruction.text))])]))
    ])
}

func encodeResponsesTranscript(transcript: LlmWireTranscript): JsonNode {
    let input = wireJsonArray([]); let seen = transcriptDeclaredNames(transcript)
    for (instruction in transcript.initialContext.instructions) { input.add(responsesInstruction(instruction)) }
    for (item in transcript.items) { match (item) {
        case LlmWireInputItem.Message(message) => appendResponsesMessage(input, message)
        case LlmWireInputItem.InstructionUpdate(instruction) => input.add(responsesInstruction(instruction))
        case LlmWireInputItem.ToolDeclaration(declaration) =>
            if (seen.add(declaration.tool.name)) {
                let encoded = wireJsonObject([WireJsonField("type", wireJsonString("additional_tools")), WireJsonField("role", wireJsonString("developer"))])
                addResponsesTools(encoded, [declaration.tool]); input.add(encoded)
            }
        case _ => unsupportedRequest("llm.context_update_unsupported", "Responses cannot represent tool visibility changes")
    } }
    input
}

func appendResponsesMessage(input: JsonNode, message: LlmWireMessage): Unit {
    var content = wireJsonArray([])
    for (block in message.blocks) { match (block) {
        case LlmWireBlock.Text(_) | LlmWireBlock.Image(_) => content.add(encodeResponsesContent(block))
        case LlmWireBlock.ToolCall(call) =>
            flushResponsesMessage(input, message.role, content); content = wireJsonArray([])
            input.add(wireJsonObject([WireJsonField("type", wireJsonString("function_call")), WireJsonField("call_id", wireJsonString(call.callId)), WireJsonField("name", wireJsonString(call.name)), WireJsonField("arguments", wireJsonString(toolArgumentsRaw(call.arguments)))]))
        case LlmWireBlock.ToolResult(result) =>
            flushResponsesMessage(input, message.role, content); content = wireJsonArray([])
            input.add(wireJsonObject([WireJsonField("type", wireJsonString("function_call_output")), WireJsonField("call_id", wireJsonString(result.callId)), WireJsonField("output", encodeResponsesToolResult(result))]))
        case LlmWireBlock.NativeReplay(value) =>
            flushResponsesMessage(input, message.role, content); content = wireJsonArray([]); input.add(value.payload())
        case _ => unsupportedRequest("llm.responses_block_unsupported", "display and diagnostic blocks cannot be encoded as request input")
    } }
    flushResponsesMessage(input, message.role, content)
}

func encodeChatTranscript(codec: LlmWireCodec, transcript: LlmWireTranscript): JsonNode {
    let messages = wireJsonArray([]); let seen = transcriptDeclaredNames(transcript)
    for (instruction in transcript.initialContext.instructions) {
        messages.add(wireJsonObject([WireJsonField("role", wireJsonString(instructionRoleName(instruction.role))), WireJsonField("content", wireJsonString(instruction.text))]))
    }
    for (item in transcript.items) { match (item) {
        case LlmWireInputItem.Message(message) => appendChatMessage(codec, messages, message)
        case LlmWireInputItem.InstructionUpdate(instruction) => messages.add(wireJsonObject([WireJsonField("role", wireJsonString(instructionRoleName(instruction.role))), WireJsonField("content", wireJsonString(instruction.text))]))
        case LlmWireInputItem.ToolDeclaration(declaration) =>
            if (seen.add(declaration.tool.name)) {
                // The absence of content is part of the Kimi native contract.
                let encoded = wireJsonObject([WireJsonField("role", wireJsonString("system"))]); addChatTools(encoded, [declaration.tool]); messages.add(encoded)
            }
        case _ => unsupportedRequest("llm.context_update_unsupported", "Chat dialect cannot represent tool visibility changes")
    } }
    messages
}

func appendChatMessage(codec: LlmWireCodec, messages: JsonNode, message: LlmWireMessage): Unit {
    let content = StringBuilder(); let contentParts = wireJsonArray([]); let calls = wireJsonArray([])
    var hasImage = false; var reasoningContent: ?String = None
    for (block in message.blocks) { match (block) {
        case LlmWireBlock.Text(value) => content.append(value.text); contentParts.add(wireJsonObject([WireJsonField("type", wireJsonString("text")), WireJsonField("text", wireJsonString(value.text))]))
        case LlmWireBlock.ToolResult(result) => messages.add(wireJsonObject([WireJsonField("role", wireJsonString("tool")), WireJsonField("tool_call_id", wireJsonString(result.callId)), WireJsonField("content", if (codec.dialect.contract.requestStyle == LlmWireRequestStyle.KimiChat) { encodeKimiToolResult(result) } else { encodeChatToolResult(codec, result) })]))
        case LlmWireBlock.ToolCall(call) => calls.add(wireJsonObject([WireJsonField("id", wireJsonString(call.callId)), WireJsonField("type", wireJsonString("function")), WireJsonField("function", wireJsonObject([WireJsonField("name", wireJsonString(call.name)), WireJsonField("arguments", wireJsonString(toolArgumentsRaw(call.arguments)))]))]))
        case LlmWireBlock.NativeReplay(value) =>
            if (!chatHasReplayReasoning(codec) || value.nativeType != "reasoning_content") { unsupportedRequest("llm.chat_opaque_unsupported", "Chat Completions cannot replay this native block") }
            reasoningContent = Some(wireRequiredString(value.payload(), "reasoning_content", provider: codec.provider))
        case LlmWireBlock.Opaque(_) => unsupportedRequest("llm.chat_opaque_unsupported", "Chat Completions cannot replay diagnostic blocks")
        case LlmWireBlock.Reasoning(_) | LlmWireBlock.Refusal(_) => unsupportedRequest("llm.chat_block_unsupported", "display-only blocks cannot be encoded as request input")
        case LlmWireBlock.Image(value) => hasImage = true; contentParts.add(encodeChatImage(codec, value))
    } }
    let text = content.toString()
    if (text != "" || hasImage || !calls.items.isEmpty() || reasoningContent.isSome()) {
        let encoded = wireJsonObject([WireJsonField("role", wireJsonString(roleName(message.role))), WireJsonField("content", if (hasImage) { contentParts } else { wireJsonString(text) })])
        match (reasoningContent) { case Some(value) => encoded.put("reasoning_content", wireJsonString(value)); case None => () }
        if (!calls.items.isEmpty()) { encoded.put("tool_calls", calls) }
        messages.add(encoded)
    }
}

func chatHasReplayReasoning(codec: LlmWireCodec): Bool {
    codec.dialect.contract.requestStyle == LlmWireRequestStyle.DeepSeekChat || codec.dialect.contract.requestStyle == LlmWireRequestStyle.KimiChat
}

func encodeKimiToolResult(result: LlmWireToolResultBlock): JsonNode {
    if (result.content.size == 1) { match (result.content[0]) {
        case LlmWireToolResultContent.Text(value) => return wireJsonString(value.text)
        case _ => ()
    } }
    unsupportedRequest("llm.kimi_tool_result_content_unsupported", "Kimi's verified tool-result contract requires one text content part")
}

func anthropicToolReference(operation: String, identity: LlmWireToolDefinitionIdentity): JsonNode {
    wireJsonObject([WireJsonField("role", wireJsonString("system")), WireJsonField("content", wireJsonArray([
        wireJsonObject([WireJsonField("type", wireJsonString(operation)), WireJsonField("tool", wireJsonObject([
            WireJsonField("type", wireJsonString("tool_reference")), WireJsonField("name", wireJsonString(identity.name))
        ]))])
    ]))])
}

func encodeMessagesTranscript(codec: LlmWireCodec, transcript: LlmWireTranscript, headers: ArrayList<LlmWireHeader>): JsonNode {
    let messages = wireJsonArray([])
    let declaredNames = transcriptDeclaredNames(transcript)
    var needsToolBeta = false
    for (declaration in transcript.initialContext.tools where declaration.deferred) { needsToolBeta = true }
    for (item in transcript.items) { match (item) {
        case LlmWireInputItem.Message(message) =>
            let content = wireJsonArray([]); for (block in message.blocks) { content.add(encodeMessagesContent(codec, block)) }
            messages.add(wireJsonObject([WireJsonField("role", wireJsonString(roleName(message.role))), WireJsonField("content", content)]))
        case LlmWireInputItem.InstructionUpdate(value) => messages.add(wireJsonObject([WireJsonField("role", wireJsonString("system")), WireJsonField("content", wireJsonArray([wireJsonObject([WireJsonField("type", wireJsonString("text")), WireJsonField("text", wireJsonString(value.text))])]))]))
        case LlmWireInputItem.ToolActivation(identity) => needsToolBeta = true; messages.add(anthropicToolReference("tool_addition", identity))
        case LlmWireInputItem.ToolDeactivation(identity) => needsToolBeta = true; messages.add(anthropicToolReference("tool_removal", identity))
        case LlmWireInputItem.ToolDeclaration(value) =>
            if (declaredNames.add(value.tool.name)) { unsupportedRequest("llm.context_update_unsupported", "Messages reference contract cannot declare a new tool schema mid-conversation") }
    } }
    if (needsToolBeta) { for (header in codec.dialect.contract.contextUpdates.requiredHeaders) { headers.add(header) } }
    messages
}

func addMessagesInitialTools(root: JsonNode, transcript: LlmWireTranscript): Unit {
    let tools = wireJsonArray([]); let seen = HashSet<String>()
    for (declaration in transcript.initialContext.tools) {
        if (!seen.add(declaration.tool.name)) { continue }
        let tool = declaration.tool
        let value = wireJsonObject([WireJsonField("name", wireJsonString(tool.name)), WireJsonField("description", wireJsonString(tool.description)), WireJsonField("input_schema", tool.inputSchema.jsonNode())])
        if (declaration.deferred) { value.put("defer_loading", wireJsonBool(true)) }
        tools.add(value)
    }
    if (!tools.items.isEmpty()) { root.put("tools", tools) }
}
