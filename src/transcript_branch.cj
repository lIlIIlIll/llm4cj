package llm4cj

import std.collection.*

func forkCacheBreakpoints(values: Array<LlmWireCacheBreakpoint>, itemCount: Int64): Array<LlmWireCacheBreakpoint> {
    let retained = ArrayList<LlmWireCacheBreakpoint>()
    for (value in values) {
        let keep = match (value.position) {
            case LlmWireCachePosition.Item(index) => index < itemCount
            case LlmWireCachePosition.MessageBlock(index, _) => index < itemCount
            case _ => true
        }
        if (keep) { retained.add(value) }
    }
    retained.toArray()
}

func continuationSelectionError(reply: LlmWireReply, code: String, message: String): LlmWireResult<LlmWireTranscript> {
    LlmWireResult.Err(withObservedUsage(LlmWireError(LlmWireErrorKind.InvalidState, code, message), observedWireUsage(reply.usage)))
}

func continuationObservedResult(reply: LlmWireReply, result: LlmWireResult<LlmWireTranscript>): LlmWireResult<LlmWireTranscript> {
    match (result) {
        case LlmWireResult.Err(error) => LlmWireResult.Err(withObservedUsage(error, observedWireUsage(reply.usage)))
        case _ => result
    }
}

func checkedBranchTranscript(transcript: LlmWireTranscript, allowUnresolvedTail!: Bool = false): LlmWireResult<LlmWireTranscript> {
    try {
        validateBranchTranscript(transcript, allowUnresolvedTail: allowUnresolvedTail)
        LlmWireResult.Ok(transcript)
    } catch (error: LlmWireError) { LlmWireResult.Err(error) }
}

// These helpers validate intrinsic data and dependency boundaries. The codec's
// model, protocol, capability, and endpoint checks still run before sending.
func validateBranchTranscript(transcript: LlmWireTranscript, allowUnresolvedTail!: Bool = false): Unit {
    for (instruction in transcript.initialContext.instructions) {
        if (instruction.text.trimAscii() == "") {
            throw transcriptError("llm.instruction_empty", "instruction text must not be empty", -1)
        }
    }
    let items = transcript.items
    for (index in 0..items.size) {
        match (items[index]) {
            case LlmWireInputItem.InstructionUpdate(instruction) =>
                if (instruction.text.trimAscii() == "") {
                    throw transcriptError("llm.instruction_empty", "instruction updates must not be empty", index)
                }
            case LlmWireInputItem.Message(message) =>
                try { validateBranchMessage(message) }
                catch (error: LlmWireError) { throw withInputItemContext(error, index) }
            case _ => ()
        }
    }
    let _ = replayTranscript(transcript, allowUnresolvedTail: allowUnresolvedTail)
}

func validateBranchMessage(message: LlmWireMessage): Unit {
    validateSnapshotAudioMessage(message.role, message.blocks)
    if (!messageHasContent(message)) {
        throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.message_empty", "messages must contain semantic content")
    }
    let spans = message.messageSpans
    validateMessageSpanLayout(spans, message.blocks.size, { index => isResponsesMessageContent(message.blocks[index]) })
    if (!spans.isEmpty() && message.role != LlmWireRole.Assistant) {
        unsupportedRequest("llm.responses_phase_role_unsupported", "assistant message spans cannot be attached to user messages")
    }
    for (span in spans) { for (index in span.blockStart..span.blockStart + span.blockCount) {
        let block = message.blocks[index]
        match (block) {
        case LlmWireBlock.Text(text) =>
            if (text.phase != LlmWireOutputPhase.Unspecified && text.phase != span.phase) {
                throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.responses_phase_mismatch", "text phase conflicts with its assistant message span")
            }
        case _ => ()
    } } }
    for (index in 0..message.blocks.size) {
        let block = message.blocks[index]
        validateBlockShape(block)
        match (block) {
            case LlmWireBlock.NativeReplay(value) =>
                if (message.role != LlmWireRole.Assistant) {
                    throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.native_replay_role_invalid", "native replay state must remain in an assistant turn")
                }
                if (value.completion != LlmWireOpaqueCompletion.Complete) {
                    unsupportedRequest("llm.native_replay_incomplete", "partial native state cannot be replayed")
                }
                if (value.blockOrder != index) {
                    unsupportedRequest("llm.native_replay_order_mismatch", "native state must retain its block order inside the assistant turn")
                }
            case LlmWireBlock.Text(value) =>
                if (value.phase != LlmWireOutputPhase.Unspecified && message.role != LlmWireRole.Assistant) {
                    unsupportedRequest("llm.responses_phase_role_unsupported", "phase belongs to assistant messages")
                }
            case _ => ()
        }
    }
}
