package llm4cj

import std.collection.*
import std.convert.*
import yjson.*

let LLM_TRANSCRIPT_MAX_ITEMS: Int64 = 65536
let LLM_TRANSCRIPT_MAX_BLOCKS: Int64 = 65536
let LLM_TRANSCRIPT_MAX_TOOLS: Int64 = 4096
let LLM_TRANSCRIPT_MAX_DIAGNOSTIC_BYTES: Int64 = 2048

func snapshotInvalid(message: String): Nothing {
    let bounded = if (Int64(message.toArray().size) > LLM_TRANSCRIPT_MAX_DIAGNOSTIC_BYTES) { "transcript snapshot is invalid" } else { message }
    throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.transcript_snapshot_invalid", bounded)
}

func snapshotLimit(message: String): Nothing {
    throw LlmWireError(LlmWireErrorKind.LimitExceeded, "llm.transcript_limit_exceeded", message)
}

func snapshotCheckBytes(source: String): Unit {
    if (Int64(source.toArray().size) > LLM_JSON_MAX_BYTES) { snapshotLimit("transcript snapshot exceeds the JSON byte limit") }
}

func snapshotCheckFields(value: JsonNode, allowed: Array<String>): Unit {
    if (value.wireKind != WireJsonKind.Object) { snapshotInvalid("transcript snapshot value must be an object") }
    for (field in value.fields) {
        var known = false
        for (name in allowed where name == field.name) { known = true }
        if (!known) { snapshotInvalid("unknown transcript snapshot field: " + field.name) }
    }
}

func snapshotRequiredArray(value: JsonNode, name: String): Array<JsonNode> {
    let field = wireRequiredField(value, name)
    if (field.wireKind != WireJsonKind.List) { snapshotInvalid("snapshot field must be an array: " + name) }
    field.items
}

func snapshotRequiredObject(value: JsonNode, name: String): JsonNode {
    let field = wireRequiredField(value, name)
    if (field.wireKind != WireJsonKind.Object) { snapshotInvalid("snapshot field must be an object: " + name) }
    field
}

func snapshotRequireObject(value: JsonNode): Unit {
    if (value.wireKind != WireJsonKind.Object) { snapshotInvalid("transcript snapshot value must be an object") }
}

func snapshotInstructionRole(value: LlmWireInstructionRole): String {
    match (value) { case LlmWireInstructionRole.System => "system"; case LlmWireInstructionRole.Developer => "developer" }
}

func snapshotParseInstructionRole(value: String): LlmWireInstructionRole {
    match (value) {
        case "system" => LlmWireInstructionRole.System
        case "developer" => LlmWireInstructionRole.Developer
        case _ => snapshotInvalid("unknown instruction role")
    }
}

func snapshotMessageRole(value: LlmWireRole): String {
    match (value) { case LlmWireRole.User => "user"; case LlmWireRole.Assistant => "assistant" }
}

func snapshotParseMessageRole(value: String): LlmWireRole {
    match (value) {
        case "user" => LlmWireRole.User
        case "assistant" => LlmWireRole.Assistant
        case _ => snapshotInvalid("unknown message role")
    }
}

func snapshotVisibility(value: LlmWireToolVisibility): String {
    match (value) { case LlmWireToolVisibility.Active => "active"; case LlmWireToolVisibility.Deferred => "deferred" }
}

func snapshotParseVisibility(value: String): LlmWireToolVisibility {
    match (value) {
        case "active" => LlmWireToolVisibility.Active
        case "deferred" => LlmWireToolVisibility.Deferred
        case _ => snapshotInvalid("unknown tool visibility")
    }
}

func snapshotPhase(value: LlmWireOutputPhase): String {
    match (value) {
        case LlmWireOutputPhase.Unspecified => "unspecified"
        case LlmWireOutputPhase.Analysis => "analysis"
        case LlmWireOutputPhase.Commentary => "commentary"
        case LlmWireOutputPhase.Final => "final"
    }
}

