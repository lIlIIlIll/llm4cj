package llm4cj_provider_probe

import llm4cj.*
import std.collection.*
import std.fs.*
import std.io.*

func inspectionCodecFor(name: String, tools!: Bool = false): LlmWireCodec {
    codecFor(name, model: "fixture-model", tools: tools)
}

// Only project public typed values; never interpret provider JSON here.
func probeValue<T>(result: LlmWireResult<T>): T {
    match (result) { case LlmWireResult.Ok(value) => value; case LlmWireResult.Err(error) => throw error }
}
func js(value: String): LlmWireJson { probeValue(LlmWireJson.string(value)) }
func ji(value: Int64): LlmWireJson { probeValue(LlmWireJson.number(value.toString())) }
func ja(values: Array<LlmWireJson>): LlmWireJson { probeValue(LlmWireJson.array(values)) }
func jo(fields: Array<LlmWireJsonField>): LlmWireJson { probeValue(LlmWireJson.object(fields)) }
func jf(name: String, value: LlmWireJson): LlmWireJsonField { LlmWireJsonField(name, value) }
func jp(value: String): LlmWireJson { probeValue(LlmWireJson.parse(value)) }
func jnull(): LlmWireJson { LlmWireJson.nullValue() }
func optionalInt(value: ?Int64): LlmWireJson { match (value) { case Some(value) => ji(value); case None => jnull() } }
func optionalText(value: ?String): LlmWireJson { match (value) { case Some(value) => js(value); case None => jnull() } }
func optionalJson(value: ?String): LlmWireJson { match (value) { case Some(value) => jp(value); case None => jnull() } }
func phaseName(value: LlmWireOutputPhase): String {
    match (value) {
        case LlmWireOutputPhase.Unspecified => "unspecified"; case LlmWireOutputPhase.Analysis => "analysis"
        case LlmWireOutputPhase.Commentary => "commentary"; case LlmWireOutputPhase.Final => "final"
    }
}
func protocolJson(value: LlmWireProtocol): LlmWireJson {
    js(match (value) { case LlmWireProtocol.Responses => "responses"; case LlmWireProtocol.ChatCompletions => "chat_completions"; case LlmWireProtocol.Messages => "messages" })
}
func usageJson(value: LlmWireUsage): LlmWireJson {
    let source = match (value.source) {
        case LlmWireUsageSource.Unknown => jnull()
        case LlmWireUsageSource.ProviderReported(provider, dialect) => jo([jf("provider", js(provider)), jf("dialect", js(dialect))])
    }
    jo([
        jf("input_tokens", optionalInt(value.inputTokens)), jf("output_tokens", optionalInt(value.outputTokens)),
        jf("reasoning_tokens", optionalInt(value.reasoningTokens)), jf("cache_read_tokens", optionalInt(value.cacheReadTokens)),
        jf("cache_write_tokens", optionalInt(value.cacheWriteTokens)), jf("total_tokens", optionalInt(value.totalTokens)),
        jf("web_search_requests", optionalInt(value.webSearchRequests)), jf("web_fetch_requests", optionalInt(value.webFetchRequests)),
        jf("service_tier", optionalText(value.serviceTier)), jf("source", source),
        jf("cache_read_availability", js(if (value.cacheReadAvailability == LlmWireUsageAvailability.Reported) { "reported" } else { "unknown" })),
        jf("cache_write_availability", js(if (value.cacheWriteAvailability == LlmWireUsageAvailability.Reported) { "reported" } else { "unknown" }))
    ])
}
func optionalUsage(value: ?LlmWireUsage): LlmWireJson { match (value) { case Some(value) => usageJson(value); case None => jnull() } }
func errorJson(value: LlmWireError): LlmWireJson {
    let kind = match (value.kind) {
        case LlmWireErrorKind.InvalidWire => "invalid_wire"; case LlmWireErrorKind.InvalidRequest => "invalid_request"
        case LlmWireErrorKind.Unsupported => "unsupported"; case LlmWireErrorKind.InvalidState => "invalid_state"
        case LlmWireErrorKind.Http => "http"; case LlmWireErrorKind.BodyLimit => "body_limit"
        case LlmWireErrorKind.LimitExceeded => "limit_exceeded"; case LlmWireErrorKind.Sse => "sse"
        case LlmWireErrorKind.Cancelled => "cancelled"; case LlmWireErrorKind.Deadline => "deadline"; case LlmWireErrorKind.Transport => "transport"
    }
    let phase = match (value.phase) {
        case None => jnull()
        case Some(value) => js(match (value) {
            case LlmTransportPhase.Encode => "encode"; case LlmTransportPhase.Request => "request"
            case LlmTransportPhase.ResponseHeaders => "response_headers"; case LlmTransportPhase.StreamFraming => "stream_framing"
            case LlmTransportPhase.WireDecode => "wire_decode"; case LlmTransportPhase.SemanticAssembly => "semantic_assembly"
            case LlmTransportPhase.Transport => "transport"
        })
    }
    let protocol = match (value.protocol) { case Some(value) => protocolJson(value); case None => jnull() }
    jo([
        jf("kind", js(kind)), jf("code", js(value.code)), jf("message", js(value.message)),
        jf("retryable", LlmWireJson.boolean(value.retryable)), jf("http_status", optionalInt(value.httpStatus)),
        jf("retry_after_millis", optionalInt(value.retryAfterMillis)), jf("provider", js(value.provider)),
        jf("provider_error_code", js(value.providerErrorCode)), jf("provider_error_type", js(value.providerErrorType)),
        jf("diagnostic", optionalJson(value.diagnosticJson)), jf("phase", phase), jf("protocol", protocol),
        jf("dialect", js(value.dialectId)), jf("event_type", js(value.eventType)), jf("block_index", ji(value.blockIndex)),
        jf("tool_call_id", js(value.toolCallId)), jf("input_item_index", ji(value.inputItemIndex)),
        jf("tool_name", js(value.toolName)), jf("tool_version", js(value.toolVersion)), jf("missing_capability", js(value.missingCapability)),
        jf("profile_id", js(value.profileId)), jf("contract_version", ji(value.contractVersion)),
        jf("provider_request_id", js(value.providerRequestId)), jf("usage", optionalUsage(value.usage))
    ])
}
func failureJson(value: LlmWireFailure): LlmWireJson {
    let kind = match (value.kind) {
        case LlmWireFailureKind.ProviderError => "provider_error"; case LlmWireFailureKind.Cancelled => "cancelled"
        case LlmWireFailureKind.InsufficientSystemResource => "insufficient_system_resource"; case LlmWireFailureKind.Other => "other"
    }
    jo([
        jf("kind", js(kind)), jf("message", js(value.message)), jf("provider", js(value.provider)),
        jf("provider_error_code", js(value.providerErrorCode)), jf("provider_error_type", js(value.providerErrorType)),
        jf("retryable", LlmWireJson.boolean(value.retryable)), jf("http_status", optionalInt(value.httpStatus)),
        jf("retry_after_millis", optionalInt(value.retryAfterMillis)), jf("provider_request_id", js(value.providerRequestId)),
        jf("usage", optionalUsage(value.usage)), jf("diagnostic", optionalJson(value.diagnosticJson))
    ])
}
func logprobsJson(values: Array<LlmWireTokenLogprob>): LlmWireJson {
    ja(values.map({ value: LlmWireTokenLogprob =>
        jo([jf("token", js(value.token)), jf("bytes", ja(value.bytes.map({ byte: Int64 => ji(byte) }))),
            // The exact literal survives JSON parsers that otherwise use floats.
            jf("logprob", js(value.logprob.stringify())),
            jf("top_logprobs", ja(value.topLogprobs.map({ candidate: LlmWireTokenLogprobCandidate =>
                jo([jf("token", js(candidate.token)), jf("bytes", ja(candidate.bytes.map({ byte: Int64 => ji(byte) }))), jf("logprob", js(candidate.logprob.stringify()))])
            })))])
    }))
}
func citationJson(value: LlmWireCitation): LlmWireJson {
    let kind = match (value.kind) {
        case LlmWireCitationKind.Url => "url"; case LlmWireCitationKind.File => "file"
        case LlmWireCitationKind.CharacterRange => "character_range"; case LlmWireCitationKind.PageRange => "page_range"
        case LlmWireCitationKind.ContentBlockRange => "content_block_range"; case LlmWireCitationKind.WebSearchResult => "web_search_result"
        case LlmWireCitationKind.SearchResult => "search_result"
    }
    jo([
        jf("kind", js(kind)), jf("cited_text", js(value.citedText)), jf("document_index", optionalInt(value.documentIndex)),
        jf("document_title", js(value.documentTitle)), jf("start_index", optionalInt(value.startIndex)), jf("end_index", optionalInt(value.endIndex)),
        jf("start_page", optionalInt(value.startPage)), jf("end_page", optionalInt(value.endPage)), jf("start_block", optionalInt(value.startBlock)),
        jf("end_block", optionalInt(value.endBlock)), jf("url", js(value.url)), jf("title", js(value.title)), jf("file_id", js(value.fileId)), jf("filename", js(value.filename))
    ])
}
func textJson(value: LlmWireTextBlock): LlmWireJson {
    jo([
        jf("text", js(value.text)), jf("phase", js(phaseName(value.phase))), jf("logprobs", logprobsJson(value.logprobs)),
        jf("citations", ja(value.citations.map({ citation: LlmWireCitation => citationJson(citation) }))),
        jf("annotations", ja(value.annotations.map({ annotation: LlmWireAnnotation =>
            let (kind, citation) = match (annotation) { case LlmWireAnnotation.UrlCitation(value) => ("url", value); case LlmWireAnnotation.FileCitation(value) => ("file", value) }
            jo([jf("kind", js(kind)), jf("citation", citationJson(citation))])
        })))
    ])
}
func refusalJson(value: LlmWireRefusalBlock): LlmWireJson {
    jo([jf("text", js(value.text)), jf("category", optionalText(value.category)), jf("explanation", optionalText(value.explanation)), jf("logprobs", logprobsJson(value.logprobs))])
}
func argumentsJson(value: LlmWireToolArguments): LlmWireJson {
    let (kind, data) = match (value) {
        case LlmWireToolArguments.Complete(value) => ("complete", value)
        case LlmWireToolArguments.InvalidJson(value) => ("invalid_json", js(value))
        case LlmWireToolArguments.InvalidShape(value) => ("invalid_shape", value)
        case LlmWireToolArguments.Partial(value) => ("partial", js(value))
        case LlmWireToolArguments.Text(value) => ("text", js(value))
        case LlmWireToolArguments.PartialText(value) => ("partial_text", js(value))
    }
    jo([jf("kind", js(kind)), jf("value", data)])
}
func blockJson(value: LlmWireOutputBlock): LlmWireJson {
    let (kind, data) = match (value) {
        case LlmWireOutputBlock.Text(value) => ("text", textJson(value))
        case LlmWireOutputBlock.Refusal(value) => ("refusal", refusalJson(value))
        case LlmWireOutputBlock.Reasoning(value) => ("reasoning", jo([jf("text", js(value.text)), jf("replay_dialect_id", js(value.replayDialectId))]))
        case LlmWireOutputBlock.ToolCall(value) =>
            let fields = ArrayList<LlmWireJsonField>(); fields.add(jf("call_id", js(value.callId))); fields.add(jf("name", js(value.name))); fields.add(jf("arguments", argumentsJson(value.arguments)))
            if (value.kind == LlmWireToolKind.Custom) { fields.add(jf("tool_kind", js("custom"))) }
            ("tool_call", jo(fields.toArray()))
        case LlmWireOutputBlock.NativeReplay(value) => ("native_replay", jp(value.snapshot()))
    }
    jo([jf("kind", js(kind)), jf("value", data)])
}
func outcomeJson(value: LlmWireChoiceOutcome): LlmWireJson {
    match (value) {
        case LlmWireChoiceOutcome.Completed => jo([jf("kind", js("completed"))])
        case LlmWireChoiceOutcome.Refused(value) => jo([jf("kind", js("refused")), jf("refusal", refusalJson(value))])
        case LlmWireChoiceOutcome.Incomplete(value) =>
            let reason = match (value) {
                case LlmWireIncompleteReason.MaxTokens => "max_tokens"; case LlmWireIncompleteReason.Length => "length"
                case LlmWireIncompleteReason.ContentFilter => "content_filter"; case LlmWireIncompleteReason.ModelContextWindowExceeded => "model_context_window_exceeded"
                case LlmWireIncompleteReason.PauseTurn => "pause_turn"; case LlmWireIncompleteReason.Other(value) => value
            }
            jo([jf("kind", js("incomplete")), jf("reason", js(reason))])
    }
}
func replyJson(value: LlmWireReply): LlmWireJson {
    jo([
        jf("response_id", js(value.responseId)), jf("model", js(value.model)), jf("raw_stop_reason", js(value.rawStopReason)),
        jf("blocks", ja(value.blocks.map({ block: LlmWireOutputBlock => blockJson(block) }))), jf("usage", usageJson(value.usage)),
        jf("choices", ja(value.choices.map({ choice: LlmWireChoice => jo([
            jf("index", ji(choice.index)), jf("raw_stop_reason", js(choice.rawStopReason)), jf("outcome", outcomeJson(choice.outcome)),
            jf("blocks", ja(choice.blocks.map({ block: LlmWireOutputBlock => blockJson(block) }))),
            jf("message_spans", ja(choice.messageSpans.map({ span: LlmWireAssistantMessageSpan => jo([
                jf("block_start", ji(span.blockStart)), jf("block_count", ji(span.blockCount)), jf("phase", js(phaseName(span.phase)))
            ]) })))
        ]) })))
    ])
}
func materializedJson(value: LlmWireMaterializedRequest): LlmWireJson {
    jo([jf("body", jp(String.fromUtf8(value.body))), jf("headers", ja(value.headers.map({ header: LlmWireHeader =>
        jo([jf("name", js(header.name)), jf("value", js(header.value))])
    })))])
}
func projectionError(value: LlmWireError): LlmWireJson { jo([jf("kind", js("error")), jf("error", errorJson(value))]) }
func projectionJson(name: String, result: LlmWireResult<Array<LlmWireMessage>>): LlmWireJson {
    try {
        let messages = probeValue(result)
        let snapshot = probeValue(LlmWireTranscript(items: messageItems(messages)).snapshot())
        let restored = probeValue(LlmWireTranscript.restore(snapshot))
        let declarations = ArrayList<LlmWireToolDeclaration>(); let names = HashSet<String>()
        let results = ArrayList<LlmWireBlock>()
        for (item in restored.items) { match (item) {
            case LlmWireInputItem.Message(message) => for (block in message.blocks) { match (block) {
                case LlmWireBlock.ToolCall(call) =>
                    if (names.add(call.name)) { declarations.add(if (call.kind == LlmWireToolKind.Custom) {
                        LlmWireToolDeclaration(LlmWireToolDefinition.Custom(LlmWireCustomTool(call.name, description: "fixture tool")))
                    } else { LlmWireToolDeclaration(LlmWireTool(call.name, "fixture tool", jp("{\"type\":\"object\"}"))) }) }
                    results.add(LlmWireBlock.ToolResult(LlmWireToolResultBlock(call.callId, [LlmWireToolResultContent.Text(LlmWireTextBlock("done"))], kind: call.kind)))
                case _ => ()
            } }
            case _ => throw IllegalStateException("projection returned a non-message item")
        } }
        let history = ArrayList<LlmWireInputItem>(); history.add(LlmWireInputItem.Message(userMessage("hello")))
        for (item in restored.items) { history.add(item) }
        if (!results.isEmpty()) { history.add(LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, results.toArray()))) }
        history.add(LlmWireInputItem.Message(userMessage("next")))
        let request = probeRequest(name, LlmWireTranscript(LlmWireInitialContext(tools: declarations.toArray()), items: history.toArray()))
        let encoded = probeValue(inspectionCodecFor(name, tools: !declarations.isEmpty()).encodeRequest(request, streaming: name == "openai-codex-responses").materialize())
        jo([jf("kind", js("ok")), jf("snapshot", jp(snapshot)), jf("restored_snapshot", jp(probeValue(restored.snapshot()))), jf("encoded", materializedJson(encoded))])
    } catch (error: LlmWireError) { projectionError(error) }
}
func continuationJson(name: String, reply: LlmWireReply): LlmWireJson {
    let defaultProjection = try { projectionJson(name, LlmWireResult.Ok(reply.toContinuationInput())) } catch (error: LlmWireError) { projectionError(error) }
    jo([jf("default", defaultProjection), jf("choices", ja(reply.choices.map({ choice: LlmWireChoice =>
        jo([jf("index", ji(choice.index)), jf("result", projectionJson(name, reply.toContinuationInput(choice.index)))])
    })))])
}
func inspectionJson(name: String, value: LlmWireTerminal): LlmWireJson {
    match (value) {
        case LlmWireTerminal.Completed(reply) => jo([
            jf("state", jo([jf("kind", js("completed")), jf("reply", replyJson(reply))])), jf("continuation", continuationJson(name, reply))
        ])
        case LlmWireTerminal.ProviderFailed(failure) => jo([jf("state", jo([jf("kind", js("provider_failed")), jf("failure", failureJson(failure))])), jf("continuation", jnull())])
        case LlmWireTerminal.Cancelled(failure) => jo([jf("state", jo([jf("kind", js("cancelled")), jf("failure", failureJson(failure))])), jf("continuation", jnull())])
    }
}
func inspectionError(value: LlmWireError): LlmWireJson {
    jo([jf("state", jo([jf("kind", js("error")), jf("error", errorJson(value))])), jf("continuation", jnull())])
}

