package llm4cj

import yjson.*
import std.collection.*
import std.convert.*

public enum LlmWireProtocol { Responses | ChatCompletions | Messages }
public enum LlmWireRole { User | Assistant }
public enum LlmWireBlockKind { Text | Image | Reasoning | ToolCall | ToolResult | Refusal | Error | Unknown }
public enum LlmWireImageSourceKind { Url | Base64 }
public enum LlmWireImageDetail { Auto | Low | High }
public enum LlmWireThinkingLevel { Off | Minimal | Low | Medium | High | XHigh | Max }
public enum LlmWireThinkingControl {
    Disabled
    | Toggle(Bool)
    | Effort(LlmWireThinkingLevel)
    | Budget(Int64)
    | Adaptive(?LlmWireThinkingLevel)
}
public enum LlmWireCachePolicy { Default | StablePrefix }
public enum LlmWireToolChoice { Auto | NoTools | Required }

public class LlmWireImage {
    public let sourceKind: LlmWireImageSourceKind
    public let data: String
    public let mediaType: String
    public let detail: LlmWireImageDetail
    public init(sourceKind: LlmWireImageSourceKind, data: String, mediaType!: String = "", detail!: LlmWireImageDetail = LlmWireImageDetail.Auto) {
        this.sourceKind = sourceKind; this.data = data; this.mediaType = mediaType; this.detail = detail
    }
}

public class LlmWireOpaqueState {
    public let protocol: String
    public let payload: String
    public let itemId: String
    public init(protocol: String, payload: String, itemId!: String = "") {
        this.protocol = protocol; this.payload = payload; this.itemId = itemId
    }
}

public class LlmWireBlock {
    public let kind: LlmWireBlockKind
    public let text: String
    public let callId: String
    public let name: String
    public let arguments: JsonNode
    public let isError: Bool
    public let image: ?LlmWireImage
    public let opaqueState: ?LlmWireOpaqueState
    public init(
        kind: LlmWireBlockKind,
        text!: String = "", callId!: String = "", name!: String = "",
        arguments!: JsonNode = wireJsonObject([]), isError!: Bool = false,
        image!: ?LlmWireImage = None, opaqueState!: ?LlmWireOpaqueState = None
    ) {
        this.kind = kind; this.text = text; this.callId = callId; this.name = name
        this.arguments = arguments; this.isError = isError; this.image = image; this.opaqueState = opaqueState
    }
}

public class LlmWireMessage {
    public let role: LlmWireRole
    public let blocks: Array<LlmWireBlock>
    public init(role: LlmWireRole, blocks: Array<LlmWireBlock>) { this.role = role; this.blocks = blocks }
}

public class LlmWireTool {
    public let name: String
    public let description: String
    public let inputSchema: JsonNode
    public init(name: String, description: String, inputSchema: JsonNode) {
        this.name = name; this.description = description; this.inputSchema = inputSchema
    }
}

public class LlmWireStructuredOutput {
    public let name: String
    public let description: String
    public let schema: JsonNode
    public let strict: Bool
    public init(name: String, schema: JsonNode, description!: String = "", strict!: Bool = true) {
        this.name = name; this.description = description; this.schema = schema; this.strict = strict
    }
}

public class LlmWireRequest {
    public let model: String
    public let system: String
    public let messages: Array<LlmWireMessage>
    public let tools: Array<LlmWireTool>
    public let thinking: LlmWireThinkingControl
    public let maxOutputTokens: Int64
    public let streaming: Bool
    public let parallelToolCalls: Bool
    public let serviceTier: String
    public let cachePolicy: LlmWireCachePolicy
    public let cacheKey: String
    public let toolChoice: LlmWireToolChoice
    public let structuredOutput: ?LlmWireStructuredOutput
    public init(
        model: String, messages: Array<LlmWireMessage>, system!: String = "",
        tools!: Array<LlmWireTool> = [],
        thinking!: LlmWireThinkingControl = LlmWireThinkingControl.Effort(LlmWireThinkingLevel.Medium),
        maxOutputTokens!: Int64 = 2000, streaming!: Bool = false, parallelToolCalls!: Bool = true,
        serviceTier!: String = "", cachePolicy!: LlmWireCachePolicy = LlmWireCachePolicy.Default,
        cacheKey!: String = "", toolChoice!: LlmWireToolChoice = LlmWireToolChoice.Auto,
        structuredOutput!: ?LlmWireStructuredOutput = None
    ) {
        this.model = model; this.messages = messages; this.system = system; this.tools = tools
        this.thinking = thinking; this.maxOutputTokens = maxOutputTokens; this.streaming = streaming
        this.parallelToolCalls = parallelToolCalls; this.serviceTier = serviceTier
        this.cachePolicy = cachePolicy; this.cacheKey = cacheKey; this.toolChoice = toolChoice
        this.structuredOutput = structuredOutput
    }
}

public func encodeLlmWireRequest(protocol: LlmWireProtocol, request: LlmWireRequest): String {
    match (protocol) {
        case LlmWireProtocol.Messages => encodeMessagesWireRequest(request)
        case LlmWireProtocol.Responses => encodeResponsesWireRequest(request)
        case LlmWireProtocol.ChatCompletions => encodeChatCompletionsWireRequest(request)
    }
}

public func encodeMessagesWireRequest(request: LlmWireRequest): String {
    encodeMessagesWireRequestForDialect(request, false)
}

public func encodeDeepSeekMessagesWireRequest(request: LlmWireRequest): String {
    encodeMessagesWireRequestForDialect(request, true)
}

func encodeMessagesWireRequestForDialect(
    request: LlmWireRequest,
    deepSeek: Bool
): String {
    let root = wireJsonObject([])
    root.put("model", wireJsonString(request.model))
    root.put("max_tokens", wireJsonNumber(request.maxOutputTokens.toString()))
    root.put("stream", wireJsonBool(request.streaming))
    if (let LlmWireCachePolicy.StablePrefix <- request.cachePolicy) {
        root.put("cache_control", wireJsonObject([WireJsonField("type", wireJsonString("ephemeral"))]))
    }
    let outputConfig = wireJsonObject([])
    match (request.structuredOutput) {
        case Some(spec) => outputConfig.put("format", wireJsonObject([
            WireJsonField("type", wireJsonString("json_schema")), WireJsonField("schema", spec.schema)
        ]))
        case None => ()
    }
    if (request.serviceTier != "") {
        if (request.serviceTier != "priority") { throw LlmTransportError(LlmTransportErrorKind.InvalidWire, "llm.messages_service_tier_invalid", "Messages supports only the priority service tier") }
        root.put("speed", wireJsonString("fast"))
    }
    match (request.toolChoice) {
        case LlmWireToolChoice.Auto => ()
        case LlmWireToolChoice.NoTools => root.put("tool_choice", wireJsonObject([WireJsonField("type", wireJsonString("none"))]))
        case LlmWireToolChoice.Required => root.put("tool_choice", wireJsonObject([WireJsonField("type", wireJsonString("any"))]))
    }
    match (request.thinking) {
        case LlmWireThinkingControl.Disabled => if (deepSeek) {
            root.put("thinking", wireJsonObject([
                WireJsonField("type", wireJsonString("disabled"))
            ]))
        }
        case LlmWireThinkingControl.Budget(tokens) => if (deepSeek) {
            throw LlmTransportError(
                LlmTransportErrorKind.InvalidWire,
                "llm.deepseek_thinking_mode_invalid",
                "DeepSeek Messages requires toggle or effort thinking control"
            )
        } else {
            root.put("thinking", wireJsonObject([
                WireJsonField("type", wireJsonString("enabled")),
                WireJsonField("budget_tokens", wireJsonNumber(tokens.toString()))
            ]))
        }
        case LlmWireThinkingControl.Toggle(enabled) => if (deepSeek || enabled) {
            root.put("thinking", wireJsonObject([
                WireJsonField("type", wireJsonString(if (enabled) { "enabled" } else { "disabled" }))
            ]))
        }
        case LlmWireThinkingControl.Adaptive(level) =>
            if (deepSeek) {
                throw LlmTransportError(
                    LlmTransportErrorKind.InvalidWire,
                    "llm.deepseek_thinking_mode_invalid",
                    "DeepSeek Messages requires toggle or effort thinking control"
                )
            }
            let adaptive = wireJsonObject([
                WireJsonField("type", wireJsonString("adaptive"))
            ])
            match (level) {
                case Some(value) => adaptive.put(
                    "effort", wireJsonString(wireThinkingEffort(value))
                )
                case None => ()
            }
            root.put("thinking", adaptive)
        case LlmWireThinkingControl.Effort(level) => if (deepSeek) {
            root.put("thinking", wireJsonObject([
                WireJsonField("type", wireJsonString("enabled"))
            ]))
            outputConfig.put("effort", wireJsonString(deepSeekThinkingEffort(level)))
        } else {
            throw LlmTransportError(
                LlmTransportErrorKind.InvalidWire,
                "llm.messages_thinking_mode_invalid",
                "Messages requires budget, toggle, or adaptive thinking control"
            )
        }
    }
    if (!outputConfig.fields.isEmpty()) { root.put("output_config", outputConfig) }
    if (request.system != "") { root.put("system", wireJsonString(request.system)) }
    let callIds = collectWireCallIds(request.messages)
    let messages = wireJsonArray([])
    for (message in request.messages) {
        let content = wireJsonArray([])
        for (block in message.blocks) {
            if (!wireOrphanToolResult(block, callIds)) { content.add(encodeMessagesWireBlock(block)) }
        }
        messages.add(wireJsonObject([
            WireJsonField("role", wireJsonString(wireRoleName(message.role))), WireJsonField("content", content)
        ]))
    }
    root.put("messages", messages)
    if (!request.tools.isEmpty()) {
        let tools = wireJsonArray([])
        for (tool in request.tools) { tools.add(wireJsonObject([
            WireJsonField("name", wireJsonString(tool.name)),
            WireJsonField("description", wireJsonString(tool.description)),
            WireJsonField("input_schema", tool.inputSchema)
        ])) }
        root.put("tools", tools)
    }
    root.stringify()
}

