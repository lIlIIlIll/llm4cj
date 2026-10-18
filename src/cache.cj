package llm4cj

import std.collection.*
import std.deriving.Derive
import yjson.*

@Derive[Equatable]
public enum LlmWireCachePosition {
    InitialTool(Int64)
    | InitialInstruction(Int64)
    | MessageBlock(Int64, Int64)
    | Item(Int64)
}

public class LlmWireCacheBreakpoint {
    public let position: LlmWireCachePosition
    public let lifetime: LlmWirePromptCacheLifetime
    public init(position: LlmWireCachePosition, lifetime!: LlmWirePromptCacheLifetime = LlmWirePromptCacheLifetime.FiveMinutes) {
        let valid = match (position) {
            case LlmWireCachePosition.InitialTool(index) => index >= 0
            case LlmWireCachePosition.InitialInstruction(index) => index >= 0
            case LlmWireCachePosition.Item(index) => index >= 0
            case LlmWireCachePosition.MessageBlock(item, block) => item >= 0 && block >= 0
        }
        if (!valid) { cachePositionError("llm.cache_position_invalid", "cache positions must use nonnegative indices", position) }
        this.position = position; this.lifetime = lifetime
    }
}

func cachePositionError(code: String, message: String, position: LlmWireCachePosition): Nothing {
    let (item, block) = match (position) {
        case LlmWireCachePosition.MessageBlock(item, block) => (item, block)
        case LlmWireCachePosition.Item(item) => (item, -1)
        case _ => (-1, -1)
    }
    throw transcriptError(code, message, item, blockIndex: block)
}

func validateCacheBreakpointStructure(context: LlmWireInitialContext, items: Array<LlmWireInputItem>, values: Array<LlmWireCacheBreakpoint>): Unit {
    if (values.isEmpty()) { return }
    if (values.size > 4) {
        throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.cache_breakpoint_limit", "a transcript can contain at most four explicit cache breakpoints")
    }
    for (index in 0..values.size) {
        let position = values[index].position
        let valid = match (position) {
            case LlmWireCachePosition.InitialTool(value) => value >= 0 && value < context.tools.size
            case LlmWireCachePosition.InitialInstruction(value) => value >= 0 && value < context.instructions.size
            case LlmWireCachePosition.Item(value) => value >= 0 && value < items.size
            case LlmWireCachePosition.MessageBlock(item, block) =>
                if (item < 0 || item >= items.size || block < 0) { false }
                else { match (items[item]) { case LlmWireInputItem.Message(message) => block < message.blocks.size; case _ => false } }
        }
        if (!valid) { cachePositionError("llm.cache_position_invalid", "cache position is outside its original transcript item", position) }
        for (previous in 0..index where values[previous].position == position) {
            cachePositionError("llm.cache_position_duplicate", "an explicit cache position may be declared only once", position)
        }
    }
}

func effectiveCacheLifetime(value: LlmWirePromptCacheLifetime): LlmWirePromptCacheLifetime {
    if (value == LlmWirePromptCacheLifetime.ProviderDefault) { LlmWirePromptCacheLifetime.FiveMinutes } else { value }
}

func explicitCacheControl(value: LlmWirePromptCacheLifetime): JsonNode {
    let result = wireJsonObject([WireJsonField("type", wireJsonString("ephemeral"))])
    if (value != LlmWirePromptCacheLifetime.ProviderDefault) { result.put("ttl", wireJsonString(cacheLifetimeName(value))) }
    result
}

// Validation resolves positions in provider prefix order once. Encoding only
// applies this immutable plan; it never searches for a replacement target.
class ResolvedCachePlan {
    private let values: Array<LlmWireCacheBreakpoint>
    init(values!: Array<LlmWireCacheBreakpoint> = []) { this.values = copyValues(values) }
    func decorate(position: LlmWireCachePosition, node: JsonNode): JsonNode {
        for (value in values where value.position == position) { node.put("cache_control", explicitCacheControl(value.lifetime)) }
        node
    }
}

