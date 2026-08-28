package llm4cj

import std.collection.*
import yjson.*

class CanonicalReplyAssembler {
    private let responseId: String
    private let model: String
    private let rawStopReason: String
    private let requireExecutableToolCalls: Bool
    private let blocks = ArrayList<LlmWireBlock>()
    private let toolCallIds = HashSet<String>()
    private var usage: LlmWireUsage

    init(responseId: String, model: String, rawStopReason: String, usage!: LlmWireUsage = LlmWireUsage(), requireExecutableToolCalls!: Bool = true) {
        this.responseId = responseId; this.model = model; this.rawStopReason = rawStopReason; this.usage = usage
        this.requireExecutableToolCalls = requireExecutableToolCalls
    }
    func add(block: LlmWireBlock): Unit {
        match (block) {
            case LlmWireBlock.ToolCall(call) =>
                if (requireExecutableToolCalls) {
                    if (call.callId == "") { invalidWire("llm.tool_call_id_missing", "a successful reply contains an empty tool call ID") }
                    if (toolCallIds.contains(call.callId)) { invalidWire("llm.tool_call_id_duplicate", "a successful reply contains duplicate tool call IDs") }
                    if (!validToolName(call.name)) { invalidWire("llm.tool_call_name_invalid", "a successful reply contains an invalid tool name") }
                    match (call.arguments) {
                        case LlmWireToolArguments.Complete(value) =>
                            if (value.wireKind != WireJsonKind.Object) { invalidWire("llm.tool_arguments_shape_invalid", "complete tool arguments must be a JSON object") }
                        case _ => invalidWire("llm.tool_arguments_not_executable", "a successful reply contains tool arguments that are not a complete JSON object")
                    }
                    toolCallIds.add(call.callId)
                }
                blocks.add(block)
            case LlmWireBlock.NativeReplay(value) =>
                if (requireExecutableToolCalls && value.completion != LlmWireOpaqueCompletion.Complete) {
                    invalidWire("llm.native_replay_incomplete", "a successful reply contains incomplete native replay state")
                }
                blocks.add(block)
            case LlmWireBlock.Opaque(_) => throw LlmTransportError(LlmTransportErrorKind.Unsupported, "llm.semantic_block_unsupported", "unknown semantic content cannot enter a canonical reply", phase: Some(LlmTransportPhase.SemanticAssembly))
            case _ => blocks.add(block)
        }
    }
    func addAll(values: Array<LlmWireBlock>): Unit { for (value in values) { add(value) } }
    func finish(): LlmWireReply { LlmWireReply(responseId: responseId, model: model, blocks: blocks.toArray(), usage: usage, rawStopReason: rawStopReason) }
}

func assembleCanonicalReply(
    responseId: String, model: String, blocks: Array<LlmWireBlock>, usage: LlmWireUsage, rawStopReason: String,
    requireExecutableToolCalls!: Bool = true
): LlmWireReply {
    let assembler = CanonicalReplyAssembler(responseId, model, rawStopReason, usage: usage, requireExecutableToolCalls: requireExecutableToolCalls)
    assembler.addAll(blocks)
    assembler.finish()
}

func validateReplyToolStop(reply: LlmWireReply, stop: String, toolStop: String, ordinaryStops: Array<String>): Unit {
    var hasToolCall = false
    for (block in reply.blocks) { match (block) { case LlmWireBlock.ToolCall(_) => hasToolCall = true; case _ => () } }
    if (stop == toolStop && !hasToolCall) { invalidWire("llm.tool_stop_without_call", "provider reported a tool-call stop without a tool call") }
    for (ordinary in ordinaryStops where stop == ordinary && hasToolCall) { invalidWire("llm.tool_call_stop_mismatch", "provider returned a tool call under a non-tool stop reason") }
}

func mergeWireUsage(current: LlmWireUsage, next: LlmWireUsage, style: LlmWireUsageMergeStyle): LlmWireUsage {
    LlmWireUsage(
        inputTokens: mergeUsageValue(current.inputTokens, next.inputTokens, style),
        outputTokens: mergeUsageValue(current.outputTokens, next.outputTokens, style),
        reasoningTokens: mergeUsageValue(current.reasoningTokens, next.reasoningTokens, style),
        cacheReadTokens: mergeUsageValue(current.cacheReadTokens, next.cacheReadTokens, style),
        cacheWriteTokens: mergeUsageValue(current.cacheWriteTokens, next.cacheWriteTokens, style)
    )
}

func mergeUsageValue(current: ?Int64, next: ?Int64, style: LlmWireUsageMergeStyle): ?Int64 {
    match (next) {
        case None => current
        case Some(value) => match (style) {
            case LlmWireUsageMergeStyle.ReplacePresent => Some(value)
            case LlmWireUsageMergeStyle.Monotonic => match (current) {
                case Some(previous) => if (value < previous) { throw LlmTransportError(LlmTransportErrorKind.InvalidWire, "llm.usage_decreased", "monotonic usage counter decreased", phase: Some(LlmTransportPhase.SemanticAssembly)) } else { Some(value) }
                case None => Some(value)
            }
            case LlmWireUsageMergeStyle.Delta => match (current) {
                case Some(previous) => if (value > Int64.Max - previous) { throw LlmTransportError(LlmTransportErrorKind.InvalidWire, "llm.usage_overflow", "usage delta overflowed Int64", phase: Some(LlmTransportPhase.SemanticAssembly)) } else { Some(previous + value) }
                case None => Some(value)
            }
        }
    }
}

func unsupportedSemantic(codec: LlmWireCodec, nativeType: String, payload: JsonNode, code: String, blockIndex!: Int64 = -1, eventType!: String = ""): Nothing {
    let raw = payload.stringify()
    let includeRaw = raw.toArray().size <= 2048
    let diagnostic = wireJsonObject([
        WireJsonField("protocol", wireJsonString(protocolName(codec.protocol))),
        WireJsonField("dialect_id", wireJsonString(codec.dialect.compatibilityId)),
        WireJsonField("native_type", wireJsonString(nativeType)),
        WireJsonField("block_index", wireJsonNumber(blockIndex.toString())),
        WireJsonField("event_type", wireJsonString(eventType)),
        WireJsonField("raw_bytes", wireJsonNumber(raw.toArray().size.toString())),
        WireJsonField("truncated", wireJsonBool(!includeRaw))
    ])
    if (includeRaw) { diagnostic.put("raw_fragment", wireJsonString(raw)) }
    throw LlmTransportError(
        LlmTransportErrorKind.Unsupported, code, "provider content is valid but cannot be represented safely",
        provider: codec.provider, diagnosticJson: Some(diagnostic.stringify()), phase: Some(LlmTransportPhase.SemanticAssembly),
        protocol: Some(codec.protocol), dialectId: codec.dialect.compatibilityId, eventType: eventType, blockIndex: blockIndex
    )
}
