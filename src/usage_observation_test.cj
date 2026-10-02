package llm4cj

import std.unittest.*
import std.unittest.testmacro.*

@Test
class UsageObservationTests {
    @TestCase
    func missingCacheUsageRemainsUnknown() {
        let codec = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect(), provider: "openai")
        let usage = decodeResponsesUsage(codec, parseWireJson("{\"usage\":{\"input_tokens\":100,\"output_tokens\":1}}"))
        @Expect(usage.cacheReadTokens.isNone(), true)
        @Expect(usage.cacheReadAvailability, LlmWireUsageAvailability.Unknown)
        @Expect(usage.cacheWriteAvailability, LlmWireUsageAvailability.Unknown)
        @Expect(usage.source, LlmWireUsageSource.ProviderReported("openai", "openai.responses.v1"))
        @Expect(observedWireUsage(LlmWireUsage()).isNone(), true)
    }

    @TestCase
    func providerZeroIsReportedAndSurvivesMerging() {
        let codec = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect(), provider: "anthropic")
        let usage = decodeMessagesUsage(codec, parseWireJson("{\"usage\":{\"input_tokens\":100,\"cache_read_input_tokens\":0,\"cache_creation_input_tokens\":0}}"))
        let merged = mergeWireUsage(usage, LlmWireUsage(outputTokens: Some(1)), LlmWireUsageMergeStyle.ReplacePresent)
        @Expect(merged.cacheReadTokens, Some(0))
        @Expect(merged.cacheWriteTokens, Some(0))
        @Expect(merged.cacheReadAvailability, LlmWireUsageAvailability.Reported)
        @Expect(merged.cacheWriteAvailability, LlmWireUsageAvailability.Reported)
        @Expect(merged.source, usage.source)
    }

    @TestCase
    func observedUsageRetainedWithFailure() {
        let codec = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect(), provider: "kimi")
        let usage = decodeChatUsage(codec, parseWireJson("{\"usage\":{\"prompt_tokens\":200,\"completion_tokens\":2,\"prompt_tokens_details\":{\"cached_tokens\":128}}}"))
        let failure = withObservedUsage(LlmWireError(LlmWireErrorKind.Http, "llm.http_error", "provider rejected update", httpStatus: Some(400)), observedWireUsage(usage))
        match (failure.usage) {
            case Some(value) =>
                @Expect(value.cacheReadTokens, Some(128))
                @Expect(value.cacheReadAvailability, LlmWireUsageAvailability.Reported)
                @Expect(value.cacheWriteAvailability, LlmWireUsageAvailability.Unknown)
                @Expect(value.source, usage.source)
            case None => @Fail("failure discarded observed usage")
        }
        @Expect(failure.httpStatus, Some(400))
        @Expect(withObservedUsage(failure, None).usage.getOrThrow().cacheReadTokens, Some(128))
    }

    @TestCase
    func fixedProviderRejectionRetainsUsageAndHttpMetadata() {
        let codec = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect(), provider: "openai")
        let body = "{\"error\":{\"message\":\"unsupported native update\",\"code\":\"unsupported_update\",\"type\":\"invalid_request_error\"},\"usage\":{\"input_tokens\":99,\"input_tokens_details\":{\"cached_tokens\":0}}}"
        match (codec.decodeResponse(LlmWireHttpResponse(400, [LlmWireHeader("x-request-id", "request-1")], body.toArray()))) {
            case LlmWireResult.Ok(LlmWireResponseState.Terminal(LlmWireTerminal.ProviderFailed(failure))) =>
                @Expect(failure.providerErrorCode, "unsupported_update")
                @Expect(failure.message, "unsupported native update")
                @Expect(failure.httpStatus, Some(400))
                @Expect(failure.providerRequestId, "request-1")
                match (failure.usage) {
                    case Some(value) => @Expect(value.inputTokens, Some(99)); @Expect(value.cacheReadTokens, Some(0))
                    case None => @Fail("HTTP context lost reported usage")
                }
            case _ => @Fail("expected actual provider rejection")
        }
        let generic = failureWithObservedUsage(LlmWireFailure(LlmWireFailureKind.ProviderError, "failed", usage: Some(LlmWireUsage(inputTokens: Some(5)))), None)
        @Expect(generic.usage.getOrThrow().inputTokens, Some(5))
    }

    @TestCase
    func nonSuccessHttpRetainsUsageAcrossResponsesStates() {
        let codec = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect(), provider: "openai")
        for (status in ["completed", "queued", "in_progress", "cancelled", "failed", "unknown"]) {
            let body = "{\"status\":\"" + status + "\",\"output\":[],\"usage\":{\"input_tokens\":77,\"input_tokens_details\":{\"cached_tokens\":0}}}"
            match (codec.decodeResponse(LlmWireHttpResponse(429, [LlmWireHeader("x-request-id", "request-2"), LlmWireHeader("retry-after", "2")], body.toArray()))) {
                case LlmWireResult.Ok(LlmWireResponseState.Terminal(LlmWireTerminal.ProviderFailed(failure))) =>
                    @Expect(failure.httpStatus, Some(429))
                    @Expect(failure.retryable, true)
                    @Expect(failure.retryAfterMillis, Some(2000))
                    @Expect(failure.providerRequestId, "request-2")
                    match (failure.usage) {
                        case Some(value) =>
                            @Expect(value.inputTokens, Some(77))
                            @Expect(value.cacheReadTokens, Some(0))
                            @Expect(value.source, LlmWireUsageSource.ProviderReported("openai", "openai.responses.v1"))
                        case None => @Fail("HTTP failure discarded usage from decoded state")
                    }
                case _ => @Fail("non-success HTTP must remain a failure")
            }
        }
    }

    @TestCase
    func streamedErrorAndCancellationKeepPreviouslyReportedUsage() {
        let codec = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect(), provider: "anthropic")
        for (cancelled in [false, true]) {
            let decoder = codec.newStreamDecoder()
            let _ = decoder.push(event("{\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":123,\"cache_read_input_tokens\":64}}}"))
            let terminal = if (cancelled) { decoder.cancel().getForUsageTest() } else {
                decoder.push(event("{\"type\":\"error\",\"error\":{\"message\":\"native tools rejected\",\"type\":\"invalid_request_error\"}}")).terminal.getOrThrow()
            }
            let failure = match (terminal) {
                case LlmWireTerminal.ProviderFailed(value) => value
                case LlmWireTerminal.Cancelled(value) => value
                case _ => throw IllegalStateException("expected failure or cancellation")
            }
            match (failure.usage) {
                case Some(value) =>
                    @Expect(value.inputTokens, Some(123))
                    @Expect(value.cacheReadTokens, Some(64))
                    @Expect(value.cacheWriteAvailability, LlmWireUsageAvailability.Unknown)
                    @Expect(value.source, LlmWireUsageSource.ProviderReported("anthropic", "anthropic.messages.v1"))
                case None => @Fail("stream terminal discarded previously observed usage")
            }
        }
    }

    @TestCase
    func responsesCompletionKeepsPreviouslyReportedCounters() {
        let codec = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect(), provider: "openai")
        let decoder = codec.newStreamDecoder()
        let _ = decoder.push(event("{\"type\":\"response.created\",\"response\":{\"id\":\"r\",\"model\":\"fixture\",\"usage\":{\"input_tokens\":10,\"input_tokens_details\":{\"cached_tokens\":0}}}}"))
        let update = decoder.push(event("{\"type\":\"response.completed\",\"response\":{\"id\":\"r\",\"model\":\"fixture\",\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}],\"usage\":{\"output_tokens\":3}}}"))
        match (update.terminal) {
            case Some(LlmWireTerminal.Completed(reply)) =>
                @Expect(reply.usage.inputTokens, Some(10))
                @Expect(reply.usage.cacheReadTokens, Some(0))
                @Expect(reply.usage.outputTokens, Some(3))
                @Expect(reply.usage.cacheReadAvailability, LlmWireUsageAvailability.Reported)
                @Expect(reply.usage.source, LlmWireUsageSource.ProviderReported("openai", "openai.responses.v1"))
                @Expect(reply.responseId, "r"); @Expect(reply.model, "fixture")
                @Expect(reply.rawStopReason, "completed"); @Expect(reply.blocks.size, 1)
            case _ => @Fail("completion must retain earlier observed counters")
        }
        var usageEvents = 0
        for (entry in update.events) { match (entry) {
            case LlmWireEvent.UsageUpdated(value) =>
                usageEvents++
                @Expect(value.inputTokens, Some(10)); @Expect(value.cacheReadTokens, Some(0)); @Expect(value.outputTokens, Some(3))
            case _ => ()
        } }
        @Expect(usageEvents, 1)
    }

    @TestCase
    func responsesStreamFailureKeepsEarlierUsageAndRejectsMismatchedTerminal() {
        let codec = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect(), provider: "openai")
        for (status in ["failed", "cancelled"]) {
            let decoder = codec.newStreamDecoder()
            let _ = decoder.push(event("{\"type\":\"response.created\",\"response\":{\"id\":\"r\",\"status\":\"in_progress\",\"usage\":{\"input_tokens\":101,\"input_tokens_details\":{\"cached_tokens\":64}}}}"))
            let update = decoder.push(("data: {\"type\":\"response.failed\",\"response\":{\"id\":\"r\",\"status\":\"" + status + "\"}}\n\n").toArray())
            if (status == "failed") {
                match (update) {
                    case LlmWireResult.Ok(value) => match (value.terminal) {
                      case Some(LlmWireTerminal.ProviderFailed(failure)) =>
                        @Expect(failure.usage.getOrThrow().inputTokens, Some(101))
                        @Expect(failure.usage.getOrThrow().cacheReadTokens, Some(64))
                      case _ => @Fail("provider failure must retain earlier stream usage")
                    }
                    case _ => @Fail("expected a provider failure terminal")
                }
            } else {
                match (update) {
                    case LlmWireResult.Err(error) =>
                        @Expect(error.code, "llm.responses_terminal_mismatch")
                        @Expect(error.usage.getOrThrow().inputTokens, Some(101))
                        @Expect(error.usage.getOrThrow().cacheReadTokens, Some(64))
                    case _ => @Fail("event/status mismatch must fail with observed usage")
                }
            }
        }
    }
}

extend LlmWireResult<LlmWireTerminal> {
    func getForUsageTest(): LlmWireTerminal {
        match (this) { case LlmWireResult.Ok(value) => value; case LlmWireResult.Err(error) => throw error }
    }
}
