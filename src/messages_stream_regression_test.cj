package llm4cj

import std.unittest.*
import std.unittest.testmacro.*

@Test
class MessagesStreamRegressionTests {
    @TestCase
    func messagesServiceTierUsesUsageObjectForFixedAndStreamedReplies() {
        let cases: Array<(String, ?String)> = [("\"standard\"", Some("standard")), ("\"priority\"", Some("priority")), ("\"batch\"", Some("batch")), ("\"\"", Some("")), ("null", None), ("", None)]
        for (dialect in [anthropicMessagesDialect(), deepSeekMessagesDialect()]) {
            let codec = LlmWireCodec(LlmWireProtocol.Messages, dialect)
            for ((field, expected) in cases) {
                let tier = if (field == "") { "" } else { ",\"service_tier\":" + field }
                let fixed = streamRegressionFixed(codec, "{\"content\":[],\"stop_reason\":\"end_turn\",\"usage\":{\"input_tokens\":1,\"output_tokens\":2" + tier + "}}")
                @Expect(fixed.usage.serviceTier, expected)
                for (startTier in [false, true]) {
                    let initialTier = if (startTier) { tier } else { "" }
                    let finalTier = if (startTier) { "" } else { tier }
                    let source = "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":1" + initialTier + "}}}\n\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2" + finalTier + "}}\n\ndata: {\"type\":\"message_stop\"}\n\n"
                    let reply = streamRegressionBytes(codec, source, 1)
                    @Expect(reply.usage.serviceTier, expected)
                    streamRegressionUsageEqual(reply.usage, fixed.usage)
                }
            }
        }
    }

    @TestCase
    func messagesMisplacedServiceTierIsRejectedWithOrWithoutUsage() {
        for (dialect in [anthropicMessagesDialect(), deepSeekMessagesDialect()]) {
            let codec = LlmWireCodec(LlmWireProtocol.Messages, dialect)
            for (value in ["\"standard\"", "null", "1", "{}"]) {
                for (withUsage in [false, true]) {
                    let usage = if (withUsage) { ",\"usage\":{\"input_tokens\":2,\"output_tokens\":2,\"service_tier\":\"priority\"}" } else { "" }
                    let misplaced = "\"service_tier\":" + value + usage
                    let fixed = streamRegressionFixedError(codec, "{\"content\":[],\"stop_reason\":\"end_turn\"," + misplaced + "}")
                    @Expect(fixed.code, "llm.messages_usage_field_unsupported"); @Expect(fixed.kind, LlmWireErrorKind.Unsupported)
                    @Expect(fixed.diagnosticJson.isSome(), true)
                    let start = streamRegressionError(codec.newStreamDecoder().push(("data: {\"type\":\"message_start\",\"message\":{" + misplaced + "}}\n\n").toArray()))
                    @Expect(start.code, fixed.code); @Expect(start.kind, fixed.kind); @Expect(start.usage.isNone(), true)
                    let outerStart = streamRegressionError(codec.newStreamDecoder().push(("data: {\"type\":\"message_start\",\"service_tier\":" + value + ",\"message\":{\"id\":\"m\"" + usage + "}}\n\n").toArray()))
                    @Expect(outerStart.code, fixed.code); @Expect(outerStart.kind, fixed.kind); @Expect(outerStart.usage.isNone(), true)
                    let decoder = codec.newStreamDecoder()
                    let _ = streamRegressionPush(decoder, "{\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":1,\"service_tier\":\"standard\"}}}")
                    let delta = streamRegressionError(decoder.push(("data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}," + misplaced + "}\n\n").toArray()))
                    @Expect(delta.code, fixed.code); @Expect(delta.kind, fixed.kind)
                    @Expect(delta.usage.getOrThrow().serviceTier, Some("standard")); @Expect(delta.usage.getOrThrow().inputTokens, Some(1))
                    @Expect(delta.usage.getOrThrow().outputTokens.isNone(), true)
                }
            }
        }
    }

    @TestCase
    func messagesStartServiceTierCannotExceedRetainedBudget() {
        let codec = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect(), provider: "anthropic")
        for (tier in ["abcde", "ééa"]) {
            let decoder = codec.newStreamDecoder(limits: LlmWireStreamLimits(maxRetainedStateBytes: 4))
            let result = decoder.push(("data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"service_tier\":\"" + tier + "\",\"input_tokens\":10}}}\n\n").toArray())
            match (result) {
                case LlmWireResult.Err(error) => @Expect(error.code, "llm.stream_retained_state_too_large"); @Expect(error.kind, LlmWireErrorKind.LimitExceeded); @Expect(error.usage.isNone(), true)
                case LlmWireResult.Ok(_) =>
                    let _ = streamRegressionPush(decoder, "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}")
                    let reply = streamRegressionReply(streamRegressionPush(decoder, "{\"type\":\"message_stop\"}").terminal.getOrThrow())
                    @Expect(reply.usage.serviceTier, Some(tier))
                    @Fail("message_start retained a service tier larger than the configured state budget")
            }
        }
    }

    @TestCase
    func messagesDeltaServiceTierCannotExceedRetainedBudget() {
        let codec = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect(), provider: "anthropic")
        for (tier in ["abcde", "ééa"]) {
            let decoder = codec.newStreamDecoder(limits: LlmWireStreamLimits(maxRetainedStateBytes: 4))
            let _ = streamRegressionPush(decoder, "{\"type\":\"message_start\",\"message\":{\"usage\":{\"service_tier\":\"ok\",\"input_tokens\":10}}}")
            match (decoder.push(("data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"service_tier\":\"" + tier + "\",\"output_tokens\":1}}\n\n").toArray())) {
                case LlmWireResult.Err(error) =>
                    @Expect(error.code, "llm.stream_retained_state_too_large"); @Expect(error.kind, LlmWireErrorKind.LimitExceeded)
                    @Expect(error.usage.getOrThrow().inputTokens, Some(10)); @Expect(error.usage.getOrThrow().outputTokens.isNone(), true)
                    @Expect(error.usage.getOrThrow().serviceTier, Some("ok"))
                case LlmWireResult.Ok(update) =>
                    for (entry in update.events) { match (entry) { case LlmWireEvent.UsageUpdated(value) => @Expect(value.serviceTier, Some(tier)); case _ => () } }
                    @Fail("message_delta retained a service tier larger than the configured state budget")
            }
        }
    }

    @TestCase
    func messagesServiceTierBudgetUsesUtf8BytesAndOtherRetainedState() {
        let codec = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect(), provider: "anthropic")
        for (startTier in [false, true]) {
            for (tier in ["abcd", "éé"]) {
                let decoder = codec.newStreamDecoder(limits: LlmWireStreamLimits(maxRetainedStateBytes: 5))
                let initialTier = if (startTier) { ",\"service_tier\":\"" + tier + "\"" } else { "" }
                let _ = streamRegressionPush(decoder, "{\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"usage\":{\"input_tokens\":1" + initialTier + "}}}")
                let deltaTier = if (startTier) { "" } else { ",\"service_tier\":\"" + tier + "\"" }
                let _ = streamRegressionPush(decoder, "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1" + deltaTier + "}}")
                let reply = streamRegressionReply(streamRegressionPush(decoder, "{\"type\":\"message_stop\"}").terminal.getOrThrow())
                let fixed = streamRegressionFixed(codec, "{\"id\":\"m\",\"content\":[],\"stop_reason\":\"end_turn\",\"usage\":{\"service_tier\":\"" + tier + "\",\"input_tokens\":1,\"output_tokens\":1}}")
                streamRegressionUsageEqual(reply.usage, fixed.usage)
                @Expect(reply.usage.serviceTier, Some(tier))
                let overflow = codec.newStreamDecoder(limits: LlmWireStreamLimits(maxRetainedStateBytes: 5))
                let _ = streamRegressionPush(overflow, "{\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"usage\":{\"input_tokens\":1}}}")
                let error = streamRegressionError(overflow.push(("data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"service_tier\":\"" + tier + "a\",\"output_tokens\":1}}\n\n").toArray()))
                @Expect(error.code, "llm.stream_retained_state_too_large")
                @Expect(error.usage.getOrThrow().serviceTier.isNone(), true)
                @Expect(error.usage.getOrThrow().outputTokens.isNone(), true)
            }
        }
    }

    @TestCase
    func messagesServiceTierReplacementAccountsOnlyCurrentRetainedBytes() {
        let codec = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect(), provider: "anthropic")
        let expected = streamRegressionFixed(codec, "{\"content\":[],\"stop_reason\":\"end_turn\",\"usage\":{\"service_tier\":\"abcd\",\"input_tokens\":10,\"output_tokens\":6}}").usage
        for (overBudget in [false, true]) {
            let decoder = codec.newStreamDecoder(limits: LlmWireStreamLimits(maxRetainedStateBytes: 4))
            let _ = streamRegressionPush(decoder, "{\"type\":\"message_start\",\"message\":{\"usage\":{\"service_tier\":\"abcd\",\"input_tokens\":10,\"output_tokens\":0}}}")
            for ((tier, output) in [("abcd", 1), ("abcd", 2), ("wxyz", 3), ("a", 4), ("", 5), ("abcd", 6)]) {
                let update = streamRegressionPush(decoder, "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"service_tier\":\"" + tier + "\",\"output_tokens\":" + output.toString() + "}}")
                var usageSeen = false
                for (entry in update.events) { match (entry) { case LlmWireEvent.UsageUpdated(value) => usageSeen = true; @Expect(value.serviceTier, Some(tier)); @Expect(value.outputTokens, Some(output)); case _ => () } }
                @Expect(usageSeen, true)
            }
            if (overBudget) {
                let error = streamRegressionError(decoder.push("data: {\"type\":\"message_delta\",\"delta\":{},\"usage\":{\"service_tier\":\"abcde\",\"output_tokens\":7}}\n\n".toArray()))
                @Expect(error.code, "llm.stream_retained_state_too_large")
                streamRegressionUsageEqual(error.usage.getOrThrow(), expected)
            } else {
                streamRegressionUsageEqual(streamRegressionReply(streamRegressionPush(decoder, "{\"type\":\"message_stop\"}").terminal.getOrThrow()).usage, expected)
            }
        }
    }

    @TestCase
    func messagesRejectedUsageUpdateCannotPartiallyReplaceServiceTier() {
        let codec = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect(), provider: "anthropic")
        let expected = streamRegressionFixed(codec, "{\"content\":[],\"stop_reason\":\"end_turn\",\"usage\":{\"service_tier\":\"abcd\",\"input_tokens\":10,\"output_tokens\":3}}").usage
        for ((tier, input, code) in [("\"abcde\"", "9", "llm.usage_decreased"), ("\"abcde\"", "-1", "llm.usage_negative"), ("1", "11", "llm.field_type_invalid")]) {
            let decoder = codec.newStreamDecoder(limits: LlmWireStreamLimits(maxRetainedStateBytes: 4))
            let _ = streamRegressionPush(decoder, "{\"type\":\"message_start\",\"message\":{\"usage\":{\"service_tier\":\"abcd\",\"input_tokens\":10,\"output_tokens\":1}}}")
            let _ = streamRegressionPush(decoder, "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}")
            let _ = streamRegressionPush(decoder, "{\"type\":\"message_delta\",\"delta\":{},\"usage\":{\"service_tier\":null,\"output_tokens\":3}}")
            let error = streamRegressionError(decoder.push(("data: {\"type\":\"message_delta\",\"delta\":{},\"usage\":{\"service_tier\":" + tier + ",\"input_tokens\":" + input + ",\"output_tokens\":4}}\n\n").toArray()))
            @Expect(error.code, code)
            streamRegressionUsageEqual(error.usage.getOrThrow(), expected)
        }
    }

    @TestCase
    func messagesCompleteCumulativeUsageMatchesFixedAndAllTerminals() {
        let codec = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect(), provider: "anthropic")
        let finalUsage = "{\"service_tier\":\"standard\",\"input_tokens\":10,\"output_tokens\":2,\"cache_read_input_tokens\":20,\"cache_creation_input_tokens\":30,\"server_tool_use\":{\"web_search_requests\":2,\"web_fetch_requests\":1}}"
        let fixed = streamRegressionFixed(codec, "{\"id\":\"m\",\"model\":\"fixture\",\"content\":[],\"stop_reason\":\"end_turn\",\"usage\":" + finalUsage + "}")
        @Expect(fixed.usage.inputTokens, Some(10)); @Expect(fixed.usage.outputTokens, Some(2))
        @Expect(fixed.usage.cacheReadTokens, Some(20)); @Expect(fixed.usage.cacheWriteTokens, Some(30))
        @Expect(fixed.usage.webSearchRequests, Some(2)); @Expect(fixed.usage.webFetchRequests, Some(1))
        @Expect(fixed.usage.reasoningTokens.isNone(), true); @Expect(fixed.usage.totalTokens.isNone(), true)
        for (ending in ["stop", "cancel", "error", "eof"]) {
            let decoder = codec.newStreamDecoder()
            let _ = streamRegressionPush(decoder, "{\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"model\":\"fixture\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1,\"cache_read_input_tokens\":0,\"cache_creation_input_tokens\":0}}}")
            let update = streamRegressionPush(decoder, "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":" + finalUsage + "}")
            var observed = 0
            for (entry in update.events) { match (entry) { case LlmWireEvent.UsageUpdated(value) => streamRegressionUsageEqual(value, fixed.usage); observed++; case _ => () } }
            @Expect(observed, 1)
            let _ = streamRegressionPush(decoder, "{\"type\":\"message_delta\",\"delta\":{},\"usage\":{\"output_tokens\":2}}")
            match (ending) {
                case "stop" => streamRegressionUsageEqual(streamRegressionReply(streamRegressionPush(decoder, "{\"type\":\"message_stop\"}").terminal.getOrThrow()).usage, fixed.usage)
                case "cancel" => match (streamRegressionValue(decoder.cancel())) { case LlmWireTerminal.Cancelled(value) => streamRegressionUsageEqual(value.usage.getOrThrow(), fixed.usage); case _ => @Fail("expected cancellation") }
                case "error" => match (streamRegressionPush(decoder, "{\"type\":\"error\",\"error\":{\"message\":\"failed\",\"type\":\"api_error\"}}").terminal.getOrThrow()) { case LlmWireTerminal.ProviderFailed(value) => streamRegressionUsageEqual(value.usage.getOrThrow(), fixed.usage); case _ => @Fail("expected provider failure") }
                case _ => streamRegressionUsageEqual(streamRegressionError(decoder.finish()).usage.getOrThrow(), fixed.usage)
            }
        }
    }

    @TestCase
    func messagesUsageRejectsEveryNegativeOrDecreasingCounterAtomically() {
        let codec = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect(), provider: "anthropic")
        for (field in ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens", "web_search_requests", "web_fetch_requests"]) {
            for (number in ["-1", "0"]) {
                let decoder = codec.newStreamDecoder()
                let before = "{\"input_tokens\":1,\"output_tokens\":1,\"cache_read_input_tokens\":1,\"cache_creation_input_tokens\":1,\"server_tool_use\":{\"web_search_requests\":1,\"web_fetch_requests\":1}}"
                let _ = streamRegressionPush(decoder, "{\"type\":\"message_start\",\"message\":{\"usage\":" + before + "}}")
                let counter = "\"" + field + "\":" + number
                let next = if (field.startsWith("web_")) { "{\"input_tokens\":5,\"server_tool_use\":{" + counter + "}}" } else { "{" + counter + "}" }
                let error = streamRegressionError(decoder.push(("data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":" + next + "}\n\n").toArray()))
                @Expect(error.code, if (number == "-1") { "llm.usage_negative" } else { "llm.usage_decreased" })
                let expected = streamRegressionFixed(codec, "{\"content\":[],\"stop_reason\":\"end_turn\",\"usage\":" + before + "}").usage
                streamRegressionUsageEqual(error.usage.getOrThrow(), expected)
            }
        }
    }

    @TestCase
    func messagesLateZeroRemainsReportedWhileMissingCountersRemainUnknown() {
        let codec = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect(), provider: "anthropic")
        let source = "data: {\"type\":\"message_start\",\"message\":{}}\n\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"input_tokens\":0,\"cache_read_input_tokens\":0,\"server_tool_use\":{\"web_fetch_requests\":0}}}\n\ndata: {\"type\":\"message_stop\"}\n\n"
        let fixed = streamRegressionFixed(codec, "{\"content\":[],\"stop_reason\":\"end_turn\",\"usage\":{\"input_tokens\":0,\"cache_read_input_tokens\":0,\"server_tool_use\":{\"web_fetch_requests\":0}}}")
        for (width in [1, 19, source.toArray().size]) {
            let reply = streamRegressionBytes(codec, source, width)
            streamRegressionUsageEqual(reply.usage, fixed.usage)
            @Expect(reply.usage.cacheReadAvailability, LlmWireUsageAvailability.Reported)
            @Expect(reply.usage.cacheWriteAvailability, LlmWireUsageAvailability.Unknown)
            @Expect(reply.usage.outputTokens.isNone(), true); @Expect(reply.usage.webSearchRequests.isNone(), true)
        }
    }

}