public func encodeResponsesWireRequest(request: LlmWireRequest): String {
    let root = wireRequestRoot(request, "max_output_tokens")
    if (let LlmWireCachePolicy.StablePrefix <- request.cachePolicy) {
        if (request.cacheKey != "") { root.put("prompt_cache_key", wireJsonString(request.cacheKey)) }
    }
    match (request.structuredOutput) {
        case Some(spec) => root.put("text", wireJsonObject([WireJsonField("format", wireStructuredOutput(spec))]))
        case None => ()
    }
    wireCommonOptions(root, request, true)
    if (request.system != "") { root.put("instructions", wireJsonString(request.system)) }
    let input = wireJsonArray([])
    for (message in request.messages) { for (block in message.blocks) {
        match (block.kind) {
            case LlmWireBlockKind.ToolResult => input.add(wireJsonObject([
                WireJsonField("type", wireJsonString("function_call_output")),
                WireJsonField("call_id", wireJsonString(block.callId)),
                WireJsonField("output", wireJsonString(wireVisibleToolResult(block)))
            ]))
            case LlmWireBlockKind.Reasoning | LlmWireBlockKind.ToolCall => match (block.opaqueState) {
                case Some(state) => if (state.protocol == "responses" && state.payload != "") { input.add(parseWireJson(state.payload)) }
                    else if (let LlmWireBlockKind.ToolCall <- block.kind) { input.add(encodeResponsesWireFunctionCall(block)) }
                case None => if (let LlmWireBlockKind.ToolCall <- block.kind) { input.add(encodeResponsesWireFunctionCall(block)) }
            }
            case LlmWireBlockKind.Error => ()
            case _ => input.add(wireJsonObject([
                WireJsonField("role", wireJsonString(wireRoleName(message.role))),
                WireJsonField("content", wireJsonArray([encodeResponsesWireBlock(block)]))
            ]))
        }
    } }
    root.put("input", input)
    addResponsesWireTools(root, request.tools)
    root.stringify()
}

public func encodeChatCompletionsWireRequest(request: LlmWireRequest): String {
    encodeChatCompletionsWireRequestForDialect(request, false)
}

public func encodeDeepSeekChatWireRequest(request: LlmWireRequest): String {
    encodeChatCompletionsWireRequestForDialect(request, true)
}

func encodeChatCompletionsWireRequestForDialect(
    request: LlmWireRequest,
    deepSeek: Bool
): String {
    let root = wireRequestRoot(request, "max_tokens")
    if (let LlmWireCachePolicy.StablePrefix <- request.cachePolicy) {
        if (request.cacheKey != "") { root.put("prompt_cache_key", wireJsonString(request.cacheKey)) }
    }
    match (request.structuredOutput) {
        case Some(spec) =>
            let nested = wireJsonObject([
                WireJsonField("name", wireJsonString(spec.name)), WireJsonField("schema", spec.schema),
                WireJsonField("strict", wireJsonBool(spec.strict))
            ])
            if (spec.description != "") { nested.put("description", wireJsonString(spec.description)) }
            root.put("response_format", wireJsonObject([
                WireJsonField("type", wireJsonString("json_schema")), WireJsonField("json_schema", nested)
            ]))
        case None => ()
    }
    if (request.streaming) { root.put("stream_options", wireJsonObject([WireJsonField("include_usage", wireJsonBool(true))])) }
    if (deepSeek) { wireDeepSeekChatThinking(root, request.thinking) }
    else { wireCommonOptions(root, request, false) }
    if (deepSeek) { wireCommonNonThinkingOptions(root, request) }
    let messages = wireJsonArray([])
    if (request.system != "") { messages.add(wireJsonObject([
        WireJsonField("role", wireJsonString("system")), WireJsonField("content", wireJsonString(request.system))
    ])) }
    let callIds = collectWireCallIds(request.messages)
    for (message in request.messages) { encodeChatWireMessage(messages, message, callIds) }
    root.put("messages", messages)
    if (!request.tools.isEmpty()) {
        let tools = wireJsonArray([])
        for (tool in request.tools) { tools.add(wireJsonObject([
            WireJsonField("type", wireJsonString("function")),
            WireJsonField("function", wireJsonObject([
                WireJsonField("name", wireJsonString(tool.name)),
                WireJsonField("description", wireJsonString(tool.description)),
                WireJsonField("parameters", tool.inputSchema)
            ]))
        ])) }
        root.put("tools", tools)
    }
    root.stringify()
}

func wireRequestRoot(request: LlmWireRequest, tokenField: String): JsonNode {
    wireJsonObject([
        WireJsonField("model", wireJsonString(request.model)),
        WireJsonField(tokenField, wireJsonNumber(request.maxOutputTokens.toString())),
        WireJsonField("stream", wireJsonBool(request.streaming))
    ])
}

func wireCommonOptions(root: JsonNode, request: LlmWireRequest, responses: Bool): Unit {
    wireCommonNonThinkingOptions(root, request)
    match (request.thinking) {
        case LlmWireThinkingControl.Disabled => if (responses) {
            root.put("reasoning", wireJsonObject([
                WireJsonField("enabled", wireJsonBool(false))
            ]))
        }
        case LlmWireThinkingControl.Effort(level) => if (responses) {
            root.put("reasoning", wireJsonObject([
                WireJsonField("effort", wireJsonString(wireThinkingEffort(level)))
            ]))
        } else {
            root.put("reasoning_effort", wireJsonString(wireThinkingEffort(level)))
        }
        case LlmWireThinkingControl.Toggle(enabled) => if (responses) {
            root.put("reasoning", wireJsonObject([
                WireJsonField("enabled", wireJsonBool(enabled))
            ]))
        } else {
            root.put("enable_thinking", wireJsonBool(enabled))
        }
        case LlmWireThinkingControl.Adaptive(level) =>
            let adaptive = wireJsonObject([
                WireJsonField("enabled", wireJsonBool(true)),
                WireJsonField("type", wireJsonString("adaptive"))
            ])
            match (level) {
                case Some(value) => adaptive.put(
                    "effort", wireJsonString(wireThinkingEffort(value))
                )
                case None => ()
            }
            if (responses) { root.put("reasoning", adaptive) }
            else { root.put("thinking", adaptive) }
        case LlmWireThinkingControl.Budget(_) => throw LlmTransportError(
            LlmTransportErrorKind.InvalidWire,
            "llm.effort_thinking_mode_invalid",
            "Responses and Chat Completions do not accept numeric thinking budgets"
        )
    }
}

