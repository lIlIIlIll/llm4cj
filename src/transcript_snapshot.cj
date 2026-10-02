package llm4cj

import std.collection.*
import std.io.*
import yjson.*

func transcriptSnapshotLimit(): LlmWireError {
    LlmWireError(LlmWireErrorKind.LimitExceeded, "llm.transcript_snapshot_limit_exceeded",
        "transcript snapshots must fit 8388608 bytes and 256 nesting levels")
}

class TranscriptSnapshotOutput <: OutputStream {
    private let bytes = ArrayList<Byte>()
    public func write(chunk: Array<Byte>): Unit {
        if (chunk.size > LLM_JSON_MAX_BYTES - bytes.size) { throw transcriptSnapshotLimit() }
        bytes.add(all: chunk)
    }
    public func flush(): Unit {}
    func finish(): String { String.fromUtf8(bytes.toArray()) }
}

func writeTranscriptSnapshot(transcript: LlmWireTranscript): String {
    try {
        // The streaming writer enforces each append before allocating or
        // committing output; its private sink independently guards retention.
        let output = TranscriptSnapshotOutput()
        encodeTranscriptSnapshot(transcript).writeJson(output, options: JsonWriteOptions(
            maxOutputBytes: LLM_JSON_MAX_BYTES, maxDepth: LLM_JSON_MAX_DEPTH))
        output.finish()
    } catch (error: JsonException) {
        if (error.code == "output_too_large" || error.code == "max_depth") { throw transcriptSnapshotLimit() }
        snapshotInvalid("transcript could not be serialized")
    }
}

func readTranscriptSnapshot(source: String): JsonNode {
    // String.size counts UTF-8 bytes and does not allocate a second copy merely
    // to reject an oversized persisted document.
    if (source.size > LLM_JSON_MAX_BYTES) { throw transcriptSnapshotLimit() }
    try {
        JsonNode.parse(source, config: JsonReadOptions(
            unknownFieldPolicy: JsonUnknownFieldPolicy.Ignore, duplicateKeyPolicy: JsonDuplicateKeyPolicy.Reject,
            maxDepth: LLM_JSON_MAX_DEPTH, maxStringBytes: LLM_JSON_MAX_STRING_BYTES,
            maxInputBytes: LLM_JSON_MAX_BYTES, maxBufferedValueBytes: LLM_JSON_MAX_BYTES))
    } catch (error: JsonException) {
        if (error.code == "max_depth") { throw transcriptSnapshotLimit() }
        snapshotInvalid("transcript snapshot contains invalid JSON")
    }
}

// This is the first transcript format. It deliberately does not read legacy
// separated requests or infer a version from fields that happen to be present.
func encodeTranscriptSnapshot(transcript: LlmWireTranscript): JsonNode {
    let instructions = ArrayList<JsonNode>()
    let tools = ArrayList<JsonNode>()
    let items = ArrayList<JsonNode>()
    for (instruction in transcript.initialContext.instructions) { instructions.add(snapshotInstruction(instruction)) }
    for (tool in transcript.initialContext.tools) { tools.add(snapshotDeclaration(tool)) }
    for (item in transcript.items) { items.add(snapshotItem(item)) }
    wireJsonObject([
        WireJsonField("format", wireJsonString("llm4cj.transcript")),
        WireJsonField("version", wireJsonNumber("1")),
        WireJsonField("initial_context", wireJsonObject([
            WireJsonField("instructions", wireJsonArray(instructions.toArray())),
            WireJsonField("tools", wireJsonArray(tools.toArray()))
        ])),
        WireJsonField("items", wireJsonArray(items.toArray()))
    ])
}