func snapshotParsePhase(value: String): LlmWireOutputPhase {
    match (value) {
        case "unspecified" => LlmWireOutputPhase.Unspecified
        case "analysis" => LlmWireOutputPhase.Analysis
        case "commentary" => LlmWireOutputPhase.Commentary
        case "final" => LlmWireOutputPhase.Final
        case _ => snapshotInvalid("unknown text phase")
    }
}

func snapshotCitationKind(value: LlmWireCitationKind): String {
    match (value) {
        case LlmWireCitationKind.Url => "url"
        case LlmWireCitationKind.File => "file"
        case LlmWireCitationKind.CharacterRange => "character_range"
        case LlmWireCitationKind.PageRange => "page_range"
        case LlmWireCitationKind.ContentBlockRange => "content_block_range"
        case LlmWireCitationKind.WebSearchResult => "web_search_result"
        case LlmWireCitationKind.SearchResult => "search_result"
    }
}

func snapshotParseCitationKind(value: String): LlmWireCitationKind {
    match (value) {
        case "url" => LlmWireCitationKind.Url
        case "file" => LlmWireCitationKind.File
        case "character_range" => LlmWireCitationKind.CharacterRange
        case "page_range" => LlmWireCitationKind.PageRange
        case "content_block_range" => LlmWireCitationKind.ContentBlockRange
        case "web_search_result" => LlmWireCitationKind.WebSearchResult
        case "search_result" => LlmWireCitationKind.SearchResult
        case _ => snapshotInvalid("unknown citation kind")
    }
}

func snapshotImageSourceKind(value: LlmWireImageSourceKind): String {
    match (value) { case LlmWireImageSourceKind.Url => "url"; case LlmWireImageSourceKind.Base64 => "base64"; case LlmWireImageSourceKind.File => "file" }
}

func snapshotParseImageSourceKind(value: String): LlmWireImageSourceKind {
    match (value) {
        case "url" => LlmWireImageSourceKind.Url
        case "base64" => LlmWireImageSourceKind.Base64
        case "file" => LlmWireImageSourceKind.File
        case _ => snapshotInvalid("unknown image source kind")
    }
}

func snapshotImageDetail(value: LlmWireImageDetail): String {
    match (value) { case LlmWireImageDetail.Auto => "auto"; case LlmWireImageDetail.Low => "low"; case LlmWireImageDetail.High => "high" }
}

func snapshotParseImageDetail(value: String): LlmWireImageDetail {
    match (value) {
        case "auto" => LlmWireImageDetail.Auto
        case "low" => LlmWireImageDetail.Low
        case "high" => LlmWireImageDetail.High
        case _ => snapshotInvalid("unknown image detail")
    }
}

func snapshotCitation(value: LlmWireCitation): JsonNode {
    let fields = ArrayList<WireJsonField>()
    fields.add(WireJsonField("kind", wireJsonString(snapshotCitationKind(value.kind))))
    fields.add(WireJsonField("cited_text", wireJsonString(value.citedText)))
    match (value.documentIndex) { case Some(found) => fields.add(WireJsonField("document_index", wireJsonNumber(found.toString()))); case None => () }
    fields.add(WireJsonField("document_title", wireJsonString(value.documentTitle)))
    match (value.startIndex) { case Some(found) => fields.add(WireJsonField("start_index", wireJsonNumber(found.toString()))); case None => () }
    match (value.endIndex) { case Some(found) => fields.add(WireJsonField("end_index", wireJsonNumber(found.toString()))); case None => () }
    match (value.startPage) { case Some(found) => fields.add(WireJsonField("start_page", wireJsonNumber(found.toString()))); case None => () }
    match (value.endPage) { case Some(found) => fields.add(WireJsonField("end_page", wireJsonNumber(found.toString()))); case None => () }
    match (value.startBlock) { case Some(found) => fields.add(WireJsonField("start_block", wireJsonNumber(found.toString()))); case None => () }
    match (value.endBlock) { case Some(found) => fields.add(WireJsonField("end_block", wireJsonNumber(found.toString()))); case None => () }
    fields.add(WireJsonField("url", wireJsonString(value.url)))
    fields.add(WireJsonField("title", wireJsonString(value.title)))
    fields.add(WireJsonField("file_id", wireJsonString(value.fileId)))
    fields.add(WireJsonField("filename", wireJsonString(value.filename)))
    wireJsonObject(fields.toArray())
}