func wireCommonNonThinkingOptions(root: JsonNode, request: LlmWireRequest): Unit {
    if (request.serviceTier != "") { root.put("service_tier", wireJsonString(request.serviceTier)) }
    match (request.toolChoice) {
        case LlmWireToolChoice.Auto => ()
        case LlmWireToolChoice.NoTools => root.put("tool_choice", wireJsonString("none"))
        case LlmWireToolChoice.Required => root.put("tool_choice", wireJsonString("required"))
    }
    root.put("parallel_tool_calls", wireJsonBool(request.parallelToolCalls))
}

func wireDeepSeekChatThinking(root: JsonNode, thinking: LlmWireThinkingControl): Unit {
    match (thinking) {
        case LlmWireThinkingControl.Disabled => root.put("thinking", wireJsonObject([
            WireJsonField("type", wireJsonString("disabled"))
        ]))
        case LlmWireThinkingControl.Toggle(enabled) => root.put("thinking", wireJsonObject([
            WireJsonField("type", wireJsonString(if (enabled) { "enabled" } else { "disabled" }))
        ]))
        case LlmWireThinkingControl.Effort(level) =>
            root.put("thinking", wireJsonObject([
                WireJsonField("type", wireJsonString("enabled"))
            ]))
            root.put("reasoning_effort", wireJsonString(deepSeekThinkingEffort(level)))
        case _ => throw LlmTransportError(
            LlmTransportErrorKind.InvalidWire,
            "llm.deepseek_thinking_mode_invalid",
            "DeepSeek requires toggle or effort thinking control"
        )
    }
}

func addResponsesWireTools(root: JsonNode, values: Array<LlmWireTool>): Unit {
    if (values.isEmpty()) { return }
    let tools = wireJsonArray([])
    for (tool in values) { tools.add(wireJsonObject([
        WireJsonField("type", wireJsonString("function")), WireJsonField("name", wireJsonString(tool.name)),
        WireJsonField("description", wireJsonString(tool.description)), WireJsonField("parameters", tool.inputSchema)
    ])) }
    root.put("tools", tools)
}

func encodeMessagesWireBlock(block: LlmWireBlock): JsonNode {
    match (block.kind) {
        case LlmWireBlockKind.Text => wireJsonObject([WireJsonField("type", wireJsonString("text")), WireJsonField("text", wireJsonString(block.text))])
        case LlmWireBlockKind.Image =>
            let image = requiredWireImage(block); let source = wireJsonObject([])
            match (image.sourceKind) {
                case LlmWireImageSourceKind.Url => source.put("type", wireJsonString("url")); source.put("url", wireJsonString(image.data))
                case LlmWireImageSourceKind.Base64 => source.put("type", wireJsonString("base64")); source.put("media_type", wireJsonString(image.mediaType)); source.put("data", wireJsonString(image.data))
            }
            wireJsonObject([WireJsonField("type", wireJsonString("image")), WireJsonField("source", source)])
        case LlmWireBlockKind.ToolCall => wireJsonObject([
            WireJsonField("type", wireJsonString("tool_use")), WireJsonField("id", wireJsonString(block.callId)),
            WireJsonField("name", wireJsonString(block.name)), WireJsonField("input", block.arguments)
        ])
        case LlmWireBlockKind.ToolResult => wireJsonObject([
            WireJsonField("type", wireJsonString("tool_result")), WireJsonField("tool_use_id", wireJsonString(block.callId)),
            WireJsonField("content", wireJsonString(wireVisibleToolResult(block))), WireJsonField("is_error", wireJsonBool(block.isError))
        ])
        case LlmWireBlockKind.Reasoning => match (block.opaqueState) {
            case Some(state) => if (state.protocol == "messages" && state.payload != "") { parseWireJson(state.payload) }
                else { wireJsonObject([WireJsonField("type", wireJsonString("thinking")), WireJsonField("thinking", wireJsonString(block.text))]) }
            case None => wireJsonObject([WireJsonField("type", wireJsonString("thinking")), WireJsonField("thinking", wireJsonString(block.text))])
        }
        case LlmWireBlockKind.Refusal | LlmWireBlockKind.Unknown => wireJsonObject([WireJsonField("type", wireJsonString("text")), WireJsonField("text", wireJsonString(block.text))])
        case LlmWireBlockKind.Error => wireJsonObject([WireJsonField("type", wireJsonString("text")), WireJsonField("text", wireJsonString(""))])
    }
}

func encodeResponsesWireBlock(block: LlmWireBlock): JsonNode {
    match (block.kind) {
        case LlmWireBlockKind.Text => wireJsonObject([WireJsonField("type", wireJsonString("input_text")), WireJsonField("text", wireJsonString(block.text))])
        case LlmWireBlockKind.Image =>
            let image = requiredWireImage(block)
            wireJsonObject([WireJsonField("type", wireJsonString("input_image")), WireJsonField("image_url", wireJsonString(wireImageUrl(image))), WireJsonField("detail", wireJsonString(wireImageDetail(image.detail)))])
        case LlmWireBlockKind.Refusal => wireJsonObject([WireJsonField("type", wireJsonString("refusal")), WireJsonField("refusal", wireJsonString(block.text))])
        case LlmWireBlockKind.ToolCall => encodeResponsesWireFunctionCall(block)
        case LlmWireBlockKind.Error => wireJsonObject([WireJsonField("type", wireJsonString("input_text")), WireJsonField("text", wireJsonString(""))])
        case _ => wireJsonObject([WireJsonField("type", wireJsonString("input_text")), WireJsonField("text", wireJsonString(block.text))])
    }
}

func encodeResponsesWireFunctionCall(block: LlmWireBlock): JsonNode {
    wireJsonObject([
        WireJsonField("type", wireJsonString("function_call")), WireJsonField("call_id", wireJsonString(block.callId)),
        WireJsonField("name", wireJsonString(block.name)), WireJsonField("arguments", wireJsonString(block.arguments.stringify()))
    ])
}

func encodeChatWireMessage(messages: JsonNode, message: LlmWireMessage, callIds: HashSet<String>): Unit {
    var text = ""; var reasoning = ""; var hasImage = false
    let parts = wireJsonArray([]); let calls = wireJsonArray([]); let results = ArrayList<LlmWireBlock>()
    for (block in message.blocks) {
        match (block.kind) {
            case LlmWireBlockKind.Text | LlmWireBlockKind.Refusal =>
                text += block.text; parts.add(wireJsonObject([WireJsonField("type", wireJsonString("text")), WireJsonField("text", wireJsonString(block.text))]))
            case LlmWireBlockKind.Reasoning => reasoning += block.text
            case LlmWireBlockKind.Image =>
                hasImage = true; let image = requiredWireImage(block)
                parts.add(wireJsonObject([WireJsonField("type", wireJsonString("image_url")), WireJsonField("image_url", wireJsonObject([
                    WireJsonField("url", wireJsonString(wireImageUrl(image))), WireJsonField("detail", wireJsonString(wireImageDetail(image.detail)))
                ]))]))
            case LlmWireBlockKind.ToolCall => calls.add(wireJsonObject([
                WireJsonField("id", wireJsonString(block.callId)), WireJsonField("type", wireJsonString("function")),
                WireJsonField("function", wireJsonObject([WireJsonField("name", wireJsonString(block.name)), WireJsonField("arguments", wireJsonString(block.arguments.stringify()))]))
            ]))
            case LlmWireBlockKind.ToolResult => if (!wireOrphanToolResult(block, callIds)) { results.add(block) }
            case _ => ()
        }
    }
    if (text != "" || reasoning != "" || hasImage || !calls.items.isEmpty()) {
        let value = wireJsonObject([WireJsonField("role", wireJsonString(wireRoleName(message.role)))])
        value.put("content", if (hasImage) { parts } else { wireJsonString(text) })
        if (reasoning != "") { value.put("reasoning_content", wireJsonString(reasoning)) }
        if (!calls.items.isEmpty()) { value.put("tool_calls", calls) }
        messages.add(value)
    }
    for (block in results) { messages.add(wireJsonObject([
        WireJsonField("role", wireJsonString("tool")), WireJsonField("tool_call_id", wireJsonString(block.callId)),
        WireJsonField("content", wireJsonString(wireVisibleToolResult(block)))
    ])) }
}