func decodeTranscriptSnapshot(value: JsonNode): LlmWireTranscript {
    let root = wireObject(value, "transcript snapshot")
    let version = wireOptionalInt(root, "version")
    if (version != Some(1)) {
        throw LlmWireError(LlmWireErrorKind.Unsupported, "llm.transcript_version_unsupported", "only transcript snapshot version 1 is supported")
    }
    if (wireOptionalString(root, "format") != Some("llm4cj.transcript")) {
        throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.transcript_snapshot_invalid", "unknown transcript snapshot format")
    }
    snapshotFields(root, ["format", "version", "initial_context", "items"])
    let context = wireObject(wireRequiredField(root, "initial_context"), "initial context")
    snapshotFields(context, ["instructions", "tools"])
    let instructions = ArrayList<LlmWireInstruction>()
    let tools = ArrayList<LlmWireToolDeclaration>()
    let items = ArrayList<LlmWireInputItem>()
    for (entry in snapshotArray(context, "instructions")) { instructions.add(restoreInstruction(entry)) }
    for (entry in snapshotArray(context, "tools")) { tools.add(restoreDeclaration(entry)) }
    for (entry in snapshotArray(root, "items")) { items.add(restoreItem(entry)) }
    LlmWireTranscript(LlmWireInitialContext(instructions: instructions.toArray(), tools: tools.toArray()), items: items.toArray())
}

func snapshotFields(value: JsonNode, allowed: Array<String>): Unit {
    let _ = wireObject(value, "transcript snapshot object")
    for (field in value.fields) {
        var known = false
        for (name in allowed where field.name == name) { known = true }
        if (!known) { snapshotInvalid("unknown transcript snapshot field") }
    }
}

func snapshotInvalid(message: String): Nothing {
    throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.transcript_snapshot_invalid", message)
}

func snapshotArray(value: JsonNode, name: String): Array<JsonNode> {
    let field = wireRequiredField(value, name)
    if (field.wireKind != WireJsonKind.List) { snapshotInvalid("transcript snapshot array expected") }
    field.items
}

func snapshotBool(value: JsonNode, name: String): Bool {
    let field = wireRequiredField(value, name)
    if (field.wireKind != WireJsonKind.Boolean) { snapshotInvalid("transcript snapshot boolean expected") }
    field.bool
}

func snapshotInstruction(value: LlmWireInstruction): JsonNode {
    wireJsonObject([
        WireJsonField("role", wireJsonString(if (value.role == LlmWireInstructionRole.System) { "system" } else { "developer" })),
        WireJsonField("text", wireJsonString(value.text))
    ])
}

func restoreInstruction(value: JsonNode): LlmWireInstruction {
    snapshotFields(value, ["role", "text"])
    let role = match (wireRequiredString(value, "role")) {
        case "system" => LlmWireInstructionRole.System
        case "developer" => LlmWireInstructionRole.Developer
        case _ => snapshotInvalid("unknown instruction role in transcript snapshot")
    }
    LlmWireInstruction(role, wireRequiredString(value, "text"))
}

func snapshotDeclaration(value: LlmWireToolDeclaration): JsonNode {
    wireJsonObject([
        WireJsonField("name", wireJsonString(value.tool.name)), WireJsonField("version", wireJsonString(value.version)),
        WireJsonField("description", wireJsonString(value.tool.description)), WireJsonField("schema", value.tool.inputSchema.jsonNode()),
        WireJsonField("deferred", wireJsonBool(value.deferred))
    ])
}

func restoreDeclaration(value: JsonNode): LlmWireToolDeclaration {
    snapshotFields(value, ["name", "version", "description", "schema", "deferred"])
    let tool = LlmWireTool(wireRequiredString(value, "name"), wireRequiredString(value, "description"),
        LlmWireJson.fromJsonNode(wireRequiredField(value, "schema")))
    LlmWireToolDeclaration(tool, version: wireRequiredString(value, "version"), deferred: snapshotBool(value, "deferred"))
}

func snapshotDefinitionIdentity(value: LlmWireToolDefinitionIdentity): JsonNode {
    wireJsonObject([WireJsonField("name", wireJsonString(value.name)), WireJsonField("version", wireJsonString(value.version))])
}

func restoreDefinitionIdentity(value: JsonNode): LlmWireToolDefinitionIdentity {
    snapshotFields(value, ["name", "version"])
    LlmWireToolDefinitionIdentity(wireRequiredString(value, "name"), version: wireRequiredString(value, "version"))
}