func snapshotAnnotation(value: LlmWireAnnotation): JsonNode {
    match (value) {
        case LlmWireAnnotation.UrlCitation(citation) => wireJsonObject([WireJsonField("type", wireJsonString("url_citation")), WireJsonField("citation", snapshotCitation(citation))])
        case LlmWireAnnotation.FileCitation(citation) => wireJsonObject([WireJsonField("type", wireJsonString("file_citation")), WireJsonField("citation", snapshotCitation(citation))])
    }
}

func snapshotBytes(values: Array<Int64>): JsonNode {
    let output = ArrayList<JsonNode>()
    for (value in values) { output.add(wireJsonNumber(value.toString())) }
    wireJsonArray(output.toArray())
}

func snapshotCandidate(value: LlmWireTokenLogprobCandidate): JsonNode {
    wireJsonObject([
        WireJsonField("token", wireJsonString(value.token)), WireJsonField("bytes", snapshotBytes(value.bytes)),
        WireJsonField("logprob", value.logprob.jsonNode())
    ])
}

func snapshotLogprob(value: LlmWireTokenLogprob): JsonNode {
    let top = ArrayList<JsonNode>()
    for (candidate in value.topLogprobs) { top.add(snapshotCandidate(candidate)) }
    wireJsonObject([
        WireJsonField("token", wireJsonString(value.token)), WireJsonField("bytes", snapshotBytes(value.bytes)),
        WireJsonField("logprob", value.logprob.jsonNode()), WireJsonField("top_logprobs", wireJsonArray(top.toArray()))
    ])
}

func snapshotText(value: LlmWireTextBlock): JsonNode {
    let citations = ArrayList<JsonNode>(); for (item in value.citations) { citations.add(snapshotCitation(item)) }
    let annotations = ArrayList<JsonNode>(); for (item in value.annotations) { annotations.add(snapshotAnnotation(item)) }
    let logprobs = ArrayList<JsonNode>(); for (item in value.logprobs) { logprobs.add(snapshotLogprob(item)) }
    wireJsonObject([
        WireJsonField("type", wireJsonString("text")), WireJsonField("text", wireJsonString(value.text)),
        WireJsonField("citations", wireJsonArray(citations.toArray())), WireJsonField("annotations", wireJsonArray(annotations.toArray())),
        WireJsonField("logprobs", wireJsonArray(logprobs.toArray())), WireJsonField("phase", wireJsonString(snapshotPhase(value.phase)))
    ])
}

func snapshotImage(value: LlmWireImageBlock): JsonNode {
    wireJsonObject([
        WireJsonField("type", wireJsonString("image")), WireJsonField("source_kind", wireJsonString(snapshotImageSourceKind(value.sourceKind))),
        WireJsonField("data", wireJsonString(value.data)), WireJsonField("media_type", wireJsonString(value.mediaType)),
        WireJsonField("detail", wireJsonString(snapshotImageDetail(value.detail)))
    ])
}

func snapshotToolResultContent(value: LlmWireToolResultContent): JsonNode {
    match (value) { case LlmWireToolResultContent.Text(text) => snapshotText(text); case LlmWireToolResultContent.Image(image) => snapshotImage(image) }
}