func probeRequest(name: String, transcript: LlmWireTranscript, model!: String = "fixture-model"): LlmWireRequest {
    LlmWireRequest(model, transcript, maxOutputTokens: if (name == "openai-codex-responses") { None } else { Some(256) })
}
func userMessage(text: String): LlmWireMessage { LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock(text))]) }
func readBytes(path: String): Array<Byte> {
    let file = File(path, OpenMode.Read)
    try { readToEnd(file) } finally { file.close() }
}

class ProbeStreamResult {
    let result: LlmWireResult<LlmWireTerminal>
    let pushFailed: Bool
    init(result: LlmWireResult<LlmWireTerminal>, pushFailed!: Bool = false) { this.result = result; this.pushFailed = pushFailed }
}

// Retain the terminal from push; finish need not repeat it. Preserve legacy exit codes.
func decodeSse(codec: LlmWireCodec, bytes: Array<Byte>, chunkBytes: Int64, cancel: Bool): ProbeStreamResult {
    if (chunkBytes < 1 || chunkBytes > 65536) { throw IllegalArgumentException("invalid chunk size") }
    let decoder = codec.newStreamDecoder(sseLimits: LlmWireSseLimits(maxEventsPerPush: 4096))
    var terminal: ?LlmWireTerminal = None
    var offset: Int64 = 0
    while (offset < bytes.size) {
        let end = if (chunkBytes > bytes.size - offset) { bytes.size } else { offset + chunkBytes }
        match (decoder.push(bytes[offset..end])) {
            case LlmWireResult.Ok(update) => if (update.terminal.isSome()) { terminal = update.terminal }
            case LlmWireResult.Err(error) => return ProbeStreamResult(LlmWireResult.Err(error), pushFailed: true)
        }
        offset = end
    }
    if (cancel) { return ProbeStreamResult(decoder.cancel()) }
    match (decoder.finish()) {
        case LlmWireResult.Ok(update) => if (update.terminal.isSome()) { terminal = update.terminal }
        case LlmWireResult.Err(error) => return ProbeStreamResult(LlmWireResult.Err(error))
    }
    match (terminal) {
        case Some(value) => ProbeStreamResult(LlmWireResult.Ok(value))
        case None => throw IllegalStateException("decoder returned no terminal or error")
    }
}
func inspectFixed(name: String, path: String): Int64 {
    let output = match (inspectionCodecFor(name).decodeResponse(LlmWireHttpResponse(200, [], readBytes(path)))) {
        case LlmWireResult.Ok(LlmWireResponseState.Terminal(value)) => inspectionJson(name, value)
        case LlmWireResult.Ok(LlmWireResponseState.Pending(value)) =>
            let (kind, reply) = match (value) {
                case LlmWirePendingReply.Queued(reply) => ("queued", reply)
                case LlmWirePendingReply.InProgress(reply) => ("in_progress", reply)
            }
            jo([jf("state", jo([jf("kind", js(kind)), jf("reply", replyJson(reply))])), jf("continuation", jnull())])
        case LlmWireResult.Err(error) => inspectionError(error)
    }
    println(output.stringify()); 0
}
func inspectStream(name: String, path: String, chunkBytes: Int64, cancel: Bool): Int64 {
    let output = match (decodeSse(inspectionCodecFor(name), readBytes(path), chunkBytes, cancel).result) {
        case LlmWireResult.Ok(value) => inspectionJson(name, value)
        case LlmWireResult.Err(error) => inspectionError(error)
    }
    println(output.stringify()); 0
}
func inspectWebSocket(name: String, path: String, legacy: Bool): Int64 {
    let session = inspectionCodecFor(name, tools: true).newResponsesWebSocketSession()
    let _ = session.prepare(probeRequest(name, LlmWireTranscript(items: messageItems([userMessage("hello")]))))
    var terminal: ?LlmWireTerminal = None
    for (event in String.fromUtf8(readBytes(path)).split('\n') where event != "") {
        match (session.push(event.toArray())) {
            case LlmWireResult.Ok(update) => if (update.terminal.isSome()) { terminal = update.terminal }
            case LlmWireResult.Err(error) => if (!legacy) { println(inspectionError(error).stringify()) }; return if (legacy) { 4 } else { 0 }
        }
    }
    let completed = match (terminal) {
        case Some(LlmWireTerminal.Completed(value)) => value
        case Some(value) => if (!legacy) { println(inspectionJson(name, value).stringify()) }; return if (legacy) { 6 } else { 0 }
        case None =>
            let output = match (session.finish()) {
                case LlmWireResult.Ok(update) => match (update.terminal) {
                    case Some(value) => inspectionJson(name, value)
                    case None => throw IllegalStateException("WebSocket returned no terminal or error")
                }
                case LlmWireResult.Err(error) => inspectionError(error)
            }
            if (!legacy) { println(output.stringify()) }; return if (legacy) { 5 } else { 0 }
    }
    try {
        let history = ArrayList<LlmWireInputItem>(); history.add(LlmWireInputItem.Message(userMessage("hello")))
        for (message in completed.toContinuationInput()) { history.add(LlmWireInputItem.Message(message)) }
        let declarations = ArrayList<LlmWireToolDeclaration>(); let results = ArrayList<LlmWireBlock>(); let names = HashSet<String>()
        var hasCustom = false
        for (block in completed.blocks) { match (block) { case LlmWireOutputBlock.ToolCall(call) => if (call.kind == LlmWireToolKind.Custom) { hasCustom = true }; case _ => () } }
        if (hasCustom) {
            for (block in completed.blocks) { match (block) {
                case LlmWireOutputBlock.ToolCall(call) =>
                    if (names.add(call.name)) { declarations.add(if (call.kind == LlmWireToolKind.Custom) {
                        LlmWireToolDeclaration(LlmWireToolDefinition.Custom(LlmWireCustomTool(call.name, description: "fixture tool")))
                    } else { LlmWireToolDeclaration(LlmWireTool(call.name, "fixture tool", jp("{\"type\":\"object\"}"))) }) }
                    results.add(LlmWireBlock.ToolResult(LlmWireToolResultBlock(call.callId, [LlmWireToolResultContent.Text(LlmWireTextBlock("done"))], kind: call.kind)))
                case _ => ()
            } }
            history.add(LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, results.toArray())))
        }
        history.add(LlmWireInputItem.Message(userMessage("next")))
        let next = jp(String.fromUtf8(session.prepare(probeRequest(name, LlmWireTranscript(LlmWireInitialContext(tools: declarations.toArray()), items: history.toArray()))).body))
        if (legacy) { println(next.stringify()) } else {
            println(jo([jf("result", inspectionJson(name, LlmWireTerminal.Completed(completed))), jf("next_request", next)]).stringify())
        }
    } catch (error: LlmWireError) {
        if (legacy) { return 6 }
        println(jo([jf("result", inspectionJson(name, LlmWireTerminal.Completed(completed))), jf("next_error", errorJson(error))]).stringify())
    }
    0
}