func snapshotItem(item: LlmWireInputItem): JsonNode {
    let (kind, value) = match (item) {
        case LlmWireInputItem.Message(message) => ("message", snapshotMessage(message))
        case LlmWireInputItem.InstructionUpdate(instruction) => ("instruction_update", snapshotInstruction(instruction))
        case LlmWireInputItem.ToolDeclaration(declaration) => ("tool_declaration", snapshotDeclaration(declaration))
        case LlmWireInputItem.ToolActivation(identity) => ("tool_activation", snapshotDefinitionIdentity(identity))
        case LlmWireInputItem.ToolDeactivation(identity) => ("tool_deactivation", snapshotDefinitionIdentity(identity))
    }
    wireJsonObject([WireJsonField("kind", wireJsonString(kind)), WireJsonField("value", value)])
}

func restoreItem(item: JsonNode): LlmWireInputItem {
    snapshotFields(item, ["kind", "value"])
    let value = wireRequiredField(item, "value")
    match (wireRequiredString(item, "kind")) {
        case "message" => LlmWireInputItem.Message(restoreMessage(value))
        case "instruction_update" => LlmWireInputItem.InstructionUpdate(restoreInstruction(value))
        case "tool_declaration" => LlmWireInputItem.ToolDeclaration(restoreDeclaration(value))
        case "tool_activation" => LlmWireInputItem.ToolActivation(restoreDefinitionIdentity(value))
        case "tool_deactivation" => LlmWireInputItem.ToolDeactivation(restoreDefinitionIdentity(value))
        case _ => snapshotInvalid("unknown input item kind in transcript snapshot")
    }
}

func snapshotMessage(value: LlmWireMessage): JsonNode {
    let blocks = ArrayList<JsonNode>()
    for (block in value.blocks) { blocks.add(snapshotBlock(block)) }
    wireJsonObject([
        WireJsonField("role", wireJsonString(if (value.role == LlmWireRole.User) { "user" } else { "assistant" })),
        WireJsonField("blocks", wireJsonArray(blocks.toArray()))
    ])
}

func restoreMessage(value: JsonNode): LlmWireMessage {
    snapshotFields(value, ["role", "blocks"])
    let role = match (wireRequiredString(value, "role")) {
        case "user" => LlmWireRole.User
        case "assistant" => LlmWireRole.Assistant
        case _ => snapshotInvalid("unknown message role in transcript snapshot")
    }
    let blocks = ArrayList<LlmWireBlock>()
    for (block in snapshotArray(value, "blocks")) { blocks.add(restoreBlock(block)) }
    LlmWireMessage(role, blocks.toArray())
}

func snapshotBlock(block: LlmWireBlock): JsonNode {
    let (kind, value) = match (block) {
        case LlmWireBlock.Text(text) => ("text", snapshotText(text))
        case LlmWireBlock.Image(image) => ("image", snapshotImage(image))
        case LlmWireBlock.Reasoning(reasoning) => ("reasoning", wireJsonObject([
            WireJsonField("text", wireJsonString(reasoning.text)), WireJsonField("replay_dialect_id", wireJsonString(reasoning.replayDialectId))
        ]))
        case LlmWireBlock.ToolCall(call) => ("tool_call", wireJsonObject([
            WireJsonField("call_id", wireJsonString(call.callId)), WireJsonField("name", wireJsonString(call.name)),
            WireJsonField("arguments", snapshotArguments(call.arguments))
        ]))
        case LlmWireBlock.ToolResult(result) => ("tool_result", snapshotToolResult(result))
        case LlmWireBlock.Refusal(refusal) => ("refusal", snapshotRefusal(refusal))
        case LlmWireBlock.NativeReplay(replay) => ("native_replay", parseWireJson(replay.snapshot()))
        case LlmWireBlock.Opaque(opaque) => ("opaque", wireJsonObject([
            WireJsonField("native_type", wireJsonString(opaque.nativeType)),
            WireJsonField("complete", wireJsonBool(opaque.completion == LlmWireOpaqueCompletion.Complete)),
            WireJsonField("payload", opaque.payload())
        ]))
    }
    wireJsonObject([WireJsonField("kind", wireJsonString(kind)), WireJsonField("value", value)])
}