func snapshotBlock(value: LlmWireBlock, blockCount: ArrayList<Int64>): JsonNode {
    match (value) {
        case LlmWireBlock.Text(text) => snapshotText(text)
        case LlmWireBlock.Image(image) => snapshotImage(image)
        case LlmWireBlock.ToolCall(call) => match (call.arguments) {
            case LlmWireToolArguments.Complete(arguments) => wireJsonObject([
                WireJsonField("type", wireJsonString("tool_call")), WireJsonField("call_id", wireJsonString(call.callId)),
                WireJsonField("name", wireJsonString(call.name)), WireJsonField("arguments", arguments.jsonNode())
            ])
            case _ => snapshotInvalid("only complete tool arguments are snapshotable")
        }
        case LlmWireBlock.ToolResult(result) =>
            let content = ArrayList<JsonNode>(); for (part in result.content) {
                blockCount[0] = blockCount[0] + 1
                if (blockCount[0] > LLM_TRANSCRIPT_MAX_BLOCKS) { snapshotLimit("transcript block count exceeds the limit") }
                content.add(snapshotToolResultContent(part))
            }
            wireJsonObject([
                WireJsonField("type", wireJsonString("tool_result")), WireJsonField("call_id", wireJsonString(result.callId)),
                WireJsonField("content", wireJsonArray(content.toArray())), WireJsonField("is_error", wireJsonBool(result.isError))
            ])
        case LlmWireBlock.NativeReplay(value) =>
            if (value.completion != LlmWireOpaqueCompletion.Complete) { snapshotInvalid("partial native replay is not snapshotable") }
            wireJsonObject([WireJsonField("type", wireJsonString("native_replay")), WireJsonField("native_replay", parseWireJson(value.snapshot()))])
        case LlmWireBlock.Reasoning(_) | LlmWireBlock.Refusal(_) | LlmWireBlock.Opaque(_) => snapshotInvalid("display and opaque blocks are not snapshotable")
    }
}

func snapshotMessage(value: LlmWireMessage, blockCount: ArrayList<Int64>): JsonNode {
    let blocks = ArrayList<JsonNode>()
    for (block in value.blocks) {
        blockCount[0] = blockCount[0] + 1
        if (blockCount[0] > LLM_TRANSCRIPT_MAX_BLOCKS) { snapshotLimit("transcript block count exceeds the limit") }
        blocks.add(snapshotBlock(block, blockCount))
    }
    wireJsonObject([WireJsonField("role", wireJsonString(snapshotMessageRole(value.role))), WireJsonField("blocks", wireJsonArray(blocks.toArray()))])
}

func snapshotTool(value: LlmWireTool): JsonNode {
    wireJsonObject([
        WireJsonField("name", wireJsonString(value.name)), WireJsonField("version", wireJsonString(value.version)),
        WireJsonField("description", wireJsonString(value.description)), WireJsonField("input_schema", value.inputSchema.jsonNode())
    ])
}

func snapshotDefinition(value: LlmWireTool, toolCount: ArrayList<Int64>): JsonNode {
    toolCount[0] = toolCount[0] + 1
    if (toolCount[0] > LLM_TRANSCRIPT_MAX_TOOLS) { snapshotLimit("transcript tool definition count exceeds the limit") }
    snapshotTool(value)
}

func snapshotDeclaration(value: LlmWireToolDeclaration, toolCount: ArrayList<Int64>): JsonNode {
    wireJsonObject([WireJsonField("tool", snapshotDefinition(value.tool, toolCount)), WireJsonField("visibility", wireJsonString(snapshotVisibility(value.visibility)))])
}

func snapshotInstruction(value: LlmWireInstruction): JsonNode {
    wireJsonObject([WireJsonField("role", wireJsonString(snapshotInstructionRole(value.role))), WireJsonField("text", wireJsonString(value.text))])
}

func snapshotRef(value: LlmWireToolRef): JsonNode {
    wireJsonObject([WireJsonField("name", wireJsonString(value.name)), WireJsonField("version", wireJsonString(value.version))])
}

