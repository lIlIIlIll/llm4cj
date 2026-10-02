package llm4cj

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

func temporalTool(name: String, schema!: String = "{}", version!: String = "1", deferred!: Bool = false): LlmWireToolDeclaration {
    LlmWireToolDeclaration(LlmWireTool(name, "", testJson(schema)), version: version, deferred: deferred)
}

func temporalCall(name: String, id!: String = "call-1", arguments!: String = "{}"): LlmWireToolCallBlock {
    LlmWireToolCallBlock(id, name, LlmWireToolArguments.Complete(testJson(arguments)))
}

func temporalMessage(role: LlmWireRole, text: String): LlmWireInputItem {
    LlmWireInputItem.Message(LlmWireMessage(role, [LlmWireBlock.Text(LlmWireTextBlock(text))]))
}

func temporalToolExchange(name: String): Array<LlmWireInputItem> {
    [
        LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.ToolCall(temporalCall(name))])),
        LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.ToolResult(toolResultText("call-1", "result"))]))
    ]
}

func temporalError(code: String, index: Int64, body: () -> Unit): Unit {
    try { body(); @Fail("expected transcript error: " + code) }
    catch (error: LlmWireError) { @Expect(error.code, code); @Expect(error.inputItemIndex, index) }
}

@Test
class TranscriptValidationTests {
    @TestCase
    func historicalCallsUseTheirOwnVisibility() {
        let exchange = temporalToolExchange("A")
        let transcript = LlmWireTranscript(LlmWireInitialContext(tools: [temporalTool("A")]), items: [
            exchange[0], exchange[1], LlmWireInputItem.ToolDeactivation(LlmWireToolDefinitionIdentity("A")),
            LlmWireInputItem.ToolDeclaration(temporalTool("C"))
        ])
        let view = replayTranscript(transcript)
        @Expect(view.messages.size, 2)
        @Expect(view.activeTools.size, 1)
        @Expect(view.activeTools[0].name, "C")
        let oldCall = LlmWireReply(blocks: [LlmWireOutputBlock.ToolCall(temporalCall("A"))], usage: LlmWireUsage(inputTokens: Some(10), cacheReadTokens: Some(0)))
        match (validateReplyToolInputs(oldCall, transcript, mode: LlmWireToolInputValidationMode.Disabled)) {
            case LlmWireResult.Err(error) => @Expect(error.code, "llm.tool_not_active"); @Expect(error.toolName, "A"); @Expect(error.inputItemIndex, 4); @Expect(error.usage.getOrThrow().inputTokens, Some(10)); @Expect(error.usage.getOrThrow().cacheReadTokens, Some(0))
            case _ => @Fail("withdrawn tools cannot be generated")
        }
        let newCall = LlmWireReply(blocks: [LlmWireOutputBlock.ToolCall(temporalCall("C"))])
        @Expect(validateReplyToolInputs(newCall, transcript).isOk(), true)
    }

    @TestCase
    func toolVisibilityNeverMovesBackwards() {
        let exchange = temporalToolExchange("later")
        let beforeDeclaration = LlmWireTranscript(items: [exchange[0], exchange[1], LlmWireInputItem.ToolDeclaration(temporalTool("later"))])
        temporalError("llm.tool_reference_unknown", 0, { => let _ = replayTranscript(beforeDeclaration) })
        let removed = LlmWireTranscript(LlmWireInitialContext(tools: [temporalTool("later")]), items: [
            LlmWireInputItem.ToolDeactivation(LlmWireToolDefinitionIdentity("later")), exchange[0], exchange[1]
        ])
        temporalError("llm.tool_not_active", 1, { => let _ = replayTranscript(removed) })
    }