func restoreBlock(block: JsonNode): LlmWireBlock {
    snapshotFields(block, ["kind", "value"])
    let value = wireRequiredField(block, "value")
    match (wireRequiredString(block, "kind")) {
        case "text" => LlmWireBlock.Text(restoreText(value))
        case "image" => LlmWireBlock.Image(restoreImage(value))
        case "reasoning" =>
            snapshotFields(value, ["text", "replay_dialect_id"])
            LlmWireBlock.Reasoning(LlmWireReasoningBlock(wireRequiredString(value, "text"), replayDialectId: wireRequiredString(value, "replay_dialect_id")))
        case "tool_call" =>
            snapshotFields(value, ["call_id", "name", "arguments"])
            LlmWireBlock.ToolCall(LlmWireToolCallBlock(wireRequiredString(value, "call_id"), wireRequiredString(value, "name"), restoreArguments(wireRequiredField(value, "arguments"))))
        case "tool_result" => LlmWireBlock.ToolResult(restoreToolResult(value))
        case "refusal" => LlmWireBlock.Refusal(restoreRefusal(value))
        case "native_replay" => LlmWireBlock.NativeReplay(restoreTranscriptReplay(value))
        case "opaque" =>
            snapshotFields(value, ["native_type", "complete", "payload"])
            LlmWireBlock.Opaque(LlmWireOpaqueBlock(wireRequiredString(value, "native_type"), wireRequiredField(value, "payload"),
                completion: if (snapshotBool(value, "complete")) { LlmWireOpaqueCompletion.Complete } else { LlmWireOpaqueCompletion.Partial }))
        case _ => snapshotInvalid("unknown block kind in transcript snapshot")
    }
}

func snapshotArguments(value: LlmWireToolArguments): JsonNode {
    let (kind, payload) = match (value) {
        case LlmWireToolArguments.Complete(json) => ("complete", json.jsonNode())
        case LlmWireToolArguments.InvalidJson(text) => ("invalid_json", wireJsonString(text))
        case LlmWireToolArguments.InvalidShape(json) => ("invalid_shape", json.jsonNode())
        case LlmWireToolArguments.Partial(text) => ("partial", wireJsonString(text))
    }
    wireJsonObject([WireJsonField("kind", wireJsonString(kind)), WireJsonField("value", payload)])
}

func restoreArguments(value: JsonNode): LlmWireToolArguments {
    snapshotFields(value, ["kind", "value"])
    let payload = wireRequiredField(value, "value")
    match (wireRequiredString(value, "kind")) {
        case "complete" => LlmWireToolArguments.Complete(LlmWireJson.fromJsonNode(payload))
        case "invalid_shape" => LlmWireToolArguments.InvalidShape(LlmWireJson.fromJsonNode(payload))
        case "invalid_json" => LlmWireToolArguments.InvalidJson(wireRequiredString(value, "value"))
        case "partial" => LlmWireToolArguments.Partial(wireRequiredString(value, "value"))
        case _ => snapshotInvalid("unknown tool argument kind in transcript snapshot")
    }
}

func snapshotImage(value: LlmWireImageBlock): JsonNode {
    let source = match (value.sourceKind) { case LlmWireImageSourceKind.Url => "url"; case LlmWireImageSourceKind.Base64 => "base64"; case LlmWireImageSourceKind.File => "file" }
    let detail = match (value.detail) { case LlmWireImageDetail.Auto => "auto"; case LlmWireImageDetail.Low => "low"; case LlmWireImageDetail.High => "high" }
    wireJsonObject([WireJsonField("source", wireJsonString(source)), WireJsonField("data", wireJsonString(value.data)),
        WireJsonField("media_type", wireJsonString(value.mediaType)), WireJsonField("detail", wireJsonString(detail))])
}

func restoreImage(value: JsonNode): LlmWireImageBlock {
    snapshotFields(value, ["source", "data", "media_type", "detail"])
    let source = match (wireRequiredString(value, "source")) {
        case "url" => LlmWireImageSourceKind.Url; case "base64" => LlmWireImageSourceKind.Base64; case "file" => LlmWireImageSourceKind.File
        case _ => snapshotInvalid("unknown image source in transcript snapshot")
    }
    let detail = match (wireRequiredString(value, "detail")) {
        case "auto" => LlmWireImageDetail.Auto; case "low" => LlmWireImageDetail.Low; case "high" => LlmWireImageDetail.High
        case _ => snapshotInvalid("unknown image detail in transcript snapshot")
    }
    LlmWireImageBlock(source, wireRequiredString(value, "data"), mediaType: wireRequiredString(value, "media_type"), detail: detail)
}