func snapshotItem(value: LlmWireInputItem, blockCount: ArrayList<Int64>, toolCount: ArrayList<Int64>): JsonNode {
    match (value) {
        case LlmWireInputItem.Message(message) => wireJsonObject([WireJsonField("type", wireJsonString("message")), WireJsonField("message", snapshotMessage(message, blockCount))])
        case LlmWireInputItem.InstructionUpdate(instruction) => wireJsonObject([WireJsonField("type", wireJsonString("instruction_update")), WireJsonField("instruction", snapshotInstruction(instruction))])
        case LlmWireInputItem.ToolDeclaration(declaration) => wireJsonObject([WireJsonField("type", wireJsonString("tool_declaration")), WireJsonField("declaration", snapshotDeclaration(declaration, toolCount))])
        case LlmWireInputItem.ToolActivation(ref) => wireJsonObject([WireJsonField("type", wireJsonString("tool_activation")), WireJsonField("reference", snapshotRef(ref))])
        case LlmWireInputItem.ToolDeactivation(ref) => wireJsonObject([WireJsonField("type", wireJsonString("tool_deactivation")), WireJsonField("reference", snapshotRef(ref))])
        case LlmWireInputItem.ToolReplacement(previous, replacement) => wireJsonObject([
            WireJsonField("type", wireJsonString("tool_replacement")),
            WireJsonField("previous", snapshotRef(previous)), WireJsonField("replacement", snapshotDefinition(replacement, toolCount))
        ])
    }
}

func snapshotTranscript(transcript: LlmWireTranscript): LlmWireResult<String> {
    try {
        if (transcript.items.size > LLM_TRANSCRIPT_MAX_ITEMS) { snapshotLimit("transcript item count exceeds the limit") }
        validateTranscript(transcript)
        let blockCount = ArrayList<Int64>(); blockCount.add(0)
        let toolCount = ArrayList<Int64>(); toolCount.add(0)
        let instructions = ArrayList<JsonNode>(); for (instruction in transcript.initialContext.instructions) { instructions.add(snapshotInstruction(instruction)) }
        let tools = ArrayList<JsonNode>()
        for (declaration in transcript.initialContext.tools) {
            tools.add(snapshotDeclaration(declaration, toolCount))
        }
        let items = ArrayList<JsonNode>()
        if (transcript.items.size > LLM_TRANSCRIPT_MAX_ITEMS) { snapshotLimit("transcript item count exceeds the limit") }
        for (item in transcript.items) { items.add(snapshotItem(item, blockCount, toolCount)) }
        let initial = wireJsonObject([WireJsonField("instructions", wireJsonArray(instructions.toArray())), WireJsonField("tools", wireJsonArray(tools.toArray()))])
        let root = wireJsonObject([
            WireJsonField("format", wireJsonString("llm4cj.transcript")), WireJsonField("version", wireJsonNumber("1")),
            WireJsonField("initial_context", initial), WireJsonField("items", wireJsonArray(items.toArray()))
        ])
        let source = root.stringify(); snapshotCheckBytes(source); LlmWireResult.Ok(source)
    } catch (error: LlmWireError) { LlmWireResult.Err(error) }
}

func restoreCitation(value: JsonNode): LlmWireCitation {
    snapshotCheckFields(value, ["kind", "cited_text", "document_index", "document_title", "start_index", "end_index", "start_page", "end_page", "start_block", "end_block", "url", "title", "file_id", "filename"])
    LlmWireCitation(
        snapshotParseCitationKind(wireRequiredString(value, "kind")), citedText: wireRequiredString(value, "cited_text"),
        documentIndex: wireOptionalInt(value, "document_index"), documentTitle: wireRequiredString(value, "document_title"),
        startIndex: wireOptionalInt(value, "start_index"), endIndex: wireOptionalInt(value, "end_index"),
        startPage: wireOptionalInt(value, "start_page"), endPage: wireOptionalInt(value, "end_page"),
        startBlock: wireOptionalInt(value, "start_block"), endBlock: wireOptionalInt(value, "end_block"),
        url: wireRequiredString(value, "url"), title: wireRequiredString(value, "title"),
        fileId: wireRequiredString(value, "file_id"), filename: wireRequiredString(value, "filename")
    )
}

