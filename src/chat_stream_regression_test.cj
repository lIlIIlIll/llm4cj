package llm4cj

import std.unittest.*
import std.unittest.testmacro.*

@Test
class ChatStreamRegressionTests {
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