func snapshotToolResult(value: LlmWireToolResultBlock): JsonNode {
    let content = ArrayList<JsonNode>()
    for (part in value.content) {
        match (part) {
            case LlmWireToolResultContent.Text(text) => content.add(snapshotBlock(LlmWireBlock.Text(text)))
            case LlmWireToolResultContent.Image(image) => content.add(snapshotBlock(LlmWireBlock.Image(image)))
        }
    }
    wireJsonObject([WireJsonField("call_id", wireJsonString(value.callId)), WireJsonField("content", wireJsonArray(content.toArray())), WireJsonField("is_error", wireJsonBool(value.isError))])
}

func restoreToolResult(value: JsonNode): LlmWireToolResultBlock {
    snapshotFields(value, ["call_id", "content", "is_error"])
    let content = ArrayList<LlmWireToolResultContent>()
    for (part in snapshotArray(value, "content")) {
        match (restoreBlock(part)) {
            case LlmWireBlock.Text(text) => content.add(LlmWireToolResultContent.Text(text))
            case LlmWireBlock.Image(image) => content.add(LlmWireToolResultContent.Image(image))
            case _ => snapshotInvalid("tool result contains invalid content kind in transcript snapshot")
        }
    }
    LlmWireToolResultBlock(wireRequiredString(value, "call_id"), content.toArray(), isError: snapshotBool(value, "is_error"))
}

func snapshotOptionalText(value: ?String): JsonNode { match (value) { case Some(text) => wireJsonString(text); case None => JsonNode.nullValue } }
func snapshotOptionalInt(value: ?Int64): JsonNode { match (value) { case Some(number) => wireJsonNumber(number.toString()); case None => JsonNode.nullValue } }

func snapshotRefusal(value: LlmWireRefusalBlock): JsonNode {
    wireJsonObject([WireJsonField("text", wireJsonString(value.text)), WireJsonField("category", snapshotOptionalText(value.category)),
        WireJsonField("explanation", snapshotOptionalText(value.explanation)), WireJsonField("logprobs", snapshotLogprobs(value.logprobs))])
}

func restoreRefusal(value: JsonNode): LlmWireRefusalBlock {
    snapshotFields(value, ["text", "category", "explanation", "logprobs"])
    LlmWireRefusalBlock(wireRequiredString(value, "text"), category: wireOptionalString(value, "category"), explanation: wireOptionalString(value, "explanation"),
        logprobs: restoreLogprobs(wireRequiredField(value, "logprobs")))
}

func snapshotText(value: LlmWireTextBlock): JsonNode {
    let citations = ArrayList<JsonNode>()
    let annotations = ArrayList<JsonNode>()
    for (citation in value.citations) { citations.add(snapshotCitation(citation)) }
    for (annotation in value.annotations) {
        let (kind, citation) = match (annotation) {
            case LlmWireAnnotation.UrlCitation(data) => ("url", data)
            case LlmWireAnnotation.FileCitation(data) => ("file", data)
        }
        annotations.add(wireJsonObject([WireJsonField("kind", wireJsonString(kind)), WireJsonField("citation", snapshotCitation(citation))]))
    }
    let phase = match (value.phase) {
        case LlmWireOutputPhase.Unspecified => "unspecified"; case LlmWireOutputPhase.Analysis => "analysis"
        case LlmWireOutputPhase.Commentary => "commentary"; case LlmWireOutputPhase.Final => "final"
    }
    wireJsonObject([WireJsonField("text", wireJsonString(value.text)), WireJsonField("citations", wireJsonArray(citations.toArray())),
        WireJsonField("annotations", wireJsonArray(annotations.toArray())), WireJsonField("logprobs", snapshotLogprobs(value.logprobs)), WireJsonField("phase", wireJsonString(phase))])
}