func restoreAnnotation(value: JsonNode): LlmWireAnnotation {
    snapshotCheckFields(value, ["type", "citation"])
    let citation = restoreCitation(snapshotRequiredObject(value, "citation"))
    match (wireRequiredString(value, "type")) {
        case "url_citation" => LlmWireAnnotation.UrlCitation(citation)
        case "file_citation" => LlmWireAnnotation.FileCitation(citation)
        case _ => snapshotInvalid("unknown annotation type")
    }
}

func restoreBytes(value: JsonNode): Array<Int64> {
    if (value.wireKind != WireJsonKind.List) { snapshotInvalid("logprob bytes must be an array") }
    let output = ArrayList<Int64>(); for (entry in value.items) {
        if (entry.wireKind != WireJsonKind.Number) { snapshotInvalid("logprob bytes must contain integers") }
        try { output.add(Int64.parse(entry.numberText)) } catch (_: Exception) { snapshotInvalid("logprob byte is invalid") }
    }; output.toArray()
}

func restoreCandidate(value: JsonNode): LlmWireTokenLogprobCandidate {
    snapshotCheckFields(value, ["token", "bytes", "logprob"])
    LlmWireTokenLogprobCandidate(wireRequiredString(value, "token"), LlmWireJson.fromJsonNode(wireRequiredField(value, "logprob")), bytes: restoreBytes(wireRequiredField(value, "bytes")))
}

func restoreLogprob(value: JsonNode): LlmWireTokenLogprob {
    snapshotCheckFields(value, ["token", "bytes", "logprob", "top_logprobs"])
    let top = ArrayList<LlmWireTokenLogprobCandidate>(); for (entry in snapshotRequiredArray(value, "top_logprobs")) { top.add(restoreCandidate(entry)) }
    LlmWireTokenLogprob(wireRequiredString(value, "token"), LlmWireJson.fromJsonNode(wireRequiredField(value, "logprob")), bytes: restoreBytes(wireRequiredField(value, "bytes")), topLogprobs: top.toArray())
}

func restoreText(value: JsonNode): LlmWireTextBlock {
    snapshotCheckFields(value, ["type", "text", "citations", "annotations", "logprobs", "phase"])
    if (wireRequiredString(value, "type") != "text") { snapshotInvalid("text block type is invalid") }
    let citations = ArrayList<LlmWireCitation>(); for (entry in snapshotRequiredArray(value, "citations")) { citations.add(restoreCitation(entry)) }
    let annotations = ArrayList<LlmWireAnnotation>(); for (entry in snapshotRequiredArray(value, "annotations")) { annotations.add(restoreAnnotation(entry)) }
    let logprobs = ArrayList<LlmWireTokenLogprob>(); for (entry in snapshotRequiredArray(value, "logprobs")) { logprobs.add(restoreLogprob(entry)) }
    LlmWireTextBlock(wireRequiredString(value, "text"), citations: citations.toArray(), annotations: annotations.toArray(), logprobs: logprobs.toArray(), phase: snapshotParsePhase(wireRequiredString(value, "phase")))
}

func restoreImage(value: JsonNode): LlmWireImageBlock {
    snapshotCheckFields(value, ["type", "source_kind", "data", "media_type", "detail"])
    if (wireRequiredString(value, "type") != "image") { snapshotInvalid("image block type is invalid") }
    LlmWireImageBlock(snapshotParseImageSourceKind(wireRequiredString(value, "source_kind")), wireRequiredString(value, "data"), mediaType: wireRequiredString(value, "media_type"), detail: snapshotParseImageDetail(wireRequiredString(value, "detail")))
}