func collectWireCallIds(messages: Array<LlmWireMessage>): HashSet<String> {
    let result = HashSet<String>()
    for (message in messages) { for (block in message.blocks) { if (let LlmWireBlockKind.ToolCall <- block.kind) { if (block.callId != "") { result.add(block.callId) } } } }
    result
}
func wireOrphanToolResult(block: LlmWireBlock, calls: HashSet<String>): Bool { if (let LlmWireBlockKind.ToolResult <- block.kind) { !calls.contains(block.callId) } else { false } }
func wireRoleName(role: LlmWireRole): String { match (role) { case LlmWireRole.User => "user"; case LlmWireRole.Assistant => "assistant" } }
func wireThinkingEffort(value: LlmWireThinkingLevel): String { match (value) {
    case LlmWireThinkingLevel.Off | LlmWireThinkingLevel.Minimal => "minimal"
    case LlmWireThinkingLevel.Low => "low"; case LlmWireThinkingLevel.Medium => "medium"
    case LlmWireThinkingLevel.High => "high"; case LlmWireThinkingLevel.XHigh => "xhigh"; case LlmWireThinkingLevel.Max => "max"
} }
func deepSeekThinkingEffort(value: LlmWireThinkingLevel): String { match (value) {
    case LlmWireThinkingLevel.Off | LlmWireThinkingLevel.Minimal => throw LlmTransportError(
        LlmTransportErrorKind.InvalidWire,
        "llm.deepseek_effort_invalid",
        "DeepSeek does not support minimal reasoning effort"
    )
    case LlmWireThinkingLevel.Low => "low"
    case LlmWireThinkingLevel.Medium | LlmWireThinkingLevel.High | LlmWireThinkingLevel.XHigh => "high"
    case LlmWireThinkingLevel.Max => "max"
} }
func requiredWireImage(block: LlmWireBlock): LlmWireImage { match (block.image) { case Some(value) => value; case None => throw LlmTransportError(LlmTransportErrorKind.InvalidWire, "llm.image_missing", "image block has no image") } }
func wireImageUrl(image: LlmWireImage): String { match (image.sourceKind) { case LlmWireImageSourceKind.Url => image.data; case LlmWireImageSourceKind.Base64 => "data:" + image.mediaType + ";base64," + image.data } }
func wireImageDetail(detail: LlmWireImageDetail): String { match (detail) { case LlmWireImageDetail.Auto => "auto"; case LlmWireImageDetail.Low => "low"; case LlmWireImageDetail.High => "high" } }
func wireVisibleToolResult(block: LlmWireBlock): String {
    if (block.text != "") { return block.text }
    if (block.arguments.wireKind == WireJsonKind.Text) { return block.arguments.text }
    match (block.arguments.field("content")) { case Some(value) => if (value.wireKind == WireJsonKind.Text) { return value.text }; case None => () }
    block.arguments.stringify()
}
func wireStructuredOutput(spec: LlmWireStructuredOutput): JsonNode {
    let value = wireJsonObject([
        WireJsonField("type", wireJsonString("json_schema")), WireJsonField("name", wireJsonString(spec.name)),
        WireJsonField("schema", spec.schema), WireJsonField("strict", wireJsonBool(spec.strict))
    ])
    if (spec.description != "") { value.put("description", wireJsonString(spec.description)) }
    value
}

public class LlmWireUsage {
    public let inputTokens: Int64
    public let outputTokens: Int64
    public let reasoningTokens: Int64
    public let cacheReadTokens: Int64
    public let cacheWriteTokens: Int64
    public init(inputTokens!: Int64 = 0, outputTokens!: Int64 = 0, reasoningTokens!: Int64 = 0, cacheReadTokens!: Int64 = 0, cacheWriteTokens!: Int64 = 0) {
        this.inputTokens = inputTokens; this.outputTokens = outputTokens
        this.reasoningTokens = reasoningTokens; this.cacheReadTokens = cacheReadTokens
        this.cacheWriteTokens = cacheWriteTokens
    }
}

public class LlmWireReply {
    public let blocks: Array<LlmWireBlock>
    public let stopReason: String
    public let usage: LlmWireUsage
    public let responseId: String
    public init(blocks: Array<LlmWireBlock>, stopReason!: String = "", usage!: LlmWireUsage = LlmWireUsage(), responseId!: String = "") {
        this.blocks = blocks; this.stopReason = stopReason; this.usage = usage; this.responseId = responseId
    }
}

// Protocol facts are intentionally distinct from Completed. Completed means
// the adapter assembled and validated a usable reply; MessageTerminalObserved
// only means the provider emitted its protocol-level terminal marker.
public enum LlmWireEventKind {
    StreamStarted
    | ContentBlockStarted
    | TextDelta
    | ReasoningDelta
    | ToolCallStarted
    | ToolArgumentsDelta
    | ContentBlockCompleted
    | MessageTerminalObserved
    | UsageDelta
    | UsageCompleted
    | ProviderError
    | StreamTransportClosed
    | Completed
}
public class LlmWireEvent {
    public let kind: LlmWireEventKind
    public let text: String
    public let callId: String
    public let inputTokens: Int64
    public let outputTokens: Int64
    public let blockIndex: Int64
    public let blockKind: String
    public let terminalEventKind: String
    public let rawStopReason: String
    public init(
        kind: LlmWireEventKind,
        text!: String = "",
        callId!: String = "",
        inputTokens!: Int64 = 0,
        outputTokens!: Int64 = 0,
        blockIndex!: Int64 = -1,
        blockKind!: String = "",
        terminalEventKind!: String = "",
        rawStopReason!: String = ""
    ) {
        this.kind = kind; this.text = text; this.callId = callId
        this.inputTokens = inputTokens; this.outputTokens = outputTokens
        this.blockIndex = blockIndex; this.blockKind = blockKind
        this.terminalEventKind = terminalEventKind
        this.rawStopReason = rawStopReason
    }
}
public class LlmWireStreamResult {
    public let terminalSource: String
    public let events: Array<LlmWireEvent>
    public init(terminalSource: String, events: Array<LlmWireEvent>) { this.terminalSource = terminalSource; this.events = events }
}

