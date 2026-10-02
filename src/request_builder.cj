package llm4cj

public class LlmWireRequestBuilder {
    private let codec: LlmWireCodec
    private let model: String
    private var transcript = LlmWireTranscript()
    private var thinkingMode = LlmWireThinkingMode.ProviderDefault
    private var reasoningEffort = LlmWireReasoningEffort.ProviderDefault
    private var maxOutputTokens: ?Int64 = None
    private var parallelToolCalls: ?Bool = None
    private var serviceTier = LlmWireServiceTier.ProviderDefault
    private var generationSpeed = LlmWireGenerationSpeed.ProviderDefault
    private var promptCache = LlmWirePromptCache.ProviderDefault
    private var promptCacheRoutingKey: ?String = None
    private var toolChoice = LlmWireToolChoice.ProviderDefault
    private var structuredOutput = LlmWireStructuredOutput.ProviderDefault

    init(codec: LlmWireCodec, model: String) { this.codec = codec; this.model = model }

    public func setInitialContext(context: LlmWireInitialContext): Unit {
        requireNoItems()
        try { validateInitialShape(context) }
        catch (error: LlmWireError) { throw withCodecContext(error, codec, LlmTransportPhase.Encode) }
        transcript = LlmWireTranscript(context)
    }
    public func setTranscript(value: LlmWireTranscript): Unit {
        requireNoItems()
        try { validateInitialShape(value.initialContext) }
        catch (error: LlmWireError) { throw withCodecContext(error, codec, LlmTransportPhase.Encode) }
        let items = value.items
        for (index in 0..items.size) {
            try { validateItemShape(items[index]) }
            catch (error: LlmWireError) { throw withCodecContext(withInputItemContext(error, index), codec, LlmTransportPhase.Encode) }
        }
        transcript = value
    }
    public func append(item: LlmWireInputItem): Unit {
        try { validateItemShape(item) }
        catch (error: LlmWireError) { throw withCodecContext(withInputItemContext(error, transcript.itemCount()), codec, LlmTransportPhase.Encode) }
        transcript = transcript.append(item)
    }
    public func appendMessage(message: LlmWireMessage): Unit { append(LlmWireInputItem.Message(message)) }
    private func requireNoItems(): Unit {
        if (transcript.itemCount() != 0) {
            throw withCodecContext(LlmWireError(LlmWireErrorKind.InvalidState, "llm.initial_context_already_started", "initial context must be assigned before transcript items",
                inputItemIndex: transcript.itemCount()), codec, LlmTransportPhase.Encode)
        }
    }
    private func validateInitialShape(context: LlmWireInitialContext): Unit {
        for (instruction in context.instructions) { validateInstructionShape(instruction) }
        for (declaration in context.tools) { validateDeclarationShape(declaration) }
    }
    private func validateInstructionShape(instruction: LlmWireInstruction): Unit {
        if (instruction.text.trimAscii() == "") {
            throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.instruction_empty", "instruction text must not be empty")
        }
    }
    private func validateDeclarationShape(declaration: LlmWireToolDeclaration): Unit {
        if (!validToolName(declaration.tool.name)) {
            throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.tool_name_invalid", "tool names must use the tool-name grammar", toolName: declaration.tool.name, toolVersion: declaration.version)
        }
        if (declaration.tool.inputSchema.kind != LlmWireJsonKind.Object) {
            throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.tool_schema_invalid", "tool input schema must be a JSON object", toolName: declaration.tool.name, toolVersion: declaration.version)
        }
    }
    private func validateItemShape(item: LlmWireInputItem): Unit {
        match (item) {
            case LlmWireInputItem.Message(message) =>
                if (!messageHasContent(message)) {
                    throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.message_empty", "messages must contain semantic content")
                }
                for (block in message.blocks) { validateBlockShape(block) }
            case LlmWireInputItem.InstructionUpdate(instruction) => validateInstructionShape(instruction)
            case LlmWireInputItem.ToolDeclaration(declaration) => validateDeclarationShape(declaration)
            case _ => ()
        }
    }

    public func setThinking(mode: LlmWireThinkingMode, effort!: LlmWireReasoningEffort = LlmWireReasoningEffort.ProviderDefault): Unit {
        if (let LlmWireThinkingMode.Budget(tokens) <- mode) {
            if (tokens < 1024) { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.thinking_budget_invalid", "thinking budget must be at least 1024 tokens") }
        }
        if (mode == LlmWireThinkingMode.Disabled && effort != LlmWireReasoningEffort.ProviderDefault) {
            throw LlmWireError(LlmWireErrorKind.Unsupported, "llm.reasoning_effort_mode_unsupported", "disabled thinking cannot use a reasoning effort")
        }
        this.thinkingMode = mode; this.reasoningEffort = effort
    }

    public func setMaxOutputTokens(value: ?Int64): Unit {
        match (value) { case Some(tokens) => if (tokens <= 0) { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.max_output_tokens_invalid", "maxOutputTokens must be positive") }; case None => () }
        maxOutputTokens = value
    }

    public func setParallelToolCalls(value: ?Bool): Unit { parallelToolCalls = value }
    public func setServiceTier(value: LlmWireServiceTier): Unit { serviceTier = value }
    public func setGenerationSpeed(value: LlmWireGenerationSpeed): Unit { generationSpeed = value }
    public func setPromptCache(value: LlmWirePromptCache, routingKey!: ?String = None): Unit {
        match (routingKey) { case Some(key) => if (key == "") { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.prompt_cache_routing_key_invalid", "prompt cache routing key must not be empty") }; case None => () }
        promptCache = value; promptCacheRoutingKey = routingKey
    }
    public func setToolChoice(value: LlmWireToolChoice): Unit { toolChoice = value }
    public func setStructuredOutput(value: LlmWireStructuredOutput): Unit { structuredOutput = value }

    public func build(): LlmWireResult<LlmWireRequest> {
        let request = LlmWireRequest(
            model, transcript,
            thinkingMode: thinkingMode, reasoningEffort: reasoningEffort, maxOutputTokens: maxOutputTokens,
            parallelToolCalls: parallelToolCalls, serviceTier: serviceTier, generationSpeed: generationSpeed,
            promptCache: promptCache, promptCacheRoutingKey: promptCacheRoutingKey,
            toolChoice: toolChoice, structuredOutput: structuredOutput
        )
        try { validateWireRequest(codec, request); LlmWireResult.Ok(request) }
        catch (error: LlmWireError) { LlmWireResult.Err(withCodecContext(error, codec, LlmTransportPhase.Encode)) }
    }

    public func reset(): Unit {
        transcript = LlmWireTranscript()
        thinkingMode = LlmWireThinkingMode.ProviderDefault; reasoningEffort = LlmWireReasoningEffort.ProviderDefault
        maxOutputTokens = None; parallelToolCalls = None; serviceTier = LlmWireServiceTier.ProviderDefault
        generationSpeed = LlmWireGenerationSpeed.ProviderDefault; promptCache = LlmWirePromptCache.ProviderDefault
        promptCacheRoutingKey = None; toolChoice = LlmWireToolChoice.ProviderDefault
        structuredOutput = LlmWireStructuredOutput.ProviderDefault
    }
}
