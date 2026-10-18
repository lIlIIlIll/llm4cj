package llm4cj

import std.collection.*

// Tool-call stream identities identify a generated call. A definition identity
// instead names one immutable version in the transcript's declared tool pool.
public class LlmWireToolDefinitionIdentity {
    public let name: String
    public let version: String
    public init(name: String, version!: String = "1") {
        this.name = name; this.version = version
    }
}

public class LlmWireToolDeclaration {
    public let tool: LlmWireToolDefinition
    public let version: String
    public let deferred: Bool
    public init(tool: LlmWireTool, version!: String = "1", deferred!: Bool = false) {
        this.tool = LlmWireToolDefinition.Function(tool)
        this.version = version; this.deferred = deferred
    }
    public init(tool: LlmWireToolDefinition, version!: String = "1", deferred!: Bool = false) {
        this.tool = tool
        this.version = version; this.deferred = deferred
    }
    public prop identity: LlmWireToolDefinitionIdentity {
        get() { LlmWireToolDefinitionIdentity(tool.name, version: version) }
    }
}

public class LlmWireInitialContext {
    private let instructionsValue: Array<LlmWireInstruction>
    private let toolsValue: Array<LlmWireToolDeclaration>
    public init(instructions!: Array<LlmWireInstruction> = [], tools!: Array<LlmWireToolDeclaration> = []) {
        this.instructionsValue = copyValues(instructions)
        this.toolsValue = copyValues(tools)
    }
    public prop instructions: Array<LlmWireInstruction> { get() { copyValues(instructionsValue) } }
    public prop tools: Array<LlmWireToolDeclaration> { get() { copyValues(toolsValue) } }
}

public enum LlmWireInputItem {
    Message(LlmWireMessage)
    | InstructionUpdate(LlmWireInstruction)
    | ToolDeclaration(LlmWireToolDeclaration)
    | ToolActivation(LlmWireToolDefinitionIdentity)
    | ToolDeactivation(LlmWireToolDefinitionIdentity)
}

// All mutable containers are copied both at ingress and on observation. The
// backing transcript never lends an array (including a nested message array)
// to its caller. Public JSON values already own canonical immutable strings.
public class LlmWireTranscript {
    public let initialContext: LlmWireInitialContext
    private let itemsValue: Array<LlmWireInputItem>
    private let cacheBreakpointsValue: Array<LlmWireCacheBreakpoint>
    public init(initialContext: LlmWireInitialContext, items!: Array<LlmWireInputItem> = [], cacheBreakpoints!: Array<LlmWireCacheBreakpoint> = []) {
        validateCacheBreakpointStructure(initialContext, items, cacheBreakpoints)
        this.initialContext = LlmWireInitialContext(instructions: initialContext.instructions, tools: initialContext.tools)
        this.itemsValue = copyTranscriptItems(items)
        this.cacheBreakpointsValue = copyValues(cacheBreakpoints)
    }
    public init(items!: Array<LlmWireInputItem> = [], cacheBreakpoints!: Array<LlmWireCacheBreakpoint> = []) {
        validateCacheBreakpointStructure(LlmWireInitialContext(), items, cacheBreakpoints)
        this.initialContext = LlmWireInitialContext()
        this.itemsValue = copyTranscriptItems(items)
        this.cacheBreakpointsValue = copyValues(cacheBreakpoints)
    }
    public prop items: Array<LlmWireInputItem> { get() { copyTranscriptItems(itemsValue) } }
    public prop cacheBreakpoints: Array<LlmWireCacheBreakpoint> { get() { copyValues(cacheBreakpointsValue) } }
    func itemCount(): Int64 { itemsValue.size }
    public prop effectiveTools: Array<LlmWireToolDefinition> { get() { replayTranscript(this).activeTools } }
    public func append(item: LlmWireInputItem): LlmWireTranscript {
        let result = ArrayList<LlmWireInputItem>()
        for (value in itemsValue) { result.add(value) }
        result.add(item)
        LlmWireTranscript(initialContext, items: result.toArray(), cacheBreakpoints: cacheBreakpointsValue)
    }
    public func snapshot(): LlmWireResult<String> {
        try { LlmWireResult.Ok(writeTranscriptSnapshot(this)) }
        catch (error: LlmWireError) { LlmWireResult.Err(error) }
        catch (_: Exception) { LlmWireResult.Err(LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.transcript_snapshot_invalid", "transcript could not be serialized")) }
    }
    public static func restore(snapshot: String): LlmWireResult<LlmWireTranscript> {
        try { LlmWireResult.Ok(decodeTranscriptSnapshot(readTranscriptSnapshot(snapshot))) }
        catch (error: LlmWireError) { LlmWireResult.Err(error) }
        catch (_: Exception) { LlmWireResult.Err(LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.transcript_snapshot_invalid", "transcript snapshot could not be restored")) }
    }
}

func copyTranscriptItems(items: Array<LlmWireInputItem>): Array<LlmWireInputItem> {
    let result = ArrayList<LlmWireInputItem>()
    for (item in items) { result.add(copyTranscriptItem(item)) }
    result.toArray()
}

func copyTranscriptItem(item: LlmWireInputItem): LlmWireInputItem {
    match (item) {
        case LlmWireInputItem.Message(value) => LlmWireInputItem.Message(copyTranscriptMessage(value))
        case _ => item
    }
}

func copyTranscriptText(value: LlmWireTextBlock): LlmWireTextBlock {
    LlmWireTextBlock(value.text, citations: value.citations, annotations: value.annotations,
        logprobs: copyTranscriptLogprobs(value.logprobs), phase: value.phase)
}

func copyTranscriptLogprobs(values: Array<LlmWireTokenLogprob>): Array<LlmWireTokenLogprob> {
    let result = ArrayList<LlmWireTokenLogprob>()
    for (value in values) {
        let candidates = ArrayList<LlmWireTokenLogprobCandidate>()
        for (candidate in value.topLogprobs) {
            candidates.add(LlmWireTokenLogprobCandidate(candidate.token, candidate.logprob, bytes: candidate.bytes))
        }
        result.add(LlmWireTokenLogprob(value.token, value.logprob, bytes: value.bytes, topLogprobs: candidates.toArray()))
    }
    result.toArray()
}

func copyTranscriptMessage(message: LlmWireMessage): LlmWireMessage {
    let blocks = ArrayList<LlmWireBlock>()
    for (block in message.blocks) {
        match (block) {
            case LlmWireBlock.Text(value) => blocks.add(LlmWireBlock.Text(copyTranscriptText(value)))
            case LlmWireBlock.ToolResult(value) =>
                let content = ArrayList<LlmWireToolResultContent>()
                for (part in value.content) {
                    match (part) {
                        case LlmWireToolResultContent.Text(text) => content.add(LlmWireToolResultContent.Text(copyTranscriptText(text)))
                        case LlmWireToolResultContent.Image(image) => content.add(LlmWireToolResultContent.Image(image))
                    }
                }
                blocks.add(LlmWireBlock.ToolResult(LlmWireToolResultBlock(value.callId, content.toArray(), isError: value.isError, kind: value.kind)))
            case LlmWireBlock.Refusal(value) =>
                blocks.add(LlmWireBlock.Refusal(LlmWireRefusalBlock(value.text, category: value.category,
                    explanation: value.explanation, logprobs: copyTranscriptLogprobs(value.logprobs))))
            case _ => blocks.add(block)
        }
    }
    LlmWireMessage(message.role, blocks.toArray(), messageSpans: message.messageSpans)
}
