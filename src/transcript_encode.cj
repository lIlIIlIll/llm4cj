package llm4cj

import std.collection.*
import yjson.*

func initialTranscriptTools(transcript: LlmWireTranscript): Array<LlmWireToolDefinition> {
    let seen = HashSet<String>(); let output = ArrayList<LlmWireToolDefinition>()
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

func encodeResponsesTranscript(codec: LlmWireCodec, transcript: LlmWireTranscript): JsonNode {
    let input = wireJsonArray([]); let seen = transcriptDeclaredNames(transcript)
    let codex = codec.dialect.contract.requestStyle == LlmWireRequestStyle.OpenAiCodexResponses
    for (instruction in transcript.initialContext.instructions) {
        if (!codex || instruction.role != LlmWireInstructionRole.System) { input.add(responsesInstruction(instruction)) }
    }
    if (codex && !transcript.initialContext.tools.isEmpty()) {
        let declarations = wireJsonObject([]); addResponsesTools(declarations, initialTranscriptTools(transcript))
        input.add(wireJsonObject([WireJsonField("type", wireJsonString("additional_tools")), WireJsonField("role", wireJsonString("developer")), WireJsonField("tools", declarations["tools"])]))
    }
    for (item in transcript.items) { match (item) {
        case LlmWireInputItem.Message(message) => appendResponsesMessage(codec, input, message)
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

func appendResponsesMessage(codec: LlmWireCodec, input: JsonNode, message: LlmWireMessage): Unit {
    let codex = codec.dialect.contract.requestStyle == LlmWireRequestStyle.OpenAiCodexResponses
    let spans = message.messageSpans
    if (!spans.isEmpty()) {
        var cursor: Int64 = 0
        for (span in spans) {
            for (index in cursor..span.blockStart) { appendResponsesStandalone(input, message.blocks[index]) }
            let content = wireJsonArray([])
            for (index in span.blockStart..span.blockStart + span.blockCount) { content.add(encodeResponsesMessageContent(codec, message.role, message.blocks[index])) }
            flushResponsesMessage(input, message.role, content, phase: span.phase, force: true, includeType: codex)
            cursor = span.blockStart + span.blockCount
        }
        for (index in cursor..message.blocks.size) { appendResponsesStandalone(input, message.blocks[index]) }
        return
    }
    var content = wireJsonArray([])
    var phase = LlmWireOutputPhase.Unspecified
    for (block in message.blocks) {
        if (isResponsesMessageContent(block)) {
            let nextPhase = match (block) { case LlmWireBlock.Text(value) => value.phase; case _ => LlmWireOutputPhase.Unspecified }
            if (!content.items.isEmpty() && nextPhase != phase) { flushResponsesMessage(input, message.role, content, phase: phase, includeType: codex); content = wireJsonArray([]) }
            phase = nextPhase
            content.add(encodeResponsesMessageContent(codec, message.role, block))
        } else {
            flushResponsesMessage(input, message.role, content, phase: phase, includeType: codex); content = wireJsonArray([])
            appendResponsesStandalone(input, block)
        }
    }
    flushResponsesMessage(input, message.role, content, phase: phase, includeType: codex)
}

func isResponsesMessageContent(block: LlmWireBlock): Bool {
    match (block) { case LlmWireBlock.Text(_) | LlmWireBlock.Image(_) | LlmWireBlock.Refusal(_) => true; case _ => false }
}

func encodeResponsesMessageContent(codec: LlmWireCodec, role: LlmWireRole, block: LlmWireBlock): JsonNode {
    if (codec.dialect.contract.requestStyle == LlmWireRequestStyle.OpenAiCodexResponses) { match (block) {
        case LlmWireBlock.Text(value) =>
            if (!value.citations.isEmpty() || !value.annotations.isEmpty() || !value.logprobs.isEmpty()) { unsupportedRequest("llm.codex_text_metadata_unsupported", "Codex input cannot replay text citations, annotations, or logprobs") }
            return wireJsonObject([WireJsonField("type", wireJsonString(if (role == LlmWireRole.Assistant) { "output_text" } else { "input_text" })), WireJsonField("text", wireJsonString(value.text))])
        case _ => ()
    } }
    encodeResponsesContent(block)
}

func appendResponsesStandalone(input: JsonNode, block: LlmWireBlock): Unit {
    match (block) {
        case LlmWireBlock.ToolCall(call) => input.add(wireJsonObject([WireJsonField("type", wireJsonString(if (call.kind == LlmWireToolKind.Custom) { "custom_tool_call" } else { "function_call" })), WireJsonField("call_id", wireJsonString(call.callId)), WireJsonField("name", wireJsonString(call.name)), WireJsonField(if (call.kind == LlmWireToolKind.Custom) { "input" } else { "arguments" }, wireJsonString(toolArgumentsRaw(call.arguments)))]))
        case LlmWireBlock.ToolResult(result) => input.add(wireJsonObject([WireJsonField("type", wireJsonString(if (result.kind == LlmWireToolKind.Custom) { "custom_tool_call_output" } else { "function_call_output" })), WireJsonField("call_id", wireJsonString(result.callId)), WireJsonField("output", encodeResponsesToolResult(result))]))
        case LlmWireBlock.NativeReplay(value) => input.add(value.payload())
        case _ => unsupportedRequest("llm.responses_block_unsupported", "display and diagnostic blocks cannot be encoded as request input")
    }
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
    var hasImage = false; var reasoningContent: ?String = None; var audioReplay: ?LlmWireAssistantAudioReplayBlock = None
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
        case LlmWireBlock.AudioInput(value) => hasImage = true; contentParts.add(wireJsonObject([
            WireJsonField("type", wireJsonString("input_audio")), WireJsonField("input_audio", wireJsonObject([
                WireJsonField("format", wireJsonString(audioFormatName(value.format))), WireJsonField("data", wireJsonString(encodeAudioBase64(value.audioBytes())))
            ]))]))
        case LlmWireBlock.AudioReplay(value) => audioReplay = Some(value)
    } }
    let text = content.toString()
    if (text != "" || hasImage || !calls.items.isEmpty() || reasoningContent.isSome() || audioReplay.isSome()) {
        let encoded = wireJsonObject([WireJsonField("role", wireJsonString(roleName(message.role))), WireJsonField("content", if (hasImage) { contentParts } else { wireJsonString(text) })])
        match (reasoningContent) { case Some(value) => encoded.put("reasoning_content", wireJsonString(value)); case None => () }
        match (audioReplay) { case Some(value) => encoded.put("audio", wireJsonObject([WireJsonField("id", wireJsonString(value.id))])); case None => () }
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

func encodeMessagesTranscript(codec: LlmWireCodec, transcript: LlmWireTranscript, headers: ArrayList<LlmWireHeader>, cachePlan!: ResolvedCachePlan = ResolvedCachePlan()): JsonNode {
    let messages = wireJsonArray([])
    let declaredNames = transcriptDeclaredNames(transcript)
    var needsToolBeta = false
    for (declaration in transcript.initialContext.tools where declaration.deferred) { needsToolBeta = true }
    let items = transcript.items
    for (itemIndex in 0..items.size) { match (items[itemIndex]) {
        case LlmWireInputItem.Message(message) =>
            let content = wireJsonArray([])
            for (index in 0..message.blocks.size) { content.add(cachePlan.decorate(LlmWireCachePosition.MessageBlock(itemIndex, index), encodeMessagesContent(codec, message.blocks[index]))) }
            messages.add(wireJsonObject([WireJsonField("role", wireJsonString(roleName(message.role))), WireJsonField("content", content)]))
        case LlmWireInputItem.InstructionUpdate(value) => messages.add(wireJsonObject([WireJsonField("role", wireJsonString("system")), WireJsonField("content", wireJsonArray([cachePlan.decorate(LlmWireCachePosition.Item(itemIndex), wireJsonObject([WireJsonField("type", wireJsonString("text")), WireJsonField("text", wireJsonString(value.text))]))]))]))
        case LlmWireInputItem.ToolActivation(identity) =>
            needsToolBeta = true
            let message = anthropicToolReference("tool_addition", identity)
            let _ = cachePlan.decorate(LlmWireCachePosition.Item(itemIndex), message["content"].items[0])
            messages.add(message)
        case LlmWireInputItem.ToolDeactivation(identity) =>
            needsToolBeta = true
            let message = anthropicToolReference("tool_removal", identity)
            let _ = cachePlan.decorate(LlmWireCachePosition.Item(itemIndex), message["content"].items[0])
            messages.add(message)
        case LlmWireInputItem.ToolDeclaration(value) =>
            if (declaredNames.add(value.tool.name)) { unsupportedRequest("llm.context_update_unsupported", "Messages reference contract cannot declare a new tool schema mid-conversation") }
    } }
    if (needsToolBeta) { for (header in codec.dialect.contract.contextUpdates.requiredHeaders) { headers.add(header) } }
    messages
}

func addMessagesInitialTools(root: JsonNode, transcript: LlmWireTranscript, cachePlan!: ResolvedCachePlan = ResolvedCachePlan()): Unit {
    let tools = wireJsonArray([]); let seen = HashSet<String>()
    let declarations = transcript.initialContext.tools
    for (index in 0..declarations.size) {
        let declaration = declarations[index]
        if (!seen.add(declaration.tool.name)) { continue }
        let tool = requireFunctionTool(declaration.tool)
        let value = wireJsonObject([WireJsonField("name", wireJsonString(tool.name)), WireJsonField("description", wireJsonString(tool.description)), WireJsonField("input_schema", tool.inputSchema.jsonNode())])
        if (declaration.deferred) { value.put("defer_loading", wireJsonBool(true)) }
        tools.add(cachePlan.decorate(LlmWireCachePosition.InitialTool(index), value))
    }
    if (!tools.items.isEmpty()) { root.put("tools", tools) }
}