// Stateless projection for callers that want low-latency events while the
// complete stream decoder continues to own terminal reconstruction.
public func decodeLlmWireEventFrame(protocol: LlmWireProtocol, payload: String): Array<LlmWireEvent> {
    if (payload == "" || payload == "[DONE]") { return [] }
    let event = wireObject(parseWireJson(payload), "provider stream event")
    let output = ArrayList<LlmWireEvent>()
    match (protocol) {
        case LlmWireProtocol.Messages => match (wireString(event, "type")) {
            case "message_start" => output.add(LlmWireEvent(
                LlmWireEventKind.StreamStarted,
                terminalEventKind: "message_start"
            ))
            case "content_block_start" => match (event.field("content_block")) {
                case Some(raw) =>
                    let block = wireObject(raw, "Messages content block")
                    output.add(LlmWireEvent(
                        LlmWireEventKind.ContentBlockStarted,
                        blockIndex: wireInt(event, "index"),
                        blockKind: wireString(block, "type")
                    ))
                    if (wireString(block, "type") == "tool_use") { output.add(LlmWireEvent(
                        LlmWireEventKind.ToolCallStarted, callId: wireString(block, "id"), text: wireString(block, "name")
                    )) }
                case None => ()
            }
            case "content_block_delta" => match (event.field("delta")) {
                case Some(raw) =>
                    let delta = wireObject(raw, "Messages delta")
                    match (wireString(delta, "type")) {
                        case "text_delta" => output.add(LlmWireEvent(LlmWireEventKind.TextDelta, text: wireString(delta, "text")))
                        case "thinking_delta" => output.add(LlmWireEvent(LlmWireEventKind.ReasoningDelta, text: wireString(delta, "thinking")))
                        case "input_json_delta" => output.add(LlmWireEvent(LlmWireEventKind.ToolArgumentsDelta, text: wireString(delta, "partial_json")))
                        case _ => ()
                    }
                case None => ()
            }
            case "content_block_stop" => output.add(LlmWireEvent(
                LlmWireEventKind.ContentBlockCompleted,
                blockIndex: wireInt(event, "index")
            ))
            case "message_delta" =>
                let delta = wireObjectOrEmpty(event, "delta")
                let usage = wireObjectOrEmpty(event, "usage")
                output.add(LlmWireEvent(
                    LlmWireEventKind.UsageDelta,
                    outputTokens: wireInt(usage, "output_tokens"),
                    rawStopReason: wireString(delta, "stop_reason")
                ))
            case "message_stop" => output.add(LlmWireEvent(
                LlmWireEventKind.MessageTerminalObserved,
                terminalEventKind: "message_stop"
            ))
            case "error" => output.add(LlmWireEvent(
                LlmWireEventKind.ProviderError,
                text: wireString(wireObjectOrEmpty(event, "error"), "message")
            ))
            case _ => ()
        }
        case LlmWireProtocol.Responses => match (wireString(event, "type")) {
            case "response.created" | "response.in_progress" => output.add(LlmWireEvent(
                LlmWireEventKind.StreamStarted,
                terminalEventKind: wireString(event, "type")
            ))
            case "response.output_text.delta" => output.add(LlmWireEvent(LlmWireEventKind.TextDelta, text: wireString(event, "delta")))
            case "response.reasoning_summary_text.delta" => output.add(LlmWireEvent(LlmWireEventKind.ReasoningDelta, text: wireString(event, "delta")))
            case "response.function_call_arguments.delta" => output.add(LlmWireEvent(LlmWireEventKind.ToolArgumentsDelta, callId: wireString(event, "item_id"), text: wireString(event, "delta")))
            case "response.output_item.added" => match (event.field("item")) {
                case Some(raw) =>
                    let item = wireObject(raw, "Responses output item")
                    output.add(LlmWireEvent(
                        LlmWireEventKind.ContentBlockStarted,
                        blockIndex: wireInt(event, "output_index"),
                        blockKind: wireString(item, "type")
                    ))
                    if (wireString(item, "type") == "function_call") { output.add(LlmWireEvent(
                        LlmWireEventKind.ToolCallStarted, callId: wireString(item, "call_id"), text: wireString(item, "name")
                    )) }
                case None => ()
            }
            case "response.output_item.done" => output.add(LlmWireEvent(
                LlmWireEventKind.ContentBlockCompleted,
                callId: match (event.field("item")) {
                    case Some(raw) => wireString(wireObject(raw, "Responses output item"), "call_id")
                    case None => ""
                },
                blockIndex: wireInt(event, "output_index")
            ))
            case "response.completed" => match (event.field("response")) {
                case Some(raw) =>
                    let response = wireObject(raw, "Responses terminal response")
                    output.add(LlmWireEvent(
                        LlmWireEventKind.MessageTerminalObserved,
                        terminalEventKind: "response.completed",
                        rawStopReason: wireString(response, "status")
                    ))
                    let usage = wireObjectOrEmpty(response, "usage")
                    output.add(LlmWireEvent(
                        LlmWireEventKind.UsageCompleted,
                        inputTokens: wireInt(usage, "input_tokens"),
                        outputTokens: wireInt(usage, "output_tokens")
                    ))
                case None => ()
            }
            case "error" => output.add(LlmWireEvent(
                LlmWireEventKind.ProviderError,
                text: wireString(event, "message")
            ))
            case _ => ()
        }
        case LlmWireProtocol.ChatCompletions =>
            let choices = match (event.field("choices")) { case Some(raw) => wireArray(raw, "Chat stream choices"); case None => return [] }
            if (choices.items.isEmpty()) { return [] }
            let choice = wireObject(choices.items[0], "Chat stream choice")
            let finishReason = wireString(choice, "finish_reason")
            if (finishReason != "") { output.add(LlmWireEvent(
                LlmWireEventKind.MessageTerminalObserved,
                terminalEventKind: "finish_reason",
                rawStopReason: finishReason
            )) }
            let delta = match (choice.field("delta")) { case Some(raw) => wireObject(raw, "Chat stream delta"); case None => return output.toArray() }
            let text = wireString(delta, "content"); if (text != "") { output.add(LlmWireEvent(LlmWireEventKind.TextDelta, text: text)) }
            let reasoning = wireString(delta, "reasoning_content"); if (reasoning != "") { output.add(LlmWireEvent(LlmWireEventKind.ReasoningDelta, text: reasoning)) }
            match (delta.field("tool_calls")) {
                case Some(raw) => for (entry in wireArray(raw, "Chat stream tool calls").items) {
                    let call = wireObject(entry, "Chat stream tool call"); let callId = wireString(call, "id")
                    match (call.field("function")) {
                        case Some(rawFunction) =>
                            let function = wireObject(rawFunction, "Chat stream function"); let name = wireString(function, "name")
                            if (callId != "" || name != "") { output.add(LlmWireEvent(LlmWireEventKind.ToolCallStarted, callId: callId, text: name)) }
                            let arguments = wireString(function, "arguments")
                            if (arguments != "") { output.add(LlmWireEvent(LlmWireEventKind.ToolArgumentsDelta, callId: callId, text: arguments)) }
                        case None => ()
                    }
                }
                case None => ()
            }
    }
    output.toArray()
}

public func decodeLlmWireReply(protocol: LlmWireProtocol, source: String, provider!: String = ""): LlmWireReply {
    try {
        match (protocol) {
            case LlmWireProtocol.Messages => decodeMessagesWireReply(source, provider: provider)
            case LlmWireProtocol.Responses => decodeResponsesWireReply(source, provider: provider)
            case LlmWireProtocol.ChatCompletions => decodeChatCompletionsWireReply(source, provider: provider)
        }
    } catch (error: LlmTransportError) { throw error }
    catch (error: JsonException) { throw LlmTransportError(
        LlmTransportErrorKind.InvalidWire, "llm.payload_malformed", error.message, provider: provider
    ) }
    catch (error: Exception) { throw LlmTransportError(
        LlmTransportErrorKind.InvalidWire, "llm.payload_invalid", error.message, provider: provider
    ) }
}

public func decodeMessagesWireReply(source: String, provider!: String = ""): LlmWireReply {
    let root = wireObject(parseWireJson(source), "Messages response")
    rejectWireProviderError(root, provider)
    let blocks = ArrayList<LlmWireBlock>()
    for (value in wireArray(wireField(root, "content"), "Messages content").items) {
        let item = wireObject(value, "Messages content block")
        match (wireString(item, "type")) {
            case "text" => blocks.add(LlmWireBlock(LlmWireBlockKind.Text, text: wireString(item, "text")))
            case "thinking" => blocks.add(LlmWireBlock(
                LlmWireBlockKind.Reasoning,
                text: wireString(item, "thinking"),
                opaqueState: Some(LlmWireOpaqueState("messages", item.stringify()))
            ))
            case "tool_use" => blocks.add(LlmWireBlock(
                LlmWireBlockKind.ToolCall,
                callId: wireString(item, "id"), name: wireString(item, "name"),
                arguments: match (item.field("input")) { case Some(value) => value; case None => wireJsonObject([]) }
            ))
            case _ => ()
        }
    }
    let usage = wireObjectOrEmpty(root, "usage")
    let cacheRead = wireInt(usage, "cache_read_input_tokens")
    let cacheWrite = wireInt(usage, "cache_creation_input_tokens")
    LlmWireReply(
        blocks.toArray(),
        stopReason: wireString(root, "stop_reason"),
        usage: LlmWireUsage(
            inputTokens: wireInt(usage, "input_tokens") + cacheRead + cacheWrite,
            outputTokens: wireInt(usage, "output_tokens"),
            cacheReadTokens: cacheRead, cacheWriteTokens: cacheWrite
        ),
        responseId: wireString(root, "id")
    )
}