class CachePlanResolver {
    private let values: Array<LlmWireCacheBreakpoint>
    private let ordered = ArrayList<LlmWireCacheBreakpoint>()
    private var last: ?LlmWireCachePosition = None
    init(values: Array<LlmWireCacheBreakpoint>) { this.values = values }
    func observe(position: LlmWireCachePosition, eligible: Bool): Unit {
        if (eligible) { last = Some(position) }
        for (value in values where value.position == position) {
            if (!eligible) { cachePositionError("llm.cache_target_invalid", "cache position does not identify an eligible emitted block", position) }
            ordered.add(value)
        }
    }
    func finish(automatic: ?LlmWirePromptCacheLifetime): Unit {
        var shortSeen = false
        for (value in ordered) {
            let lifetime = effectiveCacheLifetime(value.lifetime)
            if (lifetime == LlmWirePromptCacheLifetime.FiveMinutes) { shortSeen = true }
            else if (shortSeen) { cachePositionError("llm.cache_ttl_order_invalid", "one-hour cache breakpoints must precede five-minute breakpoints", value.position) }
        }
        match ((automatic, last)) {
            case (Some(lifetime), Some(position)) =>
                for (value in values where value.position == position) {
                    if (effectiveCacheLifetime(value.lifetime) != effectiveCacheLifetime(lifetime)) {
                        cachePositionError("llm.cache_ttl_conflict", "automatic and explicit cache TTLs conflict at the final eligible block", position)
                    }
                    return
                }
                if (shortSeen && effectiveCacheLifetime(lifetime) == LlmWirePromptCacheLifetime.OneHour) {
                    cachePositionError("llm.cache_ttl_order_invalid", "automatic one-hour cache cannot follow a five-minute breakpoint", position)
                }
            case _ => ()
        }
    }
}

func resolveCachePlan(codec: LlmWireCodec, request: LlmWireRequest): ResolvedCachePlan {
    let values = request.transcript.cacheBreakpoints
    if (values.isEmpty()) { return ResolvedCachePlan() }
    if (codec.dialect.compatibilityId != "anthropic.messages.v1" || codec.dialect.contract.promptCacheStyle != LlmWirePromptCacheStyle.Anthropic || !codec.capabilities.cache.explicitBreakpoints) {
        unsupportedRequest("llm.cache_explicit_unsupported", "explicit cache breakpoints require the built-in Anthropic contract and model capability")
    }
    let automatic: ?LlmWirePromptCacheLifetime = match (request.promptCache) { case LlmWirePromptCache.Automatic(lifetime) => Some(lifetime); case _ => None }
    // Automatic caching reserves a slot even when its final placement is a no-op.
    if (automatic.isSome() && values.size > 3) {
        throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.cache_breakpoint_limit", "automatic caching leaves at most three explicit breakpoint slots")
    }
    for (value in values) {
        let lifetime = value.lifetime
        var contract = false; for (candidate in codec.dialect.contract.promptCacheLifetimes where candidate == lifetime) { contract = true }
        var capability = false; for (candidate in codec.capabilities.cache.lifetimes where candidate == lifetime) { capability = true }
        if (!contract || !capability || (effectiveCacheLifetime(lifetime) != LlmWirePromptCacheLifetime.FiveMinutes && lifetime != LlmWirePromptCacheLifetime.OneHour)) {
            unsupportedRequest("llm.cache_lifetime_unsupported", "explicit cache TTL is not supported by this dialect and model")
        }
    }
    let resolver = CachePlanResolver(values)
    let context = request.transcript.initialContext
    let tools = context.tools; let seen = HashSet<String>()
    for (index in 0..tools.size) {
        let tool = tools[index]
        let emitted = seen.add(tool.tool.name)
        resolver.observe(LlmWireCachePosition.InitialTool(index), emitted && !tool.deferred && tool.tool.kind == LlmWireToolKind.Function)
    }
    let instructions = context.instructions
    for (index in 0..instructions.size) {
        resolver.observe(LlmWireCachePosition.InitialInstruction(index), instructions[index].role == LlmWireInstructionRole.System && instructions[index].text != "")
    }
    let items = request.transcript.items
    for (index in 0..items.size) { match (items[index]) {
        case LlmWireInputItem.Message(message) =>
            resolver.observe(LlmWireCachePosition.Item(index), false)
            for (block in 0..message.blocks.size) {
                let eligible = match (message.blocks[block]) {
                    case LlmWireBlock.Text(text) => text.text != ""
                    case LlmWireBlock.Image(_) => message.role == LlmWireRole.User
                    case LlmWireBlock.ToolCall(_) | LlmWireBlock.ToolResult(_) => true
                    case _ => false
                }
                resolver.observe(LlmWireCachePosition.MessageBlock(index, block), eligible)
            }
        case LlmWireInputItem.InstructionUpdate(_) | LlmWireInputItem.ToolActivation(_) | LlmWireInputItem.ToolDeactivation(_) =>
            resolver.observe(LlmWireCachePosition.Item(index), true)
        case _ => resolver.observe(LlmWireCachePosition.Item(index), false)
    } }
    resolver.finish(automatic)
    ResolvedCachePlan(values: values)
}