func restoreText(value: JsonNode): LlmWireTextBlock {
    snapshotFields(value, ["text", "citations", "annotations", "logprobs", "phase"])
    let citations = ArrayList<LlmWireCitation>()
    let annotations = ArrayList<LlmWireAnnotation>()
    for (citation in snapshotArray(value, "citations")) { citations.add(restoreCitation(citation)) }
    for (annotation in snapshotArray(value, "annotations")) {
        snapshotFields(annotation, ["kind", "citation"])
        let citation = restoreCitation(wireRequiredField(annotation, "citation"))
        match (wireRequiredString(annotation, "kind")) {
            case "url" => annotations.add(LlmWireAnnotation.UrlCitation(citation))
            case "file" => annotations.add(LlmWireAnnotation.FileCitation(citation))
            case _ => snapshotInvalid("unknown annotation kind in transcript snapshot")
        }
    }
    let phase = match (wireRequiredString(value, "phase")) {
        case "unspecified" => LlmWireOutputPhase.Unspecified; case "analysis" => LlmWireOutputPhase.Analysis
        case "commentary" => LlmWireOutputPhase.Commentary; case "final" => LlmWireOutputPhase.Final
        case _ => snapshotInvalid("unknown text phase in transcript snapshot")
    }
    LlmWireTextBlock(wireRequiredString(value, "text"), citations: citations.toArray(), annotations: annotations.toArray(),
        logprobs: restoreLogprobs(wireRequiredField(value, "logprobs")), phase: phase)
}

func snapshotCitation(value: LlmWireCitation): JsonNode {
    let kind = match (value.kind) {
        case LlmWireCitationKind.Url => "url"; case LlmWireCitationKind.File => "file"; case LlmWireCitationKind.CharacterRange => "character_range"
        case LlmWireCitationKind.PageRange => "page_range"; case LlmWireCitationKind.ContentBlockRange => "content_block_range"
        case LlmWireCitationKind.WebSearchResult => "web_search_result"; case LlmWireCitationKind.SearchResult => "search_result"
    }
    wireJsonObject([
        WireJsonField("kind", wireJsonString(kind)), WireJsonField("cited_text", wireJsonString(value.citedText)),
        WireJsonField("document_index", snapshotOptionalInt(value.documentIndex)), WireJsonField("document_title", wireJsonString(value.documentTitle)),
        WireJsonField("start_index", snapshotOptionalInt(value.startIndex)), WireJsonField("end_index", snapshotOptionalInt(value.endIndex)),
        WireJsonField("start_page", snapshotOptionalInt(value.startPage)), WireJsonField("end_page", snapshotOptionalInt(value.endPage)),
        WireJsonField("start_block", snapshotOptionalInt(value.startBlock)), WireJsonField("end_block", snapshotOptionalInt(value.endBlock)),
        WireJsonField("url", wireJsonString(value.url)), WireJsonField("title", wireJsonString(value.title)),
        WireJsonField("file_id", wireJsonString(value.fileId)), WireJsonField("filename", wireJsonString(value.filename))
    ])
}

func restoreCitation(value: JsonNode): LlmWireCitation {
    snapshotFields(value, ["kind", "cited_text", "document_index", "document_title", "start_index", "end_index", "start_page", "end_page", "start_block", "end_block", "url", "title", "file_id", "filename"])
    let kind = match (wireRequiredString(value, "kind")) {
        case "url" => LlmWireCitationKind.Url; case "file" => LlmWireCitationKind.File; case "character_range" => LlmWireCitationKind.CharacterRange
        case "page_range" => LlmWireCitationKind.PageRange; case "content_block_range" => LlmWireCitationKind.ContentBlockRange
        case "web_search_result" => LlmWireCitationKind.WebSearchResult; case "search_result" => LlmWireCitationKind.SearchResult
        case _ => snapshotInvalid("unknown citation kind in transcript snapshot")
    }
    LlmWireCitation(kind, citedText: wireRequiredString(value, "cited_text"), documentIndex: wireOptionalInt(value, "document_index"),
        documentTitle: wireRequiredString(value, "document_title"), startIndex: wireOptionalInt(value, "start_index"), endIndex: wireOptionalInt(value, "end_index"),
        startPage: wireOptionalInt(value, "start_page"), endPage: wireOptionalInt(value, "end_page"), startBlock: wireOptionalInt(value, "start_block"),
        endBlock: wireOptionalInt(value, "end_block"), url: wireRequiredString(value, "url"), title: wireRequiredString(value, "title"),
        fileId: wireRequiredString(value, "file_id"), filename: wireRequiredString(value, "filename"))
}