public func decodeResponsesWireReply(source: String, provider!: String = ""): LlmWireReply {
    let root = wireObject(parseWireJson(source), "Responses response")
    rejectWireProviderError(root, provider)
    let blocks = ArrayList<LlmWireBlock>()
    for (value in wireArray(wireField(root, "output"), "Responses output").items) {
        let item = wireObject(value, "Responses output item")
        match (wireString(item, "type")) {
            case "message" => for (partValue in wireArray(wireField(item, "content"), "Responses message content").items) {
                let part = wireObject(partValue, "Responses content part")
                match (wireString(part, "type")) {
                    case "output_text" => blocks.add(LlmWireBlock(LlmWireBlockKind.Text, text: wireString(part, "text")))
                    case "refusal" => blocks.add(LlmWireBlock(LlmWireBlockKind.Refusal, text: wireString(part, "refusal")))
                    case _ => ()
                }
            }
            case "function_call" =>
                let rawArguments = match (item.field("arguments")) {
                    case Some(value) => if (value.wireKind == WireJsonKind.Text) { parseWireJson(value.text) } else { value }
                    case None => wireJsonObject([])
                }
                blocks.add(LlmWireBlock(
                    LlmWireBlockKind.ToolCall,
                    callId: wireString(item, "call_id"), name: wireString(item, "name"), arguments: rawArguments,
                    opaqueState: Some(LlmWireOpaqueState("responses", item.stringify(), itemId: wireString(item, "id")))
                ))
            case "reasoning" => blocks.add(LlmWireBlock(
                LlmWireBlockKind.Reasoning,
                opaqueState: Some(LlmWireOpaqueState("responses", item.stringify(), itemId: wireString(item, "id")))
            ))
            case _ => ()
        }
    }
    let usage = wireObjectOrEmpty(root, "usage")
    let inputDetails = wireObjectOrEmpty(usage, "input_tokens_details")
    let outputDetails = wireObjectOrEmpty(usage, "output_tokens_details")
    LlmWireReply(
        blocks.toArray(),
        // Keep the provider terminal fact intact. Tool-use is derived from the
        // ordered blocks by the decision validator, not written over status.
        stopReason: wireString(root, "status"),
        usage: LlmWireUsage(
            inputTokens: wireInt(usage, "input_tokens"), outputTokens: wireInt(usage, "output_tokens"),
            reasoningTokens: wireInt(outputDetails, "reasoning_tokens"),
            cacheReadTokens: wireInt(inputDetails, "cached_tokens"), cacheWriteTokens: wireInt(inputDetails, "cache_write_tokens")
        ),
        responseId: wireString(root, "id")
    )
}

public func decodeChatCompletionsWireReply(source: String, provider!: String = ""): LlmWireReply {
    let root = wireObject(parseWireJson(source), "Chat Completions response")
    rejectWireProviderError(root, provider)
    let choices = wireArray(wireField(root, "choices"), "Chat Completions choices")
    if (choices.items.isEmpty()) { throw LlmTransportError(LlmTransportErrorKind.InvalidWire, "llm.chat_choices_empty", "Chat Completions response contains no choices", provider: provider) }
    let choice = wireObject(choices.items[0], "Chat Completions choice")
    let message = wireObject(wireField(choice, "message"), "Chat Completions message")
    let blocks = ArrayList<LlmWireBlock>()
    let content = wireString(message, "content")
    if (content != "") { blocks.add(LlmWireBlock(LlmWireBlockKind.Text, text: content)) }
    let reasoning = wireString(message, "reasoning_content")
    if (reasoning != "") { blocks.add(LlmWireBlock(LlmWireBlockKind.Reasoning, text: reasoning)) }
    let finishReason = wireString(choice, "finish_reason")
    if (finishReason != "max_tokens" && finishReason != "length") {
        match (message.field("tool_calls")) {
            case Some(raw) => for (entry in wireArray(raw, "Chat Completions tool_calls").items) {
                let call = wireObject(entry, "Chat Completions tool call")
                let function = wireObject(wireField(call, "function"), "Chat Completions function")
                let arguments = wireString(function, "arguments")
                blocks.add(LlmWireBlock(
                    LlmWireBlockKind.ToolCall, callId: wireString(call, "id"), name: wireString(function, "name"),
                    arguments: if (arguments == "") { wireJsonObject([]) } else { parseWireJson(arguments) }
                ))
            }
            case None => ()
        }
    }
    let usage = wireObjectOrEmpty(root, "usage")
    let promptDetails = wireObjectOrEmpty(usage, "prompt_tokens_details")
    let completionDetails = wireObjectOrEmpty(usage, "completion_tokens_details")
    LlmWireReply(
        blocks.toArray(), stopReason: finishReason,
        usage: LlmWireUsage(
            inputTokens: wireInt(usage, "prompt_tokens"), outputTokens: wireInt(usage, "completion_tokens"),
            reasoningTokens: wireInt(completionDetails, "reasoning_tokens"),
            cacheReadTokens: wireInt(promptDetails, "cached_tokens"), cacheWriteTokens: wireInt(promptDetails, "cache_write_tokens")
        ), responseId: wireString(root, "id")
    )
}

public func decodeLlmWireEventStream(protocol: LlmWireProtocol, source: String, provider!: String = ""): LlmWireStreamResult {
    try {
        match (protocol) {
            case LlmWireProtocol.Responses => decodeResponsesWireStream(source)
            case LlmWireProtocol.ChatCompletions => decodeChatWireStream(source)
            case LlmWireProtocol.Messages => decodeMessagesWireStream(source)
        }
    } catch (error: LlmTransportError) { throw error }
    catch (error: JsonException) { throw LlmTransportError(LlmTransportErrorKind.InvalidWire, "llm.stream_payload_malformed", error.message, provider: provider) }
    catch (error: Exception) { throw LlmTransportError(LlmTransportErrorKind.InvalidWire, "llm.stream_payload_invalid", error.message, provider: provider) }
}

func wireSseEvents(source: String): Array<SseEvent> {
    let decoder = SseDecoder(); let events = ArrayList<SseEvent>()
    match (decoder.push(source)) { case LlmResult.Ok(values) => for (value in values) { events.add(value) }; case LlmResult.Err(error) => throw error }
    match (decoder.finish()) { case LlmResult.Ok(values) => for (value in values) { events.add(value) }; case LlmResult.Err(error) => throw error }
    events.toArray()
}

func decodeResponsesWireStream(source: String): LlmWireStreamResult {
    var terminal = ""; var streamStarted = false; let output = ArrayList<LlmWireEvent>()
    for (frame in wireSseEvents(source)) {
        if (frame.data == "[DONE]" || frame.data == "") { continue }
        let event = wireObject(parseWireJson(frame.data), "Responses stream event")
        if (!streamStarted) {
            output.add(LlmWireEvent(LlmWireEventKind.StreamStarted))
            streamStarted = true
        }
        match (wireString(event, "type")) {
            case "response.output_text.delta" => output.add(LlmWireEvent(LlmWireEventKind.TextDelta, text: wireString(event, "delta")))
            case "response.reasoning_summary_text.delta" => output.add(LlmWireEvent(LlmWireEventKind.ReasoningDelta, text: wireString(event, "delta")))
            case "response.completed" => match (event.field("response")) {
                case Some(value) =>
                    terminal = value.stringify(); let usage = wireObjectOrEmpty(value, "usage")
                    output.add(LlmWireEvent(
                        LlmWireEventKind.MessageTerminalObserved,
                        terminalEventKind: "response.completed",
                        rawStopReason: wireString(value, "status")
                    ))
                    output.add(LlmWireEvent(LlmWireEventKind.UsageCompleted, inputTokens: wireInt(usage, "input_tokens"), outputTokens: wireInt(usage, "output_tokens")))
                case None => ()
            }
            case "error" => rejectWireProviderError(wireJsonObject([WireJsonField("error", event)]), "")
            case _ => ()
        }
    }
    if (terminal == "") { throw LlmTransportError(LlmTransportErrorKind.InvalidWire, "llm.responses_terminal_missing", "Responses stream did not contain a terminal response") }
    output.add(LlmWireEvent(LlmWireEventKind.Completed))
    LlmWireStreamResult(terminal, output.toArray())
}