    @TestCase
    func declarationsDeduplicateWithoutChangingState() {
        let first = temporalTool("A", schema: "{\"type\":\"object\",\"properties\":{\"a\":{\"type\":\"string\"}}}")
        let reordered = temporalTool("A", schema: "{\"properties\":{\"a\":{\"type\":\"string\"}},\"type\":\"object\"}")
        let transcript = LlmWireTranscript(LlmWireInitialContext(tools: [first, reordered]), items: [
            LlmWireInputItem.ToolDeactivation(first.identity), LlmWireInputItem.ToolDeclaration(reordered)
        ])
        let view = replayTranscript(transcript)
        @Expect(view.declaredTools.size, 1)
        @Expect(view.activeTools.size, 0)
        let deferredFirst = LlmWireTranscript(LlmWireInitialContext(tools: [temporalTool("A", deferred: true), temporalTool("A")]))
        @Expect(deferredFirst.effectiveTools.size, 0)
    }

    @TestCase
    func differentDefinitionsAndVersionsConflict() {
        for (different in [temporalTool("A", schema: "{\"type\":\"object\"}"), temporalTool("A", version: "2")]) {
            let transcript = LlmWireTranscript(LlmWireInitialContext(tools: [temporalTool("A")]), items: [LlmWireInputItem.ToolDeclaration(different)])
            temporalError("llm.tool_definition_conflict", 0, { => let _ = replayTranscript(transcript) })
        }
        let changedDescription = LlmWireToolDeclaration(LlmWireTool("A", "changed", testJson("{}")))
        let transcript = LlmWireTranscript(LlmWireInitialContext(tools: [temporalTool("A"), changedDescription]))
        temporalError("llm.tool_definition_conflict", -1, { => let _ = replayTranscript(transcript) })
    }

    @TestCase
    func identityReferencesAndDeferredStateAreExplicit() {
        for (item in [LlmWireInputItem.ToolActivation(LlmWireToolDefinitionIdentity("unknown")), LlmWireInputItem.ToolDeactivation(LlmWireToolDefinitionIdentity("unknown"))]) {
            temporalError("llm.tool_reference_unknown", 0, { => let _ = replayTranscript(LlmWireTranscript(items: [item])) })
        }
        let deferred = temporalTool("A", deferred: true)
        let unknownVersion = LlmWireTranscript(LlmWireInitialContext(tools: [deferred]), items: [LlmWireInputItem.ToolActivation(LlmWireToolDefinitionIdentity("A", version: "2"))])
        temporalError("llm.tool_reference_unknown", 0, { => let _ = replayTranscript(unknownVersion) })
        let inactive = LlmWireTranscript(LlmWireInitialContext(tools: [deferred]), items: [LlmWireInputItem.ToolDeactivation(deferred.identity)])
        temporalError("llm.tool_not_active", 0, { => let _ = replayTranscript(inactive) })
        let active = LlmWireTranscript(LlmWireInitialContext(tools: [deferred]), items: [LlmWireInputItem.ToolActivation(deferred.identity)])
        @Expect(active.effectiveTools[0].name, "A")
    }

