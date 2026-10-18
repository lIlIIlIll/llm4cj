package llm4cj

func validateCodexEncodingShape(request: LlmWireRequest, streaming: Bool, checks: RequestCheckSink): Unit {
    checks.check("request.streaming", { => if (!streaming) { unsupportedRequest("llm.codex_stream_required", "Codex HTTP requests require streaming: true") } })
    checks.check("output.max_tokens", { => if (request.maxOutputTokens.isSome()) { unsupportedRequest("llm.codex_max_output_tokens_unsupported", "SIWC does not accept max_output_tokens") } })
    var systemSeen = false
    var developerSeen = false
    for (instruction in request.transcript.initialContext.instructions) {
        checks.charge()
        if (instruction.role == LlmWireInstructionRole.System) {
            let invalidOrder = systemSeen || developerSeen
            checks.check("input.instruction_order", { => if (invalidOrder) {
                unsupportedRequest("llm.codex_instruction_order_unsupported", "Codex represents one System instruction preceding all Developer instructions")
            } })
            systemSeen = true
        } else { developerSeen = true }
    }
}

func validateCodexTextReplay(value: LlmWireTextBlock): Unit {
    if (!value.citations.isEmpty() || !value.annotations.isEmpty() || !value.logprobs.isEmpty()) {
        unsupportedRequest("llm.codex_text_metadata_unsupported", "Codex input cannot replay text citations, annotations, or logprobs")
    }
}

func validateKimiToolResultShape(value: LlmWireToolResultBlock): Unit {
    if (value.content.size == 1) { match (value.content[0]) { case LlmWireToolResultContent.Text(_) => return; case _ => () } }
    unsupportedRequest("llm.kimi_tool_result_content_unsupported", "Kimi's verified tool-result contract requires one text content part")
}

func validateEncodingRequestChecks(codec: LlmWireCodec, request: LlmWireRequest, streaming: Bool, checks: RequestCheckSink): Unit {
    validateAudioRequest(codec, request, streaming, checks: checks)
    // The option encoder is itself the representation authority. It only writes
    // bounded scalar options to this private fragment, never a request body.
    checks.check("thinking.representation", { => encodeThinking(codec, wireJsonObject([]), request.thinkingMode, request.reasoningEffort) })
    let codex = codec.dialect.contract.requestStyle == LlmWireRequestStyle.OpenAiCodexResponses
    if (codex) { validateCodexEncodingShape(request, streaming, checks) }
    let items = request.transcript.items
    for (itemIndex in 0..items.size) { checks.charge(); match (items[itemIndex]) {
        case LlmWireInputItem.Message(message) => for (blockIndex in 0..message.blocks.size) { checks.charge(); match (message.blocks[blockIndex]) {
            case LlmWireBlock.Text(value) => if (codex) {
                checks.check("input.text_metadata", { => validateCodexTextReplay(value) }, itemIndex: itemIndex, blockIndex: blockIndex)
            }
            case LlmWireBlock.ToolResult(value) => if (codec.dialect.contract.requestStyle == LlmWireRequestStyle.KimiChat) {
                checks.check("tools.result", { => validateKimiToolResultShape(value) }, itemIndex: itemIndex, blockIndex: blockIndex)
            }
            case _ => ()
        } }
        case _ => ()
    } }
}