class ChatWireCall {
    let index: Int64; var id = ""; var name = ""; var arguments = ""
    init(index: Int64) { this.index = index }
}
func chatWireCall(values: ArrayList<ChatWireCall>, index: Int64): ChatWireCall {
    for (value in values where value.index == index) { return value }
    let created = ChatWireCall(index); values.add(created); created
}

func decodeChatWireStream(source: String): LlmWireStreamResult {
    var responseId = ""; var model = ""; var content = ""; var reasoning = ""; var finishReason = ""
    var input: Int64 = 0; var outputTokens: Int64 = 0; var cacheRead: Int64 = 0; var cacheWrite: Int64 = 0; var reasoningTokens: Int64 = 0
    let calls = ArrayList<ChatWireCall>(); let events = ArrayList<LlmWireEvent>()
    var streamStarted = false
    for (frame in wireSseEvents(source)) {
        if (frame.data == "[DONE]" || frame.data == "") { continue }
        let event = wireObject(parseWireJson(frame.data), "Chat Completions stream event")
        if (!streamStarted) {
            events.add(LlmWireEvent(LlmWireEventKind.StreamStarted))
            streamStarted = true
        }
        if (responseId == "") { responseId = wireString(event, "id"); model = wireString(event, "model") }
        match (event.field("usage")) {
            case Some(raw) => if (raw.wireKind == WireJsonKind.Object) {
                input = wireInt(raw, "prompt_tokens"); outputTokens = wireInt(raw, "completion_tokens")
                cacheRead = wireInt(wireObjectOrEmpty(raw, "prompt_tokens_details"), "cached_tokens")
                cacheWrite = wireInt(wireObjectOrEmpty(raw, "prompt_tokens_details"), "cache_write_tokens")
                reasoningTokens = wireInt(wireObjectOrEmpty(raw, "completion_tokens_details"), "reasoning_tokens")
            } else if (raw.wireKind != WireJsonKind.Null) { throw LlmTransportError(LlmTransportErrorKind.InvalidWire, "llm.chat_usage_invalid", "Chat Completions stream usage must be object or null") }
            case None => ()
        }
        let choices = match (event.field("choices")) { case Some(raw) => wireArray(raw, "Chat Completions stream choices"); case None => continue }
        if (choices.items.isEmpty()) { continue }
        let choice = wireObject(choices.items[0], "Chat Completions stream choice")
        let finish = wireString(choice, "finish_reason"); if (finish != "") { finishReason = finish }
        let delta = match (choice.field("delta")) { case Some(raw) => if (raw.wireKind == WireJsonKind.Null) { continue } else { wireObject(raw, "Chat Completions delta") }; case None => continue }
        let text = wireString(delta, "content"); content += text; if (text != "") { events.add(LlmWireEvent(LlmWireEventKind.TextDelta, text: text)) }
        let thought = wireString(delta, "reasoning_content"); reasoning += thought; if (thought != "") { events.add(LlmWireEvent(LlmWireEventKind.ReasoningDelta, text: thought)) }
        match (delta.field("tool_calls")) {
            case Some(raw) => for (entry in wireArray(raw, "Chat Completions stream tool calls").items) {
                let item = wireObject(entry, "Chat Completions stream tool call"); let call = chatWireCall(calls, wireInt(item, "index"))
                let id = wireString(item, "id"); if (id != "") { call.id = id }
                match (item.field("function")) {
                    case Some(rawFunction) =>
                        let function = wireObject(rawFunction, "Chat Completions stream function")
                        let name = wireString(function, "name"); if (name != "") { call.name = name }
                        let fragment = wireString(function, "arguments"); call.arguments += fragment
                        if (fragment != "") { events.add(LlmWireEvent(LlmWireEventKind.ToolArgumentsDelta, text: fragment, callId: call.id)) }
                    case None => ()
                }
            }
            case None => ()
        }
    }
    if (finishReason == "") {
        throw LlmTransportError(
            LlmTransportErrorKind.InvalidWire,
            "llm.chat_terminal_missing",
            "Chat Completions stream did not contain a terminal finish_reason"
        )
    }
    let message = wireJsonObject([WireJsonField("role", wireJsonString("assistant")), WireJsonField("content", wireJsonString(content))])
    if (reasoning != "") { message.put("reasoning_content", wireJsonString(reasoning)) }
    let outputLimited = finishReason == "max_tokens" || finishReason == "length"
    if (!calls.isEmpty() && !outputLimited) {
        let values = wireJsonArray([])
        for (call in calls) { values.add(wireJsonObject([
            WireJsonField("id", wireJsonString(call.id)), WireJsonField("type", wireJsonString("function")),
            WireJsonField("function", wireJsonObject([WireJsonField("name", wireJsonString(call.name)), WireJsonField("arguments", wireJsonString(call.arguments))]))
        ])) }
        message.put("tool_calls", values)
    }
    if (content == "" && reasoning == "" && calls.isEmpty() && !outputLimited) { throw LlmTransportError(LlmTransportErrorKind.InvalidWire, "llm.chat_output_missing", "Chat Completions stream contained no accepted output") }
    let usage = wireJsonObject([
        WireJsonField("prompt_tokens", wireJsonNumber(input.toString())), WireJsonField("completion_tokens", wireJsonNumber(outputTokens.toString())),
        WireJsonField("prompt_tokens_details", wireJsonObject([WireJsonField("cached_tokens", wireJsonNumber(cacheRead.toString())), WireJsonField("cache_write_tokens", wireJsonNumber(cacheWrite.toString()))])),
        WireJsonField("completion_tokens_details", wireJsonObject([WireJsonField("reasoning_tokens", wireJsonNumber(reasoningTokens.toString()))]))
    ])
    let terminal = wireJsonObject([
        WireJsonField("id", wireJsonString(responseId)), WireJsonField("model", wireJsonString(model)),
        WireJsonField("choices", wireJsonArray([wireJsonObject([
            WireJsonField("index", wireJsonNumber("0")), WireJsonField("message", message), WireJsonField("finish_reason", wireJsonString(finishReason))
        ])])), WireJsonField("usage", usage)
    ])
    events.add(LlmWireEvent(
        LlmWireEventKind.MessageTerminalObserved,
        terminalEventKind: "finish_reason",
        rawStopReason: finishReason
    ))
    events.add(LlmWireEvent(LlmWireEventKind.UsageCompleted, inputTokens: input, outputTokens: outputTokens))
    events.add(LlmWireEvent(LlmWireEventKind.Completed))
    LlmWireStreamResult(terminal.stringify(), events.toArray())
}

class MessagesWireBlock {
    let index: Int64; let kind: String; let id: String; let name: String
    var text: String; var arguments = ""; var initialArguments = ""; var sawArgumentDelta = false; var signature = ""
    var completed = false
    init(index: Int64, kind: String, id: String, name: String, text: String) { this.index = index; this.kind = kind; this.id = id; this.name = name; this.text = text }
}
func messageWireBlock(values: ArrayList<MessagesWireBlock>, index: Int64): ?MessagesWireBlock { for (value in values where value.index == index) { return Some(value) }; None }

