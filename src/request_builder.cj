package llm4cj

import std.collection.*

public class LlmWireRequestBuilder {
    private let codec: LlmWireCodec
    private let model: String
    private let instructions = ArrayList<LlmWireInstruction>()
    private let messages = ArrayList<LlmWireMessage>()
    private let tools = ArrayList<LlmWireTool>()
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

    public func addInstruction(role: LlmWireInstructionRole, text: String): Unit {
        if (text.trimAscii() == "") { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.instruction_empty", "instruction text must not be empty") }
        instructions.add(LlmWireInstruction(role, text))
    }

    public func addMessage(message: LlmWireMessage): Unit {
        if (!messageHasContent(message)) { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.message_empty", "messages must contain semantic content") }
        for (block in message.blocks) { validateBlockShape(block) }
        messages.add(message)
    }

    public func addTool(tool: LlmWireTool): Unit {
        if (!validToolName(tool.name)) { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.tool_name_invalid", "tool names must use the tool-name grammar") }
        if (tool.inputSchema.kind != LlmWireJsonKind.Object) { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.tool_schema_invalid", "tool input schema must be a JSON object") }
        tools.add(tool)
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
            model, messages.toArray(), instructions: instructions.toArray(), tools: tools.toArray(),
            thinkingMode: thinkingMode, reasoningEffort: reasoningEffort, maxOutputTokens: maxOutputTokens,
            parallelToolCalls: parallelToolCalls, serviceTier: serviceTier, generationSpeed: generationSpeed,
            promptCache: promptCache, promptCacheRoutingKey: promptCacheRoutingKey,
            toolChoice: toolChoice, structuredOutput: structuredOutput
        )
        try { validateWireRequest(codec, request); LlmWireResult.Ok(request) }
        catch (error: LlmWireError) { LlmWireResult.Err(withCodecContext(error, codec, LlmTransportPhase.Encode)) }
    }

    public func reset(): Unit {
        instructions.clear(); messages.clear(); tools.clear()
        thinkingMode = LlmWireThinkingMode.ProviderDefault; reasoningEffort = LlmWireReasoningEffort.ProviderDefault
        maxOutputTokens = None; parallelToolCalls = None; serviceTier = LlmWireServiceTier.ProviderDefault
        generationSpeed = LlmWireGenerationSpeed.ProviderDefault; promptCache = LlmWirePromptCache.ProviderDefault
        promptCacheRoutingKey = None; toolChoice = LlmWireToolChoice.ProviderDefault
        structuredOutput = LlmWireStructuredOutput.ProviderDefault
    }
}