func snapshotBytes(bytes: Array<Int64>): JsonNode {
    let result = ArrayList<JsonNode>()
    for (byte in bytes) { result.add(wireJsonNumber(byte.toString())) }
    wireJsonArray(result.toArray())
}

func restoreBytes(value: JsonNode): Array<Int64> {
    if (value.wireKind != WireJsonKind.List) { snapshotInvalid("token bytes must be an array") }
    let result = ArrayList<Int64>()
    for (byte in value.items) {
        result.add(wireRequiredInt(wireJsonObject([WireJsonField("byte", byte)]), "byte"))
    }
    result.toArray()
}

func snapshotLogprobs(values: Array<LlmWireTokenLogprob>): JsonNode {
    let result = ArrayList<JsonNode>()
    for (value in values) {
        let candidates = ArrayList<JsonNode>()
        for (candidate in value.topLogprobs) {
            candidates.add(wireJsonObject([WireJsonField("token", wireJsonString(candidate.token)), WireJsonField("bytes", snapshotBytes(candidate.bytes)), WireJsonField("logprob", candidate.logprob.jsonNode())]))
        }
        result.add(wireJsonObject([WireJsonField("token", wireJsonString(value.token)), WireJsonField("bytes", snapshotBytes(value.bytes)),
            WireJsonField("logprob", value.logprob.jsonNode()), WireJsonField("top_logprobs", wireJsonArray(candidates.toArray()))]))
    }
    wireJsonArray(result.toArray())
}

func restoreLogprobs(value: JsonNode): Array<LlmWireTokenLogprob> {
    if (value.wireKind != WireJsonKind.List) { snapshotInvalid("logprobs must be an array") }
    let result = ArrayList<LlmWireTokenLogprob>()
    for (entry in value.items) {
        snapshotFields(entry, ["token", "bytes", "logprob", "top_logprobs"])
        let candidates = ArrayList<LlmWireTokenLogprobCandidate>()
        for (candidate in snapshotArray(entry, "top_logprobs")) {
            snapshotFields(candidate, ["token", "bytes", "logprob"])
            candidates.add(LlmWireTokenLogprobCandidate(wireRequiredString(candidate, "token"), LlmWireJson.fromJsonNode(wireRequiredField(candidate, "logprob")), bytes: restoreBytes(wireRequiredField(candidate, "bytes"))))
        }
        result.add(LlmWireTokenLogprob(wireRequiredString(entry, "token"), LlmWireJson.fromJsonNode(wireRequiredField(entry, "logprob")),
            bytes: restoreBytes(wireRequiredField(entry, "bytes")), topLogprobs: candidates.toArray()))
    }
    result.toArray()
}

func restoreTranscriptReplay(value: JsonNode): LlmWireNativeReplayBlock {
    snapshotFields(value, ["protocol", "dialect_id", "native_type", "schema_version", "model_constraint", "scope", "assistant_turn_index", "block_order", "complete", "payload", "display_reasoning"])
    nativeReplayFromPayload(
        parseProtocol(wireRequiredString(value, "protocol")), wireRequiredString(value, "dialect_id"), wireRequiredString(value, "native_type"),
        wireObject(wireRequiredField(value, "payload"), "native replay payload"), schemaVersion: wireRequiredInt(value, "schema_version"),
        modelConstraint: wireOptionalString(value, "model_constraint"), scope: parseReplayScope(wireRequiredString(value, "scope")),
        assistantTurnIndex: wireRequiredInt(value, "assistant_turn_index"), blockOrder: wireRequiredInt(value, "block_order"),
        completion: if (snapshotBool(value, "complete")) { LlmWireOpaqueCompletion.Complete } else { LlmWireOpaqueCompletion.Partial },
        displayReasoning: wireOptionalString(value, "display_reasoning")
    )
}