func restoreBlock(value: JsonNode, blockCount: ArrayList<Int64>): LlmWireBlock {
    snapshotRequireObject(value)
    blockCount[0] = blockCount[0] + 1
    if (blockCount[0] > LLM_TRANSCRIPT_MAX_BLOCKS) { snapshotLimit("transcript block count exceeds the limit") }
    let kind = wireRequiredString(value, "type")
    match (kind) {
        case "text" => LlmWireBlock.Text(restoreText(value))
        case "image" => LlmWireBlock.Image(restoreImage(value))
        case "tool_call" =>
            snapshotCheckFields(value, ["type", "call_id", "name", "arguments"])
            let arguments = snapshotRequiredObject(value, "arguments")
            LlmWireBlock.ToolCall(LlmWireToolCallBlock(wireRequiredString(value, "call_id"), wireRequiredString(value, "name"), LlmWireToolArguments.Complete(LlmWireJson.fromJsonNode(arguments))))
        case "tool_result" =>
            snapshotCheckFields(value, ["type", "call_id", "content", "is_error"])
            let content = ArrayList<LlmWireToolResultContent>()
            for (entry in snapshotRequiredArray(value, "content")) {
                blockCount[0] = blockCount[0] + 1
                if (blockCount[0] > LLM_TRANSCRIPT_MAX_BLOCKS) { snapshotLimit("transcript block count exceeds the limit") }
                snapshotRequireObject(entry)
                match (wireRequiredString(entry, "type")) { case "text" => content.add(LlmWireToolResultContent.Text(restoreText(entry))); case "image" => content.add(LlmWireToolResultContent.Image(restoreImage(entry))); case _ => snapshotInvalid("tool result content block is invalid") }
            }
            let error = wireRequiredField(value, "is_error"); if (error.wireKind != WireJsonKind.Boolean) { snapshotInvalid("tool result is_error must be boolean") }
            LlmWireBlock.ToolResult(LlmWireToolResultBlock(wireRequiredString(value, "call_id"), content.toArray(), isError: error.bool))
        case "native_replay" =>
            snapshotCheckFields(value, ["type", "native_replay"])
            LlmWireBlock.NativeReplay(LlmWireNativeReplayBlock.restore(snapshotRequiredObject(value, "native_replay").stringify()))
        case _ => snapshotInvalid("snapshot block tag is not replayable")
    }
}

func restoreMessage(value: JsonNode, blockCount: ArrayList<Int64>): LlmWireMessage {
    snapshotCheckFields(value, ["role", "blocks"])
    let blocks = ArrayList<LlmWireBlock>(); for (entry in snapshotRequiredArray(value, "blocks")) { blocks.add(restoreBlock(entry, blockCount)) }
    LlmWireMessage(snapshotParseMessageRole(wireRequiredString(value, "role")), blocks.toArray())
}

func restoreTool(value: JsonNode): LlmWireTool {
    snapshotCheckFields(value, ["name", "version", "description", "input_schema"])
    LlmWireTool(wireRequiredString(value, "name"), wireRequiredString(value, "version"), wireRequiredString(value, "description"), LlmWireJson.fromJsonNode(snapshotRequiredObject(value, "input_schema")))
}

func restoreDefinition(value: JsonNode, toolCount: ArrayList<Int64>): LlmWireTool {
    toolCount[0] = toolCount[0] + 1
    if (toolCount[0] > LLM_TRANSCRIPT_MAX_TOOLS) { snapshotLimit("transcript tool definition count exceeds the limit") }
    restoreTool(value)
}

func restoreDeclaration(value: JsonNode, toolCount: ArrayList<Int64>): LlmWireToolDeclaration {
    snapshotCheckFields(value, ["tool", "visibility"])
    LlmWireToolDeclaration(restoreDefinition(snapshotRequiredObject(value, "tool"), toolCount), visibility: snapshotParseVisibility(wireRequiredString(value, "visibility")))
}

func restoreInstruction(value: JsonNode): LlmWireInstruction {
    snapshotCheckFields(value, ["role", "text"])
    LlmWireInstruction(snapshotParseInstructionRole(wireRequiredString(value, "role")), wireRequiredString(value, "text"))
}