    @TestCase
    func callResultAssociationsFailAtTheirActualItem() {
        let initial = LlmWireInitialContext(tools: [temporalTool("A")])
        let call = LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.ToolCall(temporalCall("A"))]))
        let result = LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.ToolResult(toolResultText("call-1", "ok"))]))
        temporalError("llm.tool_call_unresolved", 0, { => let _ = replayTranscript(LlmWireTranscript(initial, items: [call])) })
        temporalError("llm.tool_result_unmatched", 0, { => let _ = replayTranscript(LlmWireTranscript(initial, items: [result])) })
        temporalError("llm.tool_call_duplicate", 2, { => let _ = replayTranscript(LlmWireTranscript(initial, items: [call, result, call])) })
        temporalError("llm.tool_result_unmatched", 2, { => let _ = replayTranscript(LlmWireTranscript(initial, items: [call, result, result])) })
        temporalError("llm.tool_conversation_out_of_phase", 1, { => let _ = replayTranscript(LlmWireTranscript(initial, items: [call, temporalMessage(LlmWireRole.Assistant, "text")])) })
        temporalError("llm.tool_call_role_invalid", 0, { => let _ = replayTranscript(LlmWireTranscript(initial, items: [LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.ToolCall(temporalCall("A"))]))])) })
        temporalError("llm.tool_result_role_invalid", 0, { => let _ = replayTranscript(LlmWireTranscript(initial, items: [LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.ToolResult(toolResultText("call-1", "ok"))]))])) })
    }

    @TestCase
    func parallelResultsCloseExactlyOneAssistantTurn() {
        let initial = LlmWireInitialContext(tools: [temporalTool("A")])
        let calls = LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.ToolCall(temporalCall("A")), LlmWireBlock.ToolCall(temporalCall("A", id: "call-2"))]))
        let partialResults = LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.ToolResult(toolResultText("call-1", "ok"))]))
        temporalError("llm.tool_results_incomplete", 1, { => let _ = replayTranscript(LlmWireTranscript(initial, items: [calls, partialResults])) })
        let ordinaryContent = LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.ToolResult(toolResultText("call-1", "ok")), LlmWireBlock.Text(LlmWireTextBlock("extra"))]))
        temporalError("llm.tool_conversation_out_of_phase", 1, { => let _ = replayTranscript(LlmWireTranscript(initial, items: [calls, ordinaryContent])) })
        let results = LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.ToolResult(toolResultText("call-2", "two")), LlmWireBlock.ToolResult(toolResultText("call-1", "one"))]))
        @Expect(replayTranscript(LlmWireTranscript(initial, items: [calls, results])).messages.size, 2)
        let resultsThenText = LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.ToolResult(toolResultText("call-2", "two")), LlmWireBlock.ToolResult(toolResultText("call-1", "one")), LlmWireBlock.Text(LlmWireTextBlock("continue"))]))
        @Expect(replayTranscript(LlmWireTranscript(initial, items: [calls, resultsThenText])).messages.size, 2)
        let lateResult = LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.ToolResult(toolResultText("call-2", "two")), LlmWireBlock.ToolResult(toolResultText("call-1", "one")), LlmWireBlock.Text(LlmWireTextBlock("continue")), LlmWireBlock.ToolResult(toolResultText("call-1", "again"))]))
        temporalError("llm.tool_conversation_out_of_phase", 1, { => let _ = replayTranscript(LlmWireTranscript(initial, items: [calls, lateResult])) })
    }

    @TestCase
    func anthropicUpdateGroupsRespectBothAdjacentRoles() {
        let codec = anthropicMessagesCodec(anthropicMessagesModelProfile("m", capabilities: allCapabilities()))
        let user = temporalMessage(LlmWireRole.User, "u")
        let assistant = temporalMessage(LlmWireRole.Assistant, "a")
        let update = LlmWireInputItem.InstructionUpdate(LlmWireInstruction(LlmWireInstructionRole.System, "new"))
        validateTranscriptPositions(codec, LlmWireTranscript(items: [user, update, update, assistant]))
        validateTranscriptPositions(codec, LlmWireTranscript(items: [user, update, update]))
        temporalError("llm.context_update_position_invalid", 0, { => validateTranscriptPositions(codec, LlmWireTranscript(items: [update, user])) })
        temporalError("llm.context_update_position_invalid", 1, { => validateTranscriptPositions(codec, LlmWireTranscript(items: [assistant, update])) })
        temporalError("llm.context_update_position_invalid", 1, { => validateTranscriptPositions(codec, LlmWireTranscript(items: [user, update, user])) })
        let exchange = temporalToolExchange("A")
        temporalError("llm.context_update_position_invalid", 1, { => validateTranscriptPositions(codec, LlmWireTranscript(items: [exchange[0], update, exchange[1]])) })
        validateTranscriptPositions(codec, LlmWireTranscript(items: [exchange[0], exchange[1], update]))
    }

    @TestCase
    func duplicateDeclarationsDoNotCreateAnthropicUpdateGroups() {
        let codec = anthropicMessagesCodec(anthropicMessagesModelProfile("m", capabilities: allCapabilities()))
        let tool = temporalTool("A")
        let initial = LlmWireInitialContext(tools: [tool])
        let user = temporalMessage(LlmWireRole.User, "u")
        let assistant = temporalMessage(LlmWireRole.Assistant, "a")
        let base = LlmWireTranscript(initial, items: [user, assistant, user])
        let duplicate = LlmWireTranscript(initial, items: [user, assistant, LlmWireInputItem.ToolDeclaration(tool), user])
        @Expect(codec.encodeRequest(LlmWireRequest("m", base, maxOutputTokens: Some(32))).bodyText(), codec.encodeRequest(LlmWireRequest("m", duplicate, maxOutputTokens: Some(32))).bodyText())
        let exchange = temporalToolExchange("A")
        let between = LlmWireTranscript(initial, items: [exchange[0], LlmWireInputItem.ToolDeclaration(tool), exchange[1]])
        @Expect(codec.encodeRequest(LlmWireRequest("m", between, maxOutputTokens: Some(32))).bodyText(), codec.encodeRequest(LlmWireRequest("m", LlmWireTranscript(initial, items: exchange), maxOutputTokens: Some(32))).bodyText())
        let changed = LlmWireTranscript(initial, items: [user, assistant, LlmWireInputItem.ToolDeclaration(temporalTool("A", schema: "{\"type\":\"object\"}")), user])
        temporalError("llm.tool_definition_conflict", 2, { => let _ = codec.encodeRequest(LlmWireRequest("m", changed, maxOutputTokens: Some(32))) })
    }

    @TestCase
    func callShapeFailuresPrecedeTemporalAssociation() {
        let initial = LlmWireInitialContext(tools: [temporalTool("A")])
        let malformed = [
            ("llm.tool_arguments_partial", LlmWireToolArguments.Partial("{")),
            ("llm.tool_arguments_shape_invalid", LlmWireToolArguments.Complete(testJson("[]"))),
            ("llm.tool_arguments_shape_invalid", LlmWireToolArguments.InvalidShape(testJson("true"))),
            ("llm.tool_arguments_not_executable", LlmWireToolArguments.InvalidJson("{"))
        ]
        for ((code, arguments) in malformed) {
            let transcript = LlmWireTranscript(initial, items: [LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.ToolCall(LlmWireToolCallBlock("c", "A", arguments))]))])
            temporalError(code, 0, { => let _ = replayTranscript(transcript) })
        }
        let invalidName = LlmWireTranscript(initial, items: [LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.ToolCall(temporalCall("bad name"))]))])
        temporalError("llm.tool_call_name_invalid", 0, { => let _ = replayTranscript(invalidName) })
    }

    @TestCase
    func explicitToolErrorsMustHaveProviderSemantics() {
        let initial = LlmWireInitialContext(tools: [temporalTool("A")])
        let call = LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.ToolCall(temporalCall("A"))]))
        let error = LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.ToolResult(toolResultText("call-1", "failed", isError: true))]))
        let transcript = LlmWireTranscript(initial, items: [call, error])
        for (codec in [openAiResponsesCodec(openAiResponsesModelProfile("m", capabilities: allCapabilities())), openAiChatCodec(openAiChatModelProfile("m", capabilities: allCapabilities())), deepSeekChatCodec(deepSeekChatModelProfile("m", capabilities: allCapabilities())), kimiChatCodec(kimiChatModelProfile("m", capabilities: allCapabilities()))]) {
            temporalError("llm.tool_result_error_semantics_unsupported", 1, { => let _ = codec.encodeRequest(LlmWireRequest("m", transcript)) })
        }
        let anthropic = anthropicMessagesCodec(anthropicMessagesModelProfile("m", capabilities: allCapabilities()))
        @Expect(anthropic.encodeRequest(LlmWireRequest("m", transcript, maxOutputTokens: Some(32))).bodyText().contains("\"is_error\":true"), true)
        let deepSeek = deepSeekMessagesCodec(deepSeekMessagesModelProfile("m", capabilities: allCapabilities()))
        @Expect(deepSeek.encodeRequest(LlmWireRequest("m", transcript, maxOutputTokens: Some(32))).bodyText().contains("[tool_error]"), true)
    }

    @TestCase
    func finalViewReusesTheExistingSchemaBarrier() {
        let transcript = LlmWireTranscript(items: [LlmWireInputItem.ToolDeclaration(temporalTool("C", schema: "{\"type\":\"object\",\"properties\":{\"p\":{\"type\":\"string\"}},\"required\":[\"p\"]}"))])
        let invalid = LlmWireReply(blocks: [LlmWireOutputBlock.ToolCall(temporalCall("C", arguments: "{\"p\":1}"))], usage: LlmWireUsage(inputTokens: Some(11), cacheReadTokens: Some(0)))
        match (validateReplyToolInputs(invalid, transcript)) {
            case LlmWireResult.Err(error) => @Expect(error.code, "llm.tool_arguments_schema_violation"); @Expect(error.toolName, "C"); @Expect(error.usage.getOrThrow().inputTokens, Some(11)); @Expect(error.usage.getOrThrow().cacheReadTokens, Some(0))
            case _ => @Fail("schema mismatch must survive transcript migration")
        }
        @Expect(validateReplyToolInputs(invalid, transcript, mode: LlmWireToolInputValidationMode.Disabled).isOk(), true)
        let unknown = LlmWireReply(blocks: [LlmWireOutputBlock.ToolCall(temporalCall("D"))], usage: LlmWireUsage(inputTokens: Some(10), cacheReadTokens: Some(0)))
        match (validateReplyToolInputs(unknown, transcript)) {
            case LlmWireResult.Err(error) => @Expect(error.code, "llm.tool_reference_unknown"); @Expect(error.usage.getOrThrow().inputTokens, Some(10)); @Expect(error.usage.getOrThrow().cacheReadTokens, Some(0))
            case _ => @Fail("unknown tool names cannot bypass schema lookup")
        }
        let unsupported = LlmWireTranscript(LlmWireInitialContext(tools: [temporalTool("C", schema: "{\"$ref\":\"#/definitions/C\"}")]))
        match (validateReplyToolInputs(invalid, unsupported, mode: LlmWireToolInputValidationMode.Strict)) {
            case LlmWireResult.Err(error) => @Expect(error.code, "llm.tool_schema_unsupported")
            case _ => @Fail("strict unsupported schema must remain explicit")
        }
        let broken = LlmWireTranscript(items: [LlmWireInputItem.ToolActivation(LlmWireToolDefinitionIdentity("missing"))])
        match (validateReplyToolInputs(unknown, broken)) {
            case LlmWireResult.Err(error) => @Expect(error.usage.getOrThrow().inputTokens, Some(10)); @Expect(error.usage.getOrThrow().cacheReadTokens, Some(0))
            case _ => @Fail("invalid originating transcript must preserve incurred usage")
        }
    }

    @TestCase
    func transcriptErrorContextAndUsageSurviveEveryCopy() {
        let source = transcriptError("llm.context_update_unsupported", "missing capability", 7, toolName: "A", toolVersion: "v2", blockIndex: 3, toolCallId: "call-7", kind: LlmWireErrorKind.Unsupported, missingCapability: "tool_deactivation", profileId: "profile.v1", contractVersion: 1)
        let usage = LlmWireUsage(inputTokens: Some(10), cacheReadTokens: Some(0))
        let codec = openAiResponsesCodec(openAiResponsesModelProfile("m"))
        let contextual = withCodecContext(withPhaseIfMissing(withHttpContext(withObservedUsage(source, Some(usage)), 400, None, "req"), LlmTransportPhase.WireDecode), codec, LlmTransportPhase.Encode)
        @Expect(contextual.inputItemIndex, 7); @Expect(contextual.toolName, "A"); @Expect(contextual.toolVersion, "v2")
        @Expect(contextual.missingCapability, "tool_deactivation"); @Expect(contextual.profileId, "profile.v1"); @Expect(contextual.contractVersion, 1)
        @Expect(contextual.blockIndex, 3); @Expect(contextual.toolCallId, "call-7"); @Expect(contextual.providerRequestId, "req")
        @Expect(contextual.dialectId, "openai.responses.v1"); @Expect(contextual.usage.getOrThrow().inputTokens, Some(10))
        @Expect(contextual.usage.getOrThrow().cacheReadTokens, Some(0))
        @Expect(contextual.phase, Some(LlmTransportPhase.Encode))
        let boundCodec = nativeFixtureCodec(LlmWireContextUpdateStyle.ResponsesAdditionalTools)
        let bound = withCodecContext(transcriptError("llm.tool_reference_unknown", "unknown tool", 2, toolName: "missing"), boundCodec, LlmTransportPhase.Encode)
        @Expect(bound.profileId, "fixture.responses"); @Expect(bound.contractVersion, 1); @Expect(bound.inputItemIndex, 2)
        let explicit = withCodecContext(source, boundCodec, LlmTransportPhase.Encode)
        @Expect(explicit.profileId, "profile.v1"); @Expect(explicit.contractVersion, 1)
    }

    @TestCase
    func everyGeneratedChoiceUsesTheSameEndView() {
        let transcript = LlmWireTranscript(LlmWireInitialContext(tools: [temporalTool("A")]))
        let choices = [
            LlmWireChoice(0, [LlmWireOutputBlock.Text(LlmWireTextBlock("first"))], LlmWireChoiceOutcome.Completed),
            LlmWireChoice(1, [LlmWireOutputBlock.ToolCall(temporalCall("unknown"))], LlmWireChoiceOutcome.Completed)
        ]
        let usage = LlmWireUsage(inputTokens: Some(10), cacheReadTokens: Some(0))
        match (validateReplyToolInputs(LlmWireReply(choices: choices, usage: usage), transcript)) {
            case LlmWireResult.Err(error) => @Expect(error.code, "llm.tool_reference_unknown"); @Expect(error.usage.getOrThrow().cacheReadTokens, Some(0))
            case _ => @Fail("later choices cannot bypass tool visibility")
        }
        let schema = LlmWireTranscript(LlmWireInitialContext(tools: [temporalTool("A", schema: "{\"required\":[\"p\"]}")]))
        let schemaChoices = [choices[0], LlmWireChoice(1, [LlmWireOutputBlock.ToolCall(temporalCall("A"))], LlmWireChoiceOutcome.Completed)]
        match (validateReplyToolInputs(LlmWireReply(choices: schemaChoices, usage: usage), schema)) {
            case LlmWireResult.Err(error) => @Expect(error.code, "llm.tool_arguments_schema_violation"); @Expect(error.usage.getOrThrow().inputTokens, Some(10)); @Expect(error.usage.getOrThrow().cacheReadTokens, Some(0))
            case _ => @Fail("later choices cannot bypass argument validation")
        }
    }

    @TestCase
    func identityAndSchemaEvidenceRemainBounded() {
        let builder = StringBuilder()
        for (_ in 0..4096) { builder.append("界") }
        let huge = builder.toString()
        let error = transcriptError("code", "message", 1, toolName: huge, toolVersion: huge, toolCallId: huge, missingCapability: huge, profileId: huge)
        @Expect(error.toolName.toArray().size < 128, true); @Expect(error.toolVersion.toArray().size < 128, true)
        @Expect(error.toolCallId.toArray().size < 128, true); @Expect(error.missingCapability.toArray().size < 128, true); @Expect(error.profileId.toArray().size < 128, true)
        temporalError("llm.tool_version_invalid", -1, { => let _ = replayTranscript(LlmWireTranscript(LlmWireInitialContext(tools: [temporalTool("A", version: huge)]))) })
        temporalError("llm.tool_name_invalid", -1, { => let _ = replayTranscript(LlmWireTranscript(LlmWireInitialContext(tools: [temporalTool("not valid")])) ) })
        temporalError("llm.tool_schema_invalid", -1, { => let _ = replayTranscript(LlmWireTranscript(LlmWireInitialContext(tools: [temporalTool("A", schema: "[]")])) ) })
        let violation = ToolInputViolation(ToolInputViolationKind.MissingRequired, huge, huge, expected: "field")
        let diagnostic = toolInputViolationError(temporalCall("A"), violation)
        @Expect(diagnostic.message.toArray().size < 256, true)
        @Expect(diagnostic.diagnosticJson.getOrThrow().toArray().size < 512, true)
    }

    @TestCase
    func chatReplayCardinalityFailsBeforeAnySendableBytes() {
        let payload = parseWireJson("{\"type\":\"reasoning_content\",\"reasoning_content\":\"reasoning\"}")
        for (codec in [deepSeekChatCodec(deepSeekChatModelProfile("m")), kimiChatCodec(kimiChatModelProfile("m"))]) {
            let first = nativeReplayFromPayload(LlmWireProtocol.ChatCompletions, codec.dialect.compatibilityId, "reasoning_content", payload, blockOrder: 0)
            let second = nativeReplayFromPayload(LlmWireProtocol.ChatCompletions, codec.dialect.compatibilityId, "reasoning_content", payload, blockOrder: 1)
            let transcript = LlmWireTranscript(items: [LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.NativeReplay(first), LlmWireBlock.NativeReplay(second)]))])
            temporalError("llm.native_replay_cardinality_invalid", 0, { => let _ = codec.encodeRequest(LlmWireRequest("m", transcript)) })
        }
    }

    @TestCase
    func emptyInputAndInstructionsKeepTheirSpecificFailures() {
        let messages = anthropicMessagesCodec(anthropicMessagesModelProfile("m"))
        expectLlmError("llm.messages_required", { => let _ = messages.encodeRequest(LlmWireRequest("m", LlmWireTranscript(), maxOutputTokens: Some(32))) })
        let responses = openAiResponsesCodec(openAiResponsesModelProfile("m"))
        let instructionsOnly = LlmWireTranscript(LlmWireInitialContext(instructions: [LlmWireInstruction(LlmWireInstructionRole.System, "only instruction")]))
        @Expect(responses.encodeRequest(LlmWireRequest("m", instructionsOnly)).bodyText().contains("only instruction"), true)
        expectLlmError("llm.instruction_empty", { => let _ = responses.encodeRequest(LlmWireRequest("m", LlmWireTranscript(LlmWireInitialContext(instructions: [LlmWireInstruction(LlmWireInstructionRole.System, " \t ")])))) })
        let updates = nativeFixtureCodec(LlmWireContextUpdateStyle.ResponsesAdditionalTools)
        let emptyUpdate = LlmWireTranscript(items: [temporalMessage(LlmWireRole.User, "prior input"), LlmWireInputItem.InstructionUpdate(LlmWireInstruction(LlmWireInstructionRole.Developer, " \t "))])
        temporalError("llm.instruction_empty", 1, { => let _ = updates.encodeRequest(LlmWireRequest(updates.modelProfile.getOrThrow().model, emptyUpdate)) })
    }

    @TestCase
    func invalidToolResultsRetainActualItemAndErrorCode() {
        let initial = LlmWireInitialContext(tools: [temporalTool("A")])
        let call = LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.ToolCall(temporalCall("A"))]))
        let codec = openAiResponsesCodec(openAiResponsesModelProfile("m", capabilities: allCapabilities()))
        let emptyParts: Array<LlmWireToolResultContent> = []
        for (parts in [emptyParts, [LlmWireToolResultContent.Text(LlmWireTextBlock(""))]]) {
            let transcript = LlmWireTranscript(initial, items: [call, LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.ToolResult(LlmWireToolResultBlock("call-1", parts))]))])
            temporalError("llm.tool_result_content_empty", 1, { => let _ = codec.encodeRequest(LlmWireRequest("m", transcript)) })
        }
        let malformedImage = LlmWireTranscript(initial, items: [call, LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.ToolResult(LlmWireToolResultBlock("call-1", [LlmWireToolResultContent.Image(LlmWireImageBlock(LlmWireImageSourceKind.Url, ""))]))]))])
        temporalError("llm.image_url_invalid", 1, { => let _ = codec.encodeRequest(LlmWireRequest("m", malformedImage)) })
    }

    @TestCase
    func generatedCallsCanSelectLaterDefinitionsWithoutWideningVisibility() {
        let transcript = LlmWireTranscript(LlmWireInitialContext(tools: [temporalTool("A"), temporalTool("B"), temporalTool("C", deferred: true)]))
        @Expect(validateReplyToolInputs(LlmWireReply(), transcript).isOk(), true)
        let valid = LlmWireReply(blocks: [LlmWireOutputBlock.ToolCall(temporalCall("B")), LlmWireOutputBlock.ToolCall(temporalCall("A", id: "call-2"))])
        @Expect(validateReplyToolInputs(valid, transcript).isOk(), true)
        @Expect(validateReplyToolInputs(valid, transcript, mode: LlmWireToolInputValidationMode.Disabled).isOk(), true)
        let partial = LlmWireReply(blocks: [LlmWireOutputBlock.ToolCall(LlmWireToolCallBlock("partial", "B", LlmWireToolArguments.Partial("{")))])
        @Expect(validateReplyToolInputs(partial, transcript).isOk(), true)
        for ((name, code) in [("C", "llm.tool_not_active"), ("D", "llm.tool_reference_unknown")]) {
            match (validateReplyToolInputs(LlmWireReply(blocks: [LlmWireOutputBlock.ToolCall(temporalCall(name))]), transcript)) {
                case LlmWireResult.Err(error) => @Expect(error.code, code); @Expect(error.toolName, name)
                case _ => @Fail("deferred or missing definitions must stay unavailable")
            }
        }
    }

    @TestCase
    func aNewAnthropicSchemaIsNotAnActivationOfTheInitialPool() {
        let codec = nativeFixtureCodec(LlmWireContextUpdateStyle.AnthropicToolReferences)
        let transcript = LlmWireTranscript(LlmWireInitialContext(tools: [temporalTool("A")]), items: [temporalMessage(LlmWireRole.User, "load discovered schema"), LlmWireInputItem.ToolDeclaration(temporalTool("C")), temporalMessage(LlmWireRole.Assistant, "next")])
        validateTranscriptPositions(codec, transcript)
        match (codec.modelProfile) {
            case Some(profile) =>
                try { let _ = codec.encodeRequest(LlmWireRequest(profile.model, transcript, maxOutputTokens: Some(32))); @Fail("new schemas cannot extend the predeclared pool") }
                catch (error: LlmWireError) { @Expect(error.code, "llm.context_update_unsupported"); @Expect(error.inputItemIndex, 1); @Expect(error.missingCapability, "tool_declaration"); @Expect(error.toolName, "C") }
            case None => @Fail("fixture must bind a model and endpoint")
        }
        @Expect(transcript.initialContext.tools.size, 1)
        @Expect(transcript.initialContext.tools[0].tool.name, "A")
    }

    @TestCase
    func emptyToolVersionsAndCallIdsAreRejectedBeforeStateMutation() {
        temporalError("llm.tool_version_invalid", -1, { => let _ = replayTranscript(LlmWireTranscript(LlmWireInitialContext(tools: [temporalTool("A", version: "")]))) })
        let emptyId = LlmWireTranscript(LlmWireInitialContext(tools: [temporalTool("A")]), items: [LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.ToolCall(temporalCall("A", id: ""))]))])
        temporalError("llm.tool_call_duplicate", 0, { => let _ = replayTranscript(emptyId) })
    }
}
