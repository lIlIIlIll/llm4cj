package llm4cj

import std.unittest.*
import std.unittest.testmacro.*
import std.convert.*
import yjson.*

func transcriptTestValue<T>(value: LlmWireResult<T>): T {
    match (value) { case LlmWireResult.Ok(result) => result; case LlmWireResult.Err(error) => throw error }
}

func transcriptSnapshotText(value: LlmWireTranscript): String {
    match (value.snapshot()) { case LlmWireResult.Ok(text) => text; case LlmWireResult.Err(error) => throw error }
}

func restoredTranscript(value: String): LlmWireTranscript {
    match (LlmWireTranscript.restore(value)) { case LlmWireResult.Ok(transcript) => transcript; case LlmWireResult.Err(error) => throw error }
}

func transcriptSnapshotNode(root: JsonNode, path: String): JsonNode {
    var result = root
    if (path == "") { return result }
    for (component in path.split("/")) {
        result = if (result.wireKind == WireJsonKind.List) { result.asArray().get(Int64.parse(component)).getOrThrow() }
            else { result.field(component).getOrThrow() }
    }
    result
}

// Corrupted storage must return classified errors, including at nested metadata
// boundaries, instead of leaking a JSON, cast, index or enum exception.
func expectCorruptTranscriptSnapshots(snapshot: String): Unit {
    let mutations: Array<(String, String, JsonNode)> = [
        ("", "future_field", wireJsonBool(true)),
        ("", "version", wireJsonString("1")),
        ("initial_context", "instructions", wireJsonBool(false)),
        ("initial_context/tools/0", "deferred", wireJsonString("false")),
        ("initial_context/tools/0", "name", wireJsonNumber("1")),
        ("items/0/value", "role", wireJsonString("assistant")),
        ("items/1/value", "version", wireJsonNumber("1")),
        ("items/2/value", "role", wireJsonString("system")),
        ("items/2/value", "blocks", wireJsonObject([])),
        ("items/2/value/blocks/0", "kind", wireJsonString("unknown_block")),
        ("items/2/value/blocks/0/value", "phase", wireJsonString("unknown_phase")),
        ("items/2/value/blocks/0/value", "citations", wireJsonObject([])),
        ("items/2/value/blocks/0/value", "logprobs", wireJsonBool(false)),
        ("items/2/value/blocks/0/value/citations/0", "kind", wireJsonString("unknown_citation")),
        ("items/2/value/blocks/0/value/citations/0", "start_index", wireJsonString("1")),
        ("items/2/value/blocks/0/value/annotations/0", "kind", wireJsonString("unknown_annotation")),
        ("items/2/value/blocks/0/value/logprobs/0", "bytes", wireJsonNumber("1")),
        ("items/2/value/blocks/0/value/logprobs/0", "bytes", wireJsonArray([wireJsonString("1")])),
        ("items/2/value/blocks/0/value/logprobs/0", "top_logprobs", JsonNode.nullValue),
        ("items/2/value/blocks/1/value", "source", wireJsonString("unknown_source")),
        ("items/2/value/blocks/1/value", "detail", wireJsonString("unknown_detail")),
        ("items/2/value/blocks/2/value", "replay_dialect_id", wireJsonBool(true)),
        ("items/2/value/blocks/3/value", "schema_version", wireJsonNumber("2")),
        ("items/2/value/blocks/3/value", "protocol", wireJsonString("unknown_protocol")),
        ("items/2/value/blocks/3/value", "scope", wireJsonString("conversation")),
        ("items/2/value/blocks/3/value", "block_order", wireJsonNumber("-1")),
        ("items/2/value/blocks/3/value/payload", "signature", wireJsonBool(false)),
        ("items/2/value/blocks/4/value", "payload", wireJsonString("invalid opaque payload")),
        ("items/2/value/blocks/4/value", "complete", wireJsonString("false")),
        ("items/2/value/blocks/5/value", "category", wireJsonNumber("1")),
        ("items/2/value/blocks/6/value/arguments", "kind", wireJsonString("unknown_arguments")),
        ("items/2/value/blocks/7/value/arguments", "value", wireJsonBool(false)),
        ("items/3/value/blocks/0/value", "is_error", JsonNode.nullValue),
        ("items/3/value/blocks/0/value", "content", wireJsonArray([snapshotBlock(LlmWireBlock.ToolCall(LlmWireToolCallBlock("nested", "lookup", LlmWireToolArguments.Complete(LlmWireJson.nullValue()))))]))
    ]
    for ((path, field, replacement) in mutations) {
        let root = parseWireJson(snapshot)
        transcriptSnapshotNode(root, path).put(field, replacement)
        match (LlmWireTranscript.restore(root.stringify())) {
            case LlmWireResult.Err(error) => @Expect(error.code.startsWith("llm."), true)
            case _ => @Fail("corrupt snapshot was accepted at " + path + "/" + field)
        }
    }
}