func snapshotCacheBreakpoint(value: LlmWireCacheBreakpoint): JsonNode {
    let position = wireJsonObject([])
    match (value.position) {
        case LlmWireCachePosition.MessageBlock(item, block) =>
            position.put("kind", wireJsonString("message_block"))
            position.put("item_index", wireJsonNumber(item.toString())); position.put("block_index", wireJsonNumber(block.toString()))
        case LlmWireCachePosition.InitialTool(index) => position.put("kind", wireJsonString("initial_tool")); position.put("index", wireJsonNumber(index.toString()))
        case LlmWireCachePosition.InitialInstruction(index) => position.put("kind", wireJsonString("initial_instruction")); position.put("index", wireJsonNumber(index.toString()))
        case LlmWireCachePosition.Item(index) => position.put("kind", wireJsonString("item")); position.put("index", wireJsonNumber(index.toString()))
    }
    let lifetime = if (value.lifetime == LlmWirePromptCacheLifetime.ProviderDefault) { "provider_default" } else { cacheLifetimeName(value.lifetime) }
    wireJsonObject([WireJsonField("position", position), WireJsonField("lifetime", wireJsonString(lifetime))])
}

func restoreCacheBreakpoint(value: JsonNode): LlmWireCacheBreakpoint {
    snapshotFields(value, ["position", "lifetime"])
    let position = wireObject(wireRequiredField(value, "position"), "cache position")
    let kind = wireRequiredString(position, "kind")
    snapshotFields(position, if (kind == "message_block") { ["kind", "item_index", "block_index"] } else { ["kind", "index"] })
    let target = match (kind) {
        case "initial_tool" => LlmWireCachePosition.InitialTool(wireRequiredInt(position, "index"))
        case "initial_instruction" => LlmWireCachePosition.InitialInstruction(wireRequiredInt(position, "index"))
        case "message_block" => LlmWireCachePosition.MessageBlock(wireRequiredInt(position, "item_index"), wireRequiredInt(position, "block_index"))
        case "item" => LlmWireCachePosition.Item(wireRequiredInt(position, "index"))
        case _ => snapshotInvalid("unknown cache position kind")
    }
    let lifetime = match (wireRequiredString(value, "lifetime")) {
        case "provider_default" => LlmWirePromptCacheLifetime.ProviderDefault
        case "5m" => LlmWirePromptCacheLifetime.FiveMinutes
        case "30m" => LlmWirePromptCacheLifetime.ThirtyMinutes
        case "1h" => LlmWirePromptCacheLifetime.OneHour
        case "24h" => LlmWirePromptCacheLifetime.TwentyFourHours
        case _ => snapshotInvalid("unknown cache lifetime")
    }
    LlmWireCacheBreakpoint(target, lifetime: lifetime)
}