func restoreRef(value: JsonNode): LlmWireToolRef {
    snapshotCheckFields(value, ["name", "version"])
    LlmWireToolRef(wireRequiredString(value, "name"), wireRequiredString(value, "version"))
}

func restoreItem(value: JsonNode, blockCount: ArrayList<Int64>, toolCount: ArrayList<Int64>): LlmWireInputItem {
    snapshotRequireObject(value)
    let kind = wireRequiredString(value, "type")
    match (kind) {
        case "message" => snapshotCheckFields(value, ["type", "message"]); LlmWireInputItem.Message(restoreMessage(snapshotRequiredObject(value, "message"), blockCount))
        case "instruction_update" => snapshotCheckFields(value, ["type", "instruction"]); LlmWireInputItem.InstructionUpdate(restoreInstruction(snapshotRequiredObject(value, "instruction")))
        case "tool_declaration" => snapshotCheckFields(value, ["type", "declaration"]); LlmWireInputItem.ToolDeclaration(restoreDeclaration(snapshotRequiredObject(value, "declaration"), toolCount))
        case "tool_activation" => snapshotCheckFields(value, ["type", "reference"]); LlmWireInputItem.ToolActivation(restoreRef(snapshotRequiredObject(value, "reference")))
        case "tool_deactivation" => snapshotCheckFields(value, ["type", "reference"]); LlmWireInputItem.ToolDeactivation(restoreRef(snapshotRequiredObject(value, "reference")))
        case "tool_replacement" => snapshotCheckFields(value, ["type", "previous", "replacement"]); LlmWireInputItem.ToolReplacement(restoreRef(snapshotRequiredObject(value, "previous")), restoreDefinition(snapshotRequiredObject(value, "replacement"), toolCount))
        case _ => snapshotInvalid("unknown transcript item tag")
    }
}

func restoreTranscript(source: String): LlmWireResult<LlmWireTranscript> {
    try {
        snapshotCheckBytes(source)
        let parsed = parseWireJson(source)
        if (parsed.wireKind != WireJsonKind.Object) { snapshotInvalid("transcript snapshot root must be an object") }
        let root = parsed
        snapshotCheckFields(root, ["format", "version", "initial_context", "items"])
        if (wireRequiredString(root, "format") != "llm4cj.transcript") { snapshotInvalid("transcript snapshot format is invalid") }
        if (wireRequiredInt(root, "version") != 1) { throw LlmWireError(LlmWireErrorKind.Unsupported, "llm.transcript_version_unsupported", "only transcript snapshot version 1 is supported") }
        let context = snapshotRequiredObject(root, "initial_context")
        snapshotCheckFields(context, ["instructions", "tools"])
        let instructions = ArrayList<LlmWireInstruction>(); for (entry in snapshotRequiredArray(context, "instructions")) { instructions.add(restoreInstruction(entry)) }
        let toolCount = ArrayList<Int64>(); toolCount.add(0)
        let declarations = ArrayList<LlmWireToolDeclaration>(); for (entry in snapshotRequiredArray(context, "tools")) { declarations.add(restoreDeclaration(entry, toolCount)) }
        let rawItems = snapshotRequiredArray(root, "items")
        if (rawItems.size > LLM_TRANSCRIPT_MAX_ITEMS) { snapshotLimit("transcript item count exceeds the limit") }
        let blockCount = ArrayList<Int64>(); blockCount.add(0)
        let items = ArrayList<LlmWireInputItem>(); for (entry in rawItems) { items.add(restoreItem(entry, blockCount, toolCount)) }
        let transcript = LlmWireTranscript(LlmWireInitialContext(instructions: instructions.toArray(), tools: declarations.toArray()), items: items.toArray())
        validateTranscript(transcript)
        LlmWireResult.Ok(transcript)
    } catch (error: LlmWireError) { LlmWireResult.Err(error) }
}