@Test
class TranscriptSnapshotTest {
    @TestCase
    func ingressAndObservedNestedContainersStayFrozen() {
        let schema = wireJsonObject([WireJsonField("type", wireJsonString("object")), WireJsonField("properties", wireJsonObject([]))])
        let tool = LlmWireTool("lookup", "original", LlmWireJson.fromJsonNode(schema))
        let initialTools = [LlmWireToolDeclaration(tool)]
        let initialInstructions = [LlmWireInstruction(LlmWireInstructionRole.System, "original instruction")]
        let candidate = LlmWireTokenLogprobCandidate("a", transcriptTestValue(LlmWireJson.number("-1")), bytes: [97])
        let logprob = LlmWireTokenLogprob("a", transcriptTestValue(LlmWireJson.number("-1")), bytes: [97], topLogprobs: [candidate])
        let text = LlmWireTextBlock("original text", logprobs: [logprob])
        let resultContent = [LlmWireToolResultContent.Text(text)]
        let blocks = [LlmWireBlock.Text(text), LlmWireBlock.ToolResult(LlmWireToolResultBlock("call", resultContent))]
        let sourceItems = [LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, blocks))]
        let transcript = LlmWireTranscript(LlmWireInitialContext(instructions: initialInstructions, tools: initialTools), items: sourceItems)
        let before = transcriptSnapshotText(transcript)

        schema.put("type", wireJsonString("string"))
        initialTools[0] = LlmWireToolDeclaration(LlmWireTool("other", "", LlmWireJson.fromJsonNode(wireJsonObject([]))))
        initialInstructions[0] = LlmWireInstruction(LlmWireInstructionRole.System, "changed")
        logprob.bytes[0] = 0
        logprob.topLogprobs[0].bytes[0] = 0
        text.logprobs[0] = LlmWireTokenLogprob("changed", LlmWireJson.nullValue())
        blocks[0] = LlmWireBlock.Text(LlmWireTextBlock("changed"))
        resultContent[0] = LlmWireToolResultContent.Text(LlmWireTextBlock("changed"))
        sourceItems[0] = LlmWireInputItem.InstructionUpdate(LlmWireInstruction(LlmWireInstructionRole.Developer, "changed"))

        let observed = transcript.items
        match (observed[0]) { case LlmWireInputItem.Message(message) =>
            match (message.blocks[0]) { case LlmWireBlock.Text(value) =>
                value.logprobs[0].bytes[0] = 1
                value.logprobs[0].topLogprobs[0].bytes[0] = 1
                value.logprobs[0].topLogprobs[0] = LlmWireTokenLogprobCandidate("mutated", LlmWireJson.nullValue())
            case _ => @Fail("expected text") }
            message.blocks[0] = LlmWireBlock.Text(LlmWireTextBlock("observed changed"))
        case _ => @Fail("expected message") }
        transcript.initialContext.instructions[0] = LlmWireInstruction(LlmWireInstructionRole.System, "observed changed")
        transcript.initialContext.tools[0] = initialTools[0]
        @Expect(transcriptSnapshotText(transcript), before)
        @Expect(transcriptSnapshotText(restoredTranscript(before)), before)
    }

    @TestCase
    func everyTypedItemAndBlockRoundTripsWithoutLosingMetadata() {
        let citation = LlmWireCitation(LlmWireCitationKind.CharacterRange, citedText: "citation", documentIndex: Some(2),
            documentTitle: "document", startIndex: Some(1), endIndex: Some(3), startPage: Some(4), endPage: Some(5),
            startBlock: Some(6), endBlock: Some(7), url: "https://example.test", title: "title", fileId: "file", filename: "file.txt")
        let candidate = LlmWireTokenLogprobCandidate("x", transcriptTestValue(LlmWireJson.number("-0.125")), bytes: [120])
        let probability = LlmWireTokenLogprob("x", transcriptTestValue(LlmWireJson.number("-0.25")), bytes: [120], topLogprobs: [candidate])
        let text = LlmWireTextBlock("x", citations: [citation], annotations: [LlmWireAnnotation.UrlCitation(citation), LlmWireAnnotation.FileCitation(citation)],
            logprobs: [probability], phase: LlmWireOutputPhase.Commentary)
        let image = LlmWireImageBlock(LlmWireImageSourceKind.Base64, "YQ==", mediaType: "image/png", detail: LlmWireImageDetail.High)
        let replay = nativeReplayFromPayload(LlmWireProtocol.Messages, "anthropic.messages.v1", "thinking",
            wireJsonObject([WireJsonField("type", wireJsonString("thinking")), WireJsonField("thinking", wireJsonString("native reasoning")),
                WireJsonField("signature", wireJsonString("original signature"))]), modelConstraint: Some("fixed-model"), blockOrder: 3,
            displayReasoning: Some("display reasoning"))
        let opaque = LlmWireOpaqueBlock("diagnostic", wireJsonObject([WireJsonField("type", wireJsonString("diagnostic"))]), completion: LlmWireOpaqueCompletion.Partial)
        let tool = LlmWireTool("lookup", "description", LlmWireJson.fromJsonNode(wireJsonObject([WireJsonField("type", wireJsonString("object"))])))
        let context = LlmWireInitialContext(instructions: [LlmWireInstruction(LlmWireInstructionRole.System, "initial")], tools: [LlmWireToolDeclaration(tool, version: "v1", deferred: true)])
        let items = [
            LlmWireInputItem.InstructionUpdate(LlmWireInstruction(LlmWireInstructionRole.Developer, "later")),
            LlmWireInputItem.ToolActivation(LlmWireToolDefinitionIdentity("lookup", version: "v1")),
            LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.Assistant, [
                LlmWireBlock.Text(text), LlmWireBlock.Image(image), LlmWireBlock.Reasoning(LlmWireReasoningBlock("reasoning", replayDialectId: "source")),
                LlmWireBlock.NativeReplay(replay), LlmWireBlock.Opaque(opaque),
                LlmWireBlock.Refusal(LlmWireRefusalBlock("refusal", category: Some("category"), explanation: Some("explanation"), logprobs: [probability])),
                LlmWireBlock.ToolCall(LlmWireToolCallBlock("complete", "lookup", LlmWireToolArguments.Complete(LlmWireJson.fromJsonNode(wireJsonObject([]))))),
                LlmWireBlock.ToolCall(LlmWireToolCallBlock("invalid-json", "lookup", LlmWireToolArguments.InvalidJson("{"))),
                LlmWireBlock.ToolCall(LlmWireToolCallBlock("invalid-shape", "lookup", LlmWireToolArguments.InvalidShape(LlmWireJson.string("raw")))),
                LlmWireBlock.ToolCall(LlmWireToolCallBlock("partial", "lookup", LlmWireToolArguments.Partial("{")))
            ])),
            LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.ToolResult(LlmWireToolResultBlock("complete", [LlmWireToolResultContent.Text(text), LlmWireToolResultContent.Image(image)], isError: true))])),
            LlmWireInputItem.ToolDeclaration(LlmWireToolDeclaration(tool, version: "v1")),
            LlmWireInputItem.ToolDeactivation(LlmWireToolDefinitionIdentity("lookup", version: "v1"))
        ]
        let transcript = LlmWireTranscript(context, items: items)
        let snapshot = transcriptSnapshotText(transcript)
        @Expect(transcriptSnapshotText(restoredTranscript(snapshot)), snapshot)
        @Expect(snapshot.contains("fixed-model"), true)
        @Expect(snapshot.contains("original signature"), true)
        expectCorruptTranscriptSnapshots(snapshot)
    }

    @TestCase
    func allImageCitationPhaseVariantsAndPartialReplayRoundTrip() {
        let citationKinds = [LlmWireCitationKind.Url, LlmWireCitationKind.File, LlmWireCitationKind.CharacterRange,
            LlmWireCitationKind.PageRange, LlmWireCitationKind.ContentBlockRange, LlmWireCitationKind.WebSearchResult, LlmWireCitationKind.SearchResult]
        let phases = [LlmWireOutputPhase.Unspecified, LlmWireOutputPhase.Analysis, LlmWireOutputPhase.Commentary, LlmWireOutputPhase.Final]
        let sources = [LlmWireImageSourceKind.Url, LlmWireImageSourceKind.Base64, LlmWireImageSourceKind.File]
        let details = [LlmWireImageDetail.Auto, LlmWireImageDetail.Low, LlmWireImageDetail.High]
        for (kind in citationKinds) {
            for (phase in phases) {
                for (index in 0..sources.size) {
                    let transcript = LlmWireTranscript(items: [LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [
                        LlmWireBlock.Text(LlmWireTextBlock("variant", citations: [LlmWireCitation(kind)], phase: phase)),
                        LlmWireBlock.Image(LlmWireImageBlock(sources[index], "source", detail: details[index])),
                        LlmWireBlock.Refusal(LlmWireRefusalBlock("optional metadata absent"))
                    ]))])
                    let snapshot = transcriptSnapshotText(transcript)
                    @Expect(transcriptSnapshotText(restoredTranscript(snapshot)), snapshot)
                }
            }
        }
        let native = nativeReplayFromPayload(LlmWireProtocol.Messages, "anthropic.messages.v1", "redacted_thinking",
            wireJsonObject([WireJsonField("type", wireJsonString("redacted_thinking")), WireJsonField("data", wireJsonString("signature preserved"))]),
            completion: LlmWireOpaqueCompletion.Partial)
        let partial = LlmWireTranscript(items: [LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.NativeReplay(native)]))])
        let snapshot = transcriptSnapshotText(partial)
        @Expect(transcriptSnapshotText(restoredTranscript(snapshot)), snapshot)
        @Expect(snapshot.contains("\"complete\":false"), true)
    }

    @TestCase
    func unknownLegacyAndMalformedSnapshotsFailExplicitly() {
        for (snapshot in ["{}", "{\"version\":0}", "{\"version\":2}"]) {
            match (LlmWireTranscript.restore(snapshot)) {
                case LlmWireResult.Err(error) => @Expect(error.code, "llm.transcript_version_unsupported")
                case _ => @Fail("unsupported version must fail")
            }
        }
        for (snapshot in ["{", "[]", "{\"version\":1,\"format\":\"other\"}",
            "{\"version\":1,\"format\":\"llm4cj.transcript\",\"initial_context\":{\"instructions\":[],\"tools\":[]},\"items\":[{\"kind\":\"future\",\"value\":{}}]}"]) {
            match (LlmWireTranscript.restore(snapshot)) { case LlmWireResult.Err(_) => (); case _ => @Fail("malformed snapshot must fail") }
        }
    }

    @TestCase
    func snapshotEnvelopeDepthFailureIsClassified() {
        // The definition alone fits the public JSON limit; nesting it in the
        // versioned transcript envelope must still honor the writer's limit.
        var schema = "{}"
        for (_ in 0..253) { schema = "{\"nested\":" + schema + "}" }
        let tool = LlmWireTool("deep", "", transcriptTestValue(LlmWireJson.parse(schema)))
        let transcript = LlmWireTranscript(LlmWireInitialContext(tools: [LlmWireToolDeclaration(tool)]))
        match (transcript.snapshot()) {
            case LlmWireResult.Err(error) =>
                @Expect(error.code, "llm.transcript_snapshot_limit_exceeded")
                @Expect(error.kind, LlmWireErrorKind.LimitExceeded)
            case _ => @Fail("envelope depth overflow must be classified")
        }
        var excessiveDepth = "null"
        for (_ in 0..257) { excessiveDepth = "[" + excessiveDepth + "]" }
        match (LlmWireTranscript.restore(excessiveDepth)) {
            case LlmWireResult.Err(error) => @Expect(error.code, "llm.transcript_snapshot_limit_exceeded")
            case _ => @Fail("persisted envelope depth overflow must be classified")
        }
    }

    @TestCase
    func snapshotByteBudgetMatchesItsOwnRestoreBoundary() {
        let empty = LlmWireTranscript(items: [LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock(""))]))])
        let overhead = transcriptSnapshotText(empty).size
        let boundaryText = String.fromUtf8(Array<Byte>(LLM_JSON_MAX_BYTES - overhead, repeat: 120))
        let boundary = LlmWireTranscript(items: [LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock(boundaryText))]))])
        let snapshot = transcriptSnapshotText(boundary)
        @Expect(snapshot.size, LLM_JSON_MAX_BYTES)
        @Expect(transcriptSnapshotText(restoredTranscript(snapshot)), snapshot)

        let justOver = LlmWireTranscript(items: [LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock(boundaryText + "x"))]))])
        match (justOver.snapshot()) {
            case LlmWireResult.Err(error) => @Expect(error.code, "llm.transcript_snapshot_limit_exceeded")
            case _ => @Fail("snapshot writer must reject a document beyond its read limit")
        }
        match (LlmWireTranscript.restore(snapshot + " ")) {
            case LlmWireResult.Err(error) => @Expect(error.code, "llm.transcript_snapshot_limit_exceeded")
            case _ => @Fail("snapshot reader must reject one byte beyond its limit")
        }
        let fiveMiB = String.fromUtf8(Array<Byte>(5 * 1024 * 1024, repeat: 120))
        let typedLarge = LlmWireTranscript(items: [LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [
            LlmWireBlock.Text(LlmWireTextBlock(fiveMiB)), LlmWireBlock.Text(LlmWireTextBlock(fiveMiB))
        ]))])
        match (typedLarge.snapshot()) {
            case LlmWireResult.Err(error) => @Expect(error.code, "llm.transcript_snapshot_limit_exceeded")
            case _ => @Fail("large typed input must fail during bounded serialization")
        }
    }

    @TestCase
    func appendAndBuilderResetPreservePreparedTranscript() {
        let original = LlmWireTranscript(items: [LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock("first"))]))])
        let originalSnapshot = transcriptSnapshotText(original)
        let appended = original.append(LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.Text(LlmWireTextBlock("next"))])))
        @Expect(original.items.size, 1)
        @Expect(appended.items.size, 2)
        @Expect(transcriptSnapshotText(original), originalSnapshot)
        let builder = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect()).newRequestBuilder(model: "model")
        builder.setTranscript(original)
        let request = transcriptTestValue(builder.build())
        builder.reset()
        builder.setInitialContext(LlmWireInitialContext(instructions: [LlmWireInstruction(LlmWireInstructionRole.System, "new baseline")]))
        builder.appendMessage(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock("new input"))]))
        @Expect(transcriptSnapshotText(request.transcript), originalSnapshot)
        try { builder.setInitialContext(LlmWireInitialContext()); @Fail("baseline rewrite must fail") }
        catch (error: LlmWireError) { @Expect(error.code, "llm.initial_context_already_started") }
        try { builder.setTranscript(original); @Fail("transcript replacement after append must fail") }
        catch (error: LlmWireError) { @Expect(error.code, "llm.initial_context_already_started") }
    }

    @TestCase
    func rejectedBuilderAppendDoesNotMutateEarlierInput() {
        let builder = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect()).newRequestBuilder(model: "model")
        try {
            builder.setTranscript(LlmWireTranscript(LlmWireInitialContext(instructions: [LlmWireInstruction(LlmWireInstructionRole.System, " ")])))
            @Fail("invalid initial context must fail before assignment")
        } catch (error: LlmWireError) { @Expect(error.code, "llm.instruction_empty"); @Expect(error.phase, Some(LlmTransportPhase.Encode)) }
        try {
            builder.setTranscript(LlmWireTranscript(items: [LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, []))]))
            @Fail("invalid input item must fail before assignment")
        } catch (error: LlmWireError) { @Expect(error.code, "llm.message_empty"); @Expect(error.inputItemIndex, 0) }
        builder.appendMessage(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock("prepared prefix"))]))
        let before = transcriptSnapshotText(transcriptTestValue(builder.build()).transcript)
        let invalidItems = [
            LlmWireInputItem.InstructionUpdate(LlmWireInstruction(LlmWireInstructionRole.System, " ")),
            LlmWireInputItem.ToolDeclaration(LlmWireToolDeclaration(LlmWireTool("bad name", "", LlmWireJson.fromJsonNode(wireJsonObject([]))))),
            LlmWireInputItem.ToolDeclaration(LlmWireToolDeclaration(LlmWireTool("valid", "", LlmWireJson.nullValue()))),
            LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, []))
        ]
        for (item in invalidItems) {
            try { builder.append(item); @Fail("invalid append must fail") }
            catch (error: LlmWireError) {
                @Expect(error.inputItemIndex, 1)
                @Expect(error.dialectId, "openai.responses.v1")
                @Expect(error.phase, Some(LlmTransportPhase.Encode))
            }
            @Expect(transcriptSnapshotText(transcriptTestValue(builder.build()).transcript), before)
        }
        builder.append(LlmWireInputItem.InstructionUpdate(LlmWireInstruction(LlmWireInstructionRole.System, "valid update")))
        builder.append(LlmWireInputItem.ToolDeclaration(LlmWireToolDeclaration(LlmWireTool("valid", "", LlmWireJson.fromJsonNode(wireJsonObject([]))))))
        builder.append(LlmWireInputItem.ToolActivation(LlmWireToolDefinitionIdentity("valid")))
        builder.append(LlmWireInputItem.ToolDeactivation(LlmWireToolDefinitionIdentity("valid")))
        match (builder.build()) { case LlmWireResult.Err(error) => @Expect(error.kind, LlmWireErrorKind.Unsupported); case _ => @Fail("unprofiled updates must fail preflight") }
    }
}