func decodeMessagesWireStream(source: String): LlmWireStreamResult {
    let blocks = ArrayList<MessagesWireBlock>(); let events = ArrayList<LlmWireEvent>()
    var responseId = ""; var stopReason = ""; var input: Int64 = 0; var output: Int64 = 0; var cacheRead: Int64 = 0; var cacheWrite: Int64 = 0
    var messageTerminalObserved = false
    for (frame in wireSseEvents(source)) {
        if (frame.data == "[DONE]" || frame.data == "") { continue }
        let event = wireObject(parseWireJson(frame.data), "Messages stream event")
        match (wireString(event, "type")) {
            case "message_start" => match (event.field("message")) {
                case Some(raw) => let message = wireObject(raw, "Messages stream message"); responseId = wireString(message, "id")
                    events.add(LlmWireEvent(
                        LlmWireEventKind.StreamStarted,
                        terminalEventKind: "message_start"
                    ))
                    let usage = wireObjectOrEmpty(message, "usage"); input = wireInt(usage, "input_tokens")
                    cacheRead = wireInt(usage, "cache_read_input_tokens"); cacheWrite = wireInt(usage, "cache_creation_input_tokens")
                case None => ()
            }
            case "content_block_start" =>
                let index = wireInt(event, "index")
                match (event.field("content_block")) {
                    case Some(raw) =>
                        let block = wireObject(raw, "Messages stream content block"); let kind = wireString(block, "type")
                        let item = MessagesWireBlock(index, kind, wireString(block, "id"), wireString(block, "name"), if (kind == "thinking") { wireString(block, "thinking") } else { wireString(block, "text") })
                        if (kind == "tool_use") { match (block.field("input")) { case Some(value) => if (value.wireKind != WireJsonKind.Object || !value.fields.isEmpty()) { item.initialArguments = value.stringify() }; case None => () } }
                        blocks.add(item)
                        events.add(LlmWireEvent(
                            LlmWireEventKind.ContentBlockStarted,
                            blockIndex: index,
                            blockKind: kind
                        ))
                    case None => ()
                }
            case "content_block_delta" => match ((messageWireBlock(blocks, wireInt(event, "index")), event.field("delta"))) {
                case (Some(target), Some(raw)) =>
                    let delta = wireObject(raw, "Messages stream delta")
                    match (wireString(delta, "type")) {
                        case "text_delta" => let value = wireString(delta, "text"); target.text += value; events.add(LlmWireEvent(LlmWireEventKind.TextDelta, text: value))
                        case "thinking_delta" => let value = wireString(delta, "thinking"); target.text += value; events.add(LlmWireEvent(LlmWireEventKind.ReasoningDelta, text: value))
                        case "input_json_delta" => let value = wireString(delta, "partial_json"); if (!target.sawArgumentDelta) { target.arguments = ""; target.sawArgumentDelta = true }; target.arguments += value; events.add(LlmWireEvent(LlmWireEventKind.ToolArgumentsDelta, text: value, callId: target.id))
                        case "signature_delta" => target.signature += wireString(delta, "signature")
                        case _ => ()
                    }
                case _ => ()
            }
            case "content_block_stop" => match (messageWireBlock(blocks, wireInt(event, "index"))) {
                case Some(target) =>
                    target.completed = true
                    events.add(LlmWireEvent(
                        LlmWireEventKind.ContentBlockCompleted,
                        callId: target.id,
                        blockIndex: target.index,
                        blockKind: target.kind
                    ))
                case None => throw LlmTransportError(
                    LlmTransportErrorKind.InvalidWire,
                    "llm.messages_block_stop_without_start",
                    "Messages stream completed an unknown content block"
                )
            }
            case "message_delta" =>
                match (event.field("delta")) { case Some(raw) => stopReason = wireString(wireObject(raw, "Messages message delta"), "stop_reason"); case None => () }
                output = wireInt(wireObjectOrEmpty(event, "usage"), "output_tokens")
                events.add(LlmWireEvent(
                    LlmWireEventKind.UsageDelta,
                    inputTokens: input + cacheRead + cacheWrite,
                    outputTokens: output,
                    rawStopReason: stopReason
                ))
            case "message_stop" =>
                messageTerminalObserved = true
                events.add(LlmWireEvent(
                    LlmWireEventKind.MessageTerminalObserved,
                    terminalEventKind: "message_stop",
                    rawStopReason: stopReason
                ))
            case "error" => rejectWireProviderError(wireJsonObject([WireJsonField("error", event)]), "")
            case _ => ()
        }
    }
    let outputLimited = stopReason == "max_tokens" || stopReason == "length"
    if (blocks.isEmpty() && !outputLimited) { throw LlmTransportError(LlmTransportErrorKind.InvalidWire, "llm.messages_output_missing", "Messages stream contained no content") }
    if (!messageTerminalObserved) { throw LlmTransportError(
        LlmTransportErrorKind.InvalidWire,
        "llm.messages_terminal_missing",
        "Messages stream did not contain message_stop"
    ) }
    for (block in blocks where !block.completed && !outputLimited) { throw LlmTransportError(
        LlmTransportErrorKind.InvalidWire,
        "llm.messages_content_block_incomplete",
        "Messages stream reached message_stop with an incomplete content block"
    ) }
    let content = wireJsonArray([])
    for (block in blocks where block.completed) {
        let value = wireJsonObject([WireJsonField("type", wireJsonString(block.kind))])
        match (block.kind) {
            case "text" => value.put("text", wireJsonString(block.text))
            case "thinking" => value.put("thinking", wireJsonString(block.text)); value.put("signature", wireJsonString(block.signature))
            case "tool_use" =>
                value.put("id", wireJsonString(block.id)); value.put("name", wireJsonString(block.name))
                let arguments = if (block.sawArgumentDelta) { block.arguments } else { block.initialArguments }
                value.put("input", if (arguments == "") { wireJsonObject([]) } else { parseWireJson(arguments) })
            case _ => ()
        }
        content.add(value)
    }
    let terminal = wireJsonObject([
        WireJsonField("id", wireJsonString(responseId)), WireJsonField("content", content), WireJsonField("stop_reason", wireJsonString(stopReason)),
        WireJsonField("usage", wireJsonObject([
            WireJsonField("input_tokens", wireJsonNumber(input.toString())), WireJsonField("output_tokens", wireJsonNumber(output.toString())),
            WireJsonField("cache_read_input_tokens", wireJsonNumber(cacheRead.toString())), WireJsonField("cache_creation_input_tokens", wireJsonNumber(cacheWrite.toString()))
        ]))
    ])
    events.add(LlmWireEvent(
        LlmWireEventKind.UsageCompleted,
        inputTokens: input + cacheRead + cacheWrite,
        outputTokens: output
    ))
    events.add(LlmWireEvent(LlmWireEventKind.Completed))
    LlmWireStreamResult(terminal.stringify(), events.toArray())
}

func rejectWireProviderError(root: JsonNode, provider: String): Unit {
    match (root.field("error")) {
        case Some(raw) =>
            let error = if (raw.wireKind == WireJsonKind.Object) { raw } else { wireJsonObject([WireJsonField("message", wireJsonString(raw.stringify()))]) }
            let message = wireString(error, "message")
            throw LlmTransportError(
                LlmTransportErrorKind.InvalidWire,
                "llm.provider_error",
                if (message == "") { "provider returned an error" } else { message },
                provider: provider,
                providerErrorCode: wireString(error, "code"),
                providerErrorType: wireString(error, "type")
            )
        case None => ()
    }
}
func wireObject(value: JsonNode, name: String): JsonNode { if (value.wireKind != WireJsonKind.Object) { throw LlmTransportError(LlmTransportErrorKind.InvalidWire, "llm.object_expected", name + " must be an object") }; value }
func wireArray(value: JsonNode, name: String): JsonNode { if (value.wireKind != WireJsonKind.List) { throw LlmTransportError(LlmTransportErrorKind.InvalidWire, "llm.array_expected", name + " must be an array") }; value }
func wireField(value: JsonNode, name: String): JsonNode { match (value.field(name)) { case Some(found) => found; case None => throw LlmTransportError(LlmTransportErrorKind.InvalidWire, "llm.field_missing", "provider response is missing field: " + name) } }
func wireString(value: JsonNode, name: String): String { match (value.field(name)) { case Some(found) => if (found.wireKind == WireJsonKind.Text) { found.text } else { "" }; case None => "" } }
func wireObjectOrEmpty(value: JsonNode, name: String): JsonNode { match (value.field(name)) { case Some(found) => if (found.wireKind == WireJsonKind.Object) { found } else { wireJsonObject([]) }; case None => wireJsonObject([]) } }
func wireInt(value: JsonNode, name: String): Int64 { match (value.field(name)) { case Some(found) => if (found.wireKind == WireJsonKind.Number) { try { Int64.parse(found.number) } catch (_: Exception) { 0 } } else { 0 }; case None => 0 } }
