package llm4cj

import std.unittest.*
import std.unittest.testmacro.*

@Test
class MessagesStreamRegressionTests {
    @TestCase
    func messagesCompleteCumulativeUsageMatchesFixedAndAllTerminals() {
        let codec = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect(), provider: "anthropic")
        let finalUsage = "{\"input_tokens\":10,\"output_tokens\":2,\"cache_read_input_tokens\":20,\"cache_creation_input_tokens\":30,\"server_tool_use\":{\"web_search_requests\":2,\"web_fetch_requests\":1}}"
        let fixed = streamRegressionFixed(codec, "{\"id\":\"m\",\"model\":\"fixture\",\"content\":[],\"stop_reason\":\"end_turn\",\"service_tier\":\"standard\",\"usage\":" + finalUsage + "}")
        @Expect(fixed.usage.inputTokens, Some(10)); @Expect(fixed.usage.outputTokens, Some(2))
        @Expect(fixed.usage.cacheReadTokens, Some(20)); @Expect(fixed.usage.cacheWriteTokens, Some(30))
        @Expect(fixed.usage.webSearchRequests, Some(2)); @Expect(fixed.usage.webFetchRequests, Some(1))
        @Expect(fixed.usage.reasoningTokens.isNone(), true); @Expect(fixed.usage.totalTokens.isNone(), true)
        for (ending in ["stop", "cancel", "error", "eof"]) {
            let decoder = codec.newStreamDecoder()
            let _ = streamRegressionPush(decoder, "{\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"model\":\"fixture\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1,\"cache_read_input_tokens\":0,\"cache_creation_input_tokens\":0}}}")
            let update = streamRegressionPush(decoder, "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"service_tier\":\"standard\",\"usage\":" + finalUsage + "}")
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
