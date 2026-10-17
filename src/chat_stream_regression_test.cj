package llm4cj

import std.unittest.*
import std.unittest.testmacro.*

@Test
class ChatStreamRegressionTests {
    @TestCase
    func chatResourceFailurePrecedesMalformedOrOverBudgetLogprobs() {
        let codec = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect(), provider: "openai")
        let finalUsage = "{\"prompt_tokens\":5,\"completion_tokens\":3,\"total_tokens\":8,\"prompt_tokens_details\":{\"cached_tokens\":0}}"
        for (payload in ["false", "{\"content\":[{\"token\":\"x\",\"logprob\":\"bad\"}]}", "{\"content\":[{\"token\":\"a long token whose metadata exceeds the configured retained state budget\",\"logprob\":-0.1,\"bytes\":[97]}]}"]) {
            let fixed = match (streamRegressionValue(codec.decodeResponse(LlmWireHttpResponse(200, [], ("{\"choices\":[{\"index\":0,\"message\":{\"content\":\"discarded\"},\"finish_reason\":\"insufficient_system_resource\",\"logprobs\":" + payload + "}],\"usage\":" + finalUsage + "}").toArray())))) {
                case LlmWireResponseState.Terminal(LlmWireTerminal.ProviderFailed(value)) => value
                case _ => throw IllegalStateException("fixed resource outcome must be a provider failure")
            }
            for (width in [1, 13, 65536]) {
                let decoder = codec.newStreamDecoder(limits: LlmWireStreamLimits(maxRetainedStateBytes: 32))
                let first = streamRegressionPush(decoder, "{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"before\"}}],\"usage\":{\"prompt_tokens\":5,\"prompt_tokens_details\":{\"cached_tokens\":0}}}")
                var priorTextObserved = false
                for (entry in first.events) { match (entry) { case LlmWireEvent.TextDelta(value, _) => @Expect(value, "before"); priorTextObserved = true; case _ => () } }
                @Expect(priorTextObserved, true)
                let source = ("data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"discarded\"},\"finish_reason\":\"insufficient_system_resource\",\"logprobs\":" + payload + "}],\"usage\":{\"completion_tokens\":2}}\n\n").toArray()
                var offset: Int64 = 0
                while (offset < source.size) {
                    let end = min(offset + width, source.size)
                    let update = streamRegressionValue(decoder.push(source[offset..end]))
                    @Expect(update.terminal.isNone(), true)
                    for (entry in update.events) { match (entry) {
                        case LlmWireEvent.TextDelta(_, _) | LlmWireEvent.ReasoningDelta(_, _) | LlmWireEvent.RefusalDelta(_, _) | LlmWireEvent.ToolCallStarted(_) | LlmWireEvent.ToolArgumentsDelta(_, _) => @Fail("resource failure packet must not emit semantic payload")
                        case _ => ()
                    } }
                    offset = end
                }
                let _ = streamRegressionPush(decoder, "{\"choices\":[],\"usage\":{\"completion_tokens\":3,\"total_tokens\":8}}")
                let observed = match (streamRegressionPush(decoder, "[DONE]").terminal.getOrThrow()) {
                    case LlmWireTerminal.ProviderFailed(value) => value
                    case _ => throw IllegalStateException("stream resource outcome must be a provider failure")
                }
                match ((observed.kind, fixed.kind)) { case (LlmWireFailureKind.InsufficientSystemResource, LlmWireFailureKind.InsufficientSystemResource) => (); case _ => @Fail("resource failure kind must match fixed decoding") }
                @Expect(observed.message, fixed.message)
                @Expect(observed.retryable, true); @Expect(observed.retryable, fixed.retryable)
                @Expect(observed.provider, fixed.provider)
                streamRegressionUsageEqual(observed.usage.getOrThrow(), fixed.usage.getOrThrow())
                match (streamRegressionValue(decoder.finish()).terminal) { case Some(LlmWireTerminal.ProviderFailed(value)) => streamRegressionUsageEqual(value.usage.getOrThrow(), fixed.usage.getOrThrow()); case _ => @Fail("finish must retain provider failure") }
            }
        }
    }

    @TestCase
    func chatResourceFailurePreflightsLaterChoicesBeforeSemanticPayload() {
        let codec = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect(), provider: "openai")
        for (resourceIndex in [0, 1]) {
            for ((payload, retainedLimit) in [
                ("{\"content\":[{\"token\":\"x\",\"logprob\":0}]}", 256),
                ("false", 256),
                ("{\"content\":[{\"token\":\"x\",\"logprob\":\"bad\"}]}", 256),
                ("{\"content\":[{\"token\":\"a long token whose metadata exceeds the configured retained state budget\",\"logprob\":-0.1,\"bytes\":[97]}]}", 32)
            ]) {
                let resource = "{\"index\":" + resourceIndex.toString() + ",\"delta\":{\"content\":\"discarded\"},\"finish_reason\":\"insufficient_system_resource\",\"logprobs\":" + payload + "}"
                let ordinary = "{\"index\":" + (1 - resourceIndex).toString() + ",\"delta\":{\"content\":\"discarded\"},\"finish_reason\":\"stop\",\"logprobs\":" + payload + "}"
                let ordered = if (resourceIndex == 0) { resource + "," + ordinary } else { ordinary + "," + resource }
                let body = "{\"choices\":[" + ordered + "],\"usage\":{\"completion_tokens\":2}}"
                let fixed = match (streamRegressionValue(codec.decodeResponse(LlmWireHttpResponse(200, [], body.replace("\"delta\":", "\"message\":").toArray())))) {
                    case LlmWireResponseState.Terminal(LlmWireTerminal.ProviderFailed(value)) => value
                    case _ => throw IllegalStateException("fixed resource preflight must precede every choice payload")
                }
                let decoder = codec.newStreamDecoder(limits: LlmWireStreamLimits(maxRetainedStateBytes: retainedLimit))
                let update = streamRegressionPush(decoder, body)
                for (entry in update.events) { match (entry) { case LlmWireEvent.TextDelta(_, _) => @Fail("resource preflight must precede earlier choice semantic payload"); case _ => () } }
                match (streamRegressionPush(decoder, "[DONE]").terminal) {
                    case Some(LlmWireTerminal.ProviderFailed(value)) =>
                        match ((value.kind, fixed.kind)) { case (LlmWireFailureKind.InsufficientSystemResource, LlmWireFailureKind.InsufficientSystemResource) => (); case _ => @Fail("expected matching resource failures") }
                        @Expect(value.message, fixed.message); @Expect(value.provider, fixed.provider)
                        @Expect(value.retryable, true); @Expect(value.retryable, fixed.retryable)
                        @Expect(value.usage.getOrThrow().outputTokens, Some(2))
                        streamRegressionUsageEqual(value.usage.getOrThrow(), fixed.usage.getOrThrow())
                    case _ => @Fail("a resource failure anywhere in the packet must fail the attempt")
                }
            }
        }
    }

    @TestCase
    func chatResourceFailureStillEnforcesTransportAndChoiceLifecycle() {
        let codec = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect(), provider: "openai")
        let resource = "{\"choices\":[{\"index\":0,\"finish_reason\":\"insufficient_system_resource\",\"logprobs\":false}],\"usage\":{\"prompt_tokens\":5}}"
        for (ending in ["eof", "cancel", "event-limit", "semantic-after-finish"]) {
            let decoder = codec.newStreamDecoder(limits: LlmWireStreamLimits(maxRetainedStateBytes: 1, maxEvents: if (ending == "event-limit") { 1 } else { 8 }))
            let _ = streamRegressionPush(decoder, resource)
            match (ending) {
                case "cancel" => match (streamRegressionValue(decoder.cancel())) {
                    case LlmWireTerminal.Cancelled(value) => @Expect(value.usage.getOrThrow().inputTokens, Some(5))
                    case _ => @Fail("cancellation before DONE must remain cancellation")
                }
                case _ =>
                    let error = if (ending == "eof") { streamRegressionError(decoder.finish()) }
                        else if (ending == "event-limit") { streamRegressionError(decoder.push("data: [DONE]\n\n".toArray())) }
                        else { streamRegressionError(decoder.push("data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"late\"}}]}\n\n".toArray())) }
                    @Expect(error.code, if (ending == "eof") { "llm.stream_terminal_missing" } else if (ending == "event-limit") { "llm.stream_events_too_many" } else { "llm.chat_event_after_choice_finished" })
                    @Expect(error.usage.getOrThrow().inputTokens, Some(5))
            }
        }
        let finished = codec.newStreamDecoder()
        let _ = streamRegressionPush(finished, "{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":5}}")
        let duplicate = streamRegressionError(finished.push(("data: " + resource + "\n\n").toArray()))
        @Expect(duplicate.code, "llm.chat_event_after_choice_finished")
        @Expect(duplicate.usage.getOrThrow().inputTokens, Some(5))
    }

    @TestCase
    func chatResourceFailureStillValidatesUsageAndEveryChoiceHeader() {
        let codec = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect(), provider: "openai")
        let resource = "{\"index\":0,\"finish_reason\":\"insufficient_system_resource\",\"logprobs\":false}"
        for ((choices, code) in [
            ("[{\"index\":-1,\"finish_reason\":\"insufficient_system_resource\"}]", "llm.chat_choice_index_invalid"),
            ("[{\"index\":\"bad\",\"finish_reason\":\"insufficient_system_resource\"}]", "llm.field_type_invalid"),
            ("[" + resource + ",{\"index\":2,\"finish_reason\":\"stop\"}]", "llm.chat_choice_index_invalid"),
            ("[" + resource + ",{\"index\":1,\"finish_reason\":1}]", "llm.field_type_invalid"),
            ("[" + resource + ",false]", "llm.object_expected")
        ]) {
            let body = "{\"choices\":" + choices + ",\"usage\":{\"completion_tokens\":2}}"
            let fixed = streamRegressionFixedError(codec, body)
            let decoder = codec.newStreamDecoder()
            let streamed = streamRegressionError(decoder.push(("data: " + body + "\n\n").toArray()))
            @Expect(fixed.code, code); @Expect(streamed.code, code)
            streamRegressionUsageEqual(streamed.usage.getOrThrow(), fixed.usage.getOrThrow())
        }
        let body = "{\"choices\":[" + resource + "],\"usage\":{\"completion_tokens\":-1}}"
        let fixed = streamRegressionFixedError(codec, body)
        let decoder = codec.newStreamDecoder()
        let streamed = streamRegressionError(decoder.push(("data: " + body + "\n\n").toArray()))
        @Expect(fixed.code, "llm.usage_negative"); @Expect(streamed.code, fixed.code)
    }

    @TestCase
    func chatTruncatedInvalidToolNameStaysDiagnosticButCannotContinue() {
        let codec = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect())
        let tooLong = "12345678901234567890123456789012345678901234567890123456789012345"
        for (reason in ["length", "content_filter"]) {
            for (name in ["bad name", "f/x", "f.x", "工具", tooLong]) {
                for (raw in ["{}", "{", "[]"]) {
                    let call = "\"id\":\"c\",\"type\":\"function\",\"function\":{\"name\":\"" + name + "\",\"arguments\":\"" + raw + "\"}"
                    let fixed = streamRegressionFixed(codec, "{\"choices\":[{\"index\":0,\"message\":{\"tool_calls\":[{" + call + "}]},\"finish_reason\":\"" + reason + "\"}]}")
                    let source = "data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0," + call + "}]},\"finish_reason\":\"" + reason + "\"}]}\n\ndata: [DONE]\n\n"
                    for (width in [1, 23, source.toArray().size]) {
                        let streamed = streamRegressionBytes(codec, source, width)
                        for (reply in [fixed, streamed]) {
                            match (reply.choices[0].outcome) {
                                case LlmWireChoiceOutcome.Incomplete(value) => @Expect(value, if (reason == "length") { LlmWireIncompleteReason.Length } else { LlmWireIncompleteReason.ContentFilter })
                                case _ => @Fail("invalid diagnostic name must preserve truncation")
                            }
                            match (reply.blocks[0]) {
                                case LlmWireOutputBlock.ToolCall(value) =>
                                    @Expect(value.callId, "c"); @Expect(value.name, name)
                                    match (value.arguments) {
                                        case LlmWireToolArguments.Complete(value) => @Expect(raw, "{}"); @Expect(value.stringify(), raw)
                                        case LlmWireToolArguments.InvalidJson(value) => @Expect(raw, "{"); @Expect(value, raw)
                                        case LlmWireToolArguments.InvalidShape(value) => @Expect(raw, "[]"); @Expect(value.stringify(), raw)
                                        case _ => @Fail("invalid name must not change argument classification")
                                    }
                                case _ => @Fail("expected diagnostic tool call")
                            }
                            match (reply.choices[0].toContinuationInput()) {
                                case LlmWireResult.Err(error) => @Expect(error.code, "llm.tool_call_incomplete"); @Expect(error.kind, LlmWireErrorKind.InvalidState)
                                case _ => @Fail("invalid tool-name grammar cannot enter continuation")
                            }
                            try {
                                let _ = reply.toContinuationInput()
                                @Fail("default continuation must also reject invalid tool names")
                            } catch (error: LlmWireError) { @Expect(error.code, "llm.tool_call_incomplete") }
                        }
                    }
                }
            }
        }
    }

    @TestCase
    func chatLogprobsPreserveChunksChoicesAndPrecision() {
        let codec = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect(), provider: "openai")
        let first = "{\"token\":\"o\",\"bytes\":[111],\"logprob\":-0.1234567890123456789,\"top_logprobs\":[{\"token\":\"a\",\"bytes\":[97],\"logprob\":-2.34567890123456789}]}"
        let second = "{\"token\":\"k\",\"bytes\":[107],\"logprob\":-0.2,\"top_logprobs\":[]}"
        let refusal = "{\"token\":\"no\",\"bytes\":[110,111],\"logprob\":-0.3,\"top_logprobs\":[]}"
        let fixed = streamRegressionFixed(codec, "{\"id\":\"r\",\"model\":\"m\",\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":\"ok\"},\"finish_reason\":\"stop\",\"logprobs\":{\"content\":[" + first + "," + second + "],\"refusal\":null}},{\"index\":1,\"message\":{\"refusal\":\"no\"},\"finish_reason\":\"stop\",\"logprobs\":{\"content\":[],\"refusal\":[" + refusal + "]}}]}")
        let source = "data: {\"id\":\"r\",\"model\":\"m\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"o\"},\"logprobs\":{\"content\":[" + first + "],\"refusal\":null}},{\"index\":1,\"delta\":{\"refusal\":\"no\"},\"logprobs\":{\"content\":[],\"refusal\":[" + refusal + "]}}]}\n\ndata: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"k\"},\"finish_reason\":\"stop\",\"logprobs\":{\"content\":[" + second + "]}},{\"index\":1,\"delta\":{},\"finish_reason\":\"stop\",\"logprobs\":null}]}\n\ndata: [DONE]\n\n"
        for (width in [1, 17, source.toArray().size]) {
            let streamed = streamRegressionBytes(codec, source, width)
            @Expect(streamed.responseId, fixed.responseId); @Expect(streamed.model, fixed.model)
            @Expect(streamed.choices.size, 2); @Expect(streamed.rawStopReason, fixed.rawStopReason)
            streamRegressionUsageEqual(streamed.usage, fixed.usage)
            for (index in 0..2) {
                @Expect(streamed.choices[index].index, fixed.choices[index].index)
                @Expect(streamed.choices[index].rawStopReason, fixed.choices[index].rawStopReason)
                @Expect(streamed.choices[index].blocks.size, 1)
                match ((streamed.choices[index].blocks[0], fixed.choices[index].blocks[0])) {
                    case (LlmWireOutputBlock.Text(a), LlmWireOutputBlock.Text(b)) =>
                        @Expect(a.text, "ok"); @Expect(a.text, b.text); @Expect(a.logprobs.size, 2)
                        @Expect(a.logprobs[0].logprob.stringify(), "-0.1234567890123456789")
                        @Expect(a.logprobs[0].token, "o"); @Expect(a.logprobs[0].bytes.size, 1); @Expect(a.logprobs[0].bytes[0], 111)
                        @Expect(a.logprobs[0].topLogprobs.size, 1)
                        @Expect(a.logprobs[0].topLogprobs[0].token, "a")
                        @Expect(a.logprobs[0].topLogprobs[0].logprob.stringify(), "-2.34567890123456789")
                        @Expect(a.logprobs[0].topLogprobs[0].bytes[0], 97)
                        @Expect(a.logprobs[1].token, "k"); @Expect(a.logprobs[1].bytes[0], 107)
                        match (streamed.choices[index].outcome) { case LlmWireChoiceOutcome.Completed => (); case _ => @Fail("text choice must complete") }
                        streamRegressionLogprobsEqual(a.logprobs, b.logprobs)
                    case (LlmWireOutputBlock.Refusal(a), LlmWireOutputBlock.Refusal(b)) =>
                        @Expect(a.text, "no"); @Expect(a.text, b.text); @Expect(a.logprobs.size, 1)
                        @Expect(a.logprobs[0].token, "no"); @Expect(a.logprobs[0].bytes.size, 2)
                        @Expect(a.logprobs[0].bytes[0], 110); @Expect(a.logprobs[0].bytes[1], 111)
                        @Expect(a.logprobs[0].logprob.stringify(), "-0.3")
                        match (streamed.choices[index].outcome) { case LlmWireChoiceOutcome.Refused(value) => @Expect(value.text, "no"); case _ => @Fail("refusal choice must remain refused") }
                        streamRegressionLogprobsEqual(a.logprobs, b.logprobs)
                    case _ => @Fail("fixed and streamed canonical block types differ")
                }
            }
        }
    }

    @TestCase
    func chatMalformedLogprobsMatchFixedErrors() {
        let codec = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect())
        for (payload in [
            "{\"content\":[{\"token\":\"x\",\"logprob\":\"bad\"}]}",
            "{\"content\":[{\"token\":\"x\",\"logprob\":0,\"bytes\":[256]}]}",
            "{\"content\":[{\"token\":\"x\",\"logprob\":0,\"bytes\":[-1]}]}",
            "{\"content\":[{\"token\":\"x\",\"logprob\":0,\"bytes\":[1.5]}]}",
            "{\"content\":[{\"token\":\"x\",\"logprob\":0,\"bytes\":[\"1\"]}]}",
            "{\"content\":[{\"token\":\"x\",\"logprob\":0,\"top_logprobs\":[{\"token\":\"y\",\"logprob\":false}]}]}",
            "{\"content\":false}", "false"
        ]) {
            let fixedError = streamRegressionFixedError(codec, "{\"choices\":[{\"index\":0,\"message\":{\"content\":\"x\"},\"finish_reason\":\"stop\",\"logprobs\":" + payload + "}]}")
            let decoder = codec.newStreamDecoder()
            let streamError = streamRegressionError(decoder.push(("data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"x\"},\"finish_reason\":\"stop\",\"logprobs\":" + payload + "}]}\n\n").toArray()))
            @Expect(streamError.code, fixedError.code); @Expect(streamError.kind, fixedError.kind)
        }
    }

    @TestCase
    func chatOrphanLogprobsFailClosedAndEmptyArraysStayEmpty() {
        let codec = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect())
        let payload = "{\"content\":[{\"token\":\"x\",\"logprob\":0}]}"
        let fixedError = streamRegressionFixedError(codec, "{\"choices\":[{\"index\":0,\"message\":{},\"finish_reason\":\"stop\",\"logprobs\":" + payload + "}]}")
        let decoder = codec.newStreamDecoder()
        let _ = streamRegressionPush(decoder, "{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\",\"logprobs\":" + payload + "}]}")
        let streamError = streamRegressionError(decoder.push("data: [DONE]\n\n".toArray()))
        @Expect(streamError.code, "llm.chat_logprobs_without_content"); @Expect(streamError.code, fixedError.code)
        let empty = streamRegressionBytes(codec, "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"x\"},\"finish_reason\":\"stop\",\"logprobs\":{\"content\":[],\"refusal\":null}}]}\n\ndata: [DONE]\n\n", 1)
        match (empty.blocks[0]) { case LlmWireOutputBlock.Text(value) => @Expect(value.logprobs.size, 0); case _ => @Fail("expected text") }
    }

    @TestCase
    func chatLogprobRetentionIsBudgetedBeforeEmission() {
        let codec = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect())
        let decoder = codec.newStreamDecoder(limits: LlmWireStreamLimits(maxRetainedStateBytes: 16))
        let error = streamRegressionError(decoder.push("data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"x\"},\"logprobs\":{\"content\":[{\"token\":\"x\",\"logprob\":0}]}}]}\n\n".toArray()))
        @Expect(error.code, "llm.stream_retained_state_too_large"); @Expect(error.kind, LlmWireErrorKind.LimitExceeded)
    }

    @TestCase
    func chatTruncatedArgumentsAndContinuationMatchFixed() {
        let codec = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect())
        for (reason in ["length", "content_filter"]) {
            for (raw in ["{}", "{", "[]"]) {
                for (identity in ["complete", "missing-id", "missing-name", "missing-both"]) {
                    let id = if (identity == "complete" || identity == "missing-name") { "\"id\":\"c\"," } else { "" }
                    let name = if (identity == "complete" || identity == "missing-id") { "\"name\":\"f\"," } else { "" }
                    let call = id + "\"type\":\"function\",\"function\":{" + name + "\"arguments\":\"" + raw + "\"}"
                    let fixed = streamRegressionFixed(codec, "{\"choices\":[{\"index\":0,\"message\":{\"tool_calls\":[{" + call + "}]},\"finish_reason\":\"" + reason + "\"}]}")
                    let source = "data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0," + call + "}]},\"finish_reason\":\"" + reason + "\"}]}\n\ndata: [DONE]\n\n"
                    for (width in [1, 23, source.toArray().size]) {
                        let streamed = streamRegressionBytes(codec, source, width)
                        let expectedReason = if (reason == "length") { LlmWireIncompleteReason.Length } else { LlmWireIncompleteReason.ContentFilter }
                        for (reply in [fixed, streamed]) {
                            match (reply.choices[0].outcome) { case LlmWireChoiceOutcome.Incomplete(actual) => @Expect(actual, expectedReason); case _ => @Fail("truncation must remain incomplete") }
                            match (reply.blocks[0]) {
                                case LlmWireOutputBlock.ToolCall(value) =>
                                    @Expect(value.callId, if (identity == "complete" || identity == "missing-name") { "c" } else { "" })
                                    @Expect(value.name, if (identity == "complete" || identity == "missing-id") { "f" } else { "" })
                                    match (value.arguments) {
                                        case LlmWireToolArguments.Complete(value) => @Expect(raw, "{}"); @Expect(value.stringify(), raw)
                                        case LlmWireToolArguments.InvalidJson(value) => @Expect(raw, "{"); @Expect(value, raw)
                                        case LlmWireToolArguments.InvalidShape(value) => @Expect(raw, "[]"); @Expect(value.stringify(), raw)
                                        case _ => @Fail("fixed and stream must classify complete diagnostic arguments")
                                    }
                                case _ => @Fail("expected tool call")
                            }
                            match (reply.choices[0].toContinuationInput()) {
                                case LlmWireResult.Ok(messages) => @Expect(identity, "complete"); @Expect(raw, "{}"); @Expect(messages.size, 1)
                                case LlmWireResult.Err(error) => @Expect(error.code, if (identity != "complete") { "llm.tool_call_incomplete" } else { "llm.tool_arguments_not_executable" })
                            }
                        }
                    }
                }
            }
        }
    }

    @TestCase
    func chatTruncatedOptionalIdentityStillRejectsMalformedTypes() {
        let codec = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect())
        for (call in ["\"id\":1,\"function\":{\"arguments\":\"{}\"}", "\"function\":{\"name\":1,\"arguments\":\"{}\"}", "\"type\":1,\"function\":{\"arguments\":\"{}\"}", "\"type\":\"other\",\"function\":{\"arguments\":\"{}\"}", "\"type\":\"\",\"function\":{\"arguments\":\"{}\"}", "\"function\":false", "\"function\":{\"arguments\":1}"]) {
            let fixed = streamRegressionFixedError(codec, "{\"choices\":[{\"index\":0,\"message\":{\"tool_calls\":[{" + call + "}]},\"finish_reason\":\"length\"}]}")
            let decoder = codec.newStreamDecoder()
            let streamed = streamRegressionError(decoder.push(("data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0," + call + "}]},\"finish_reason\":\"length\"}]}\n\n").toArray()))
            @Expect(streamed.code, fixed.code); @Expect(streamed.kind, fixed.kind)
        }
        for (call in ["", "\"id\":null,\"type\":null,\"function\":null", "\"function\":{}", "\"function\":{\"arguments\":null}"]) {
            let fixed = streamRegressionFixed(codec, "{\"choices\":[{\"index\":0,\"message\":{\"tool_calls\":[{" + call + "}]},\"finish_reason\":\"length\"}]}")
            let indexedCall = if (call == "") { "\"index\":0" } else { "\"index\":0," + call }
            let source = "data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{" + indexedCall + "}]},\"finish_reason\":\"length\"}]}\n\ndata: [DONE]\n\n"
            let streamed = streamRegressionBytes(codec, source, 1)
            for (reply in [fixed, streamed]) {
                match (reply.blocks[0]) { case LlmWireOutputBlock.ToolCall(value) => match (value.arguments) { case LlmWireToolArguments.InvalidJson(raw) => @Expect(raw, ""); case _ => @Fail("missing arguments remain diagnostic") }; case _ => @Fail("expected diagnostic tool") }
                match (reply.choices[0].toContinuationInput()) { case LlmWireResult.Err(error) => @Expect(error.code, "llm.tool_call_incomplete"); case _ => @Fail("missing identity cannot enter continuation") }
            }
        }
        for (reason in ["stop", "tool_calls"]) {
            for (raw in ["{", "[]"]) {
                let call = "\"id\":\"c\",\"type\":\"function\",\"function\":{\"name\":\"f\",\"arguments\":\"" + raw + "\"}"
                let fixed = streamRegressionFixedError(codec, "{\"choices\":[{\"index\":0,\"message\":{\"tool_calls\":[{" + call + "}]},\"finish_reason\":\"" + reason + "\"}]}")
                let decoder = codec.newStreamDecoder()
                let _ = streamRegressionPush(decoder, "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0," + call + "}]},\"finish_reason\":\"" + reason + "\"}]}")
                let streamed = streamRegressionError(decoder.push("data: [DONE]\n\n".toArray()))
                @Expect(streamed.code, fixed.code); @Expect(streamed.code, "llm.tool_arguments_not_executable")
            }
        }
    }

}
