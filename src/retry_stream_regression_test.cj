package llm4cj

import std.unittest.*
import std.unittest.testmacro.*

@Test
class RetryStreamRegressionTests {
    @TestCase
    func retryDecimalThresholdAndSaturatedSuffixRemainStrict() {
        for ((text, expected) in [
            ("9223372036854775799", 9223372036854775799),
            ("9223372036854775800", 9223372036854775800),
            ("9223372036854775806", 9223372036854775806),
            ("9223372036854775807", Int64.Max),
            ("9223372036854775808", Int64.Max),
            ("92233720368547758080", Int64.Max),
            ("92233720368547758087", Int64.Max),
            ("92233720368547758089", Int64.Max)
        ]) {
            @Expect(parseSseRetryMillis(text), Some(expected))
            @Expect(parseRetryAfterMillis(text, 0), Some(Int64.Max))
            for (suffix in ["/", ":", "x", "+", "-", "x0", "/9", ":0"]) {
                @Expect(parseSseRetryMillis(text + suffix).isNone(), true)
                @Expect(parseRetryAfterMillis(text + suffix, 0).isNone(), true)
            }
        }
        @Expect(parseSseRetryMillis("00000000000000000000000000000001"), Some(1))
        let decoder = SseDecoder()
        let events = streamRegressionValue(decoder.push("retry: 9\ndata: first\n\nretry: 92233720368547758080/\ndata: second\n\nretry: 92233720368547758087:\ndata: third\n\n".toArray()))
        @Expect(events.size, 3)
        for (entry in events) { @Expect(entry.retryMillis, Some(9)) }
    }

    @TestCase
    func retryOverflowStillValidatesEveryDigit() {
        for (valid in ["9223372036854775807", "9223372036854775808", "999999999999999999999999999999999999"]) {
            @Expect(parseSseRetryMillis(valid), Some(Int64.Max)); @Expect(parseRetryAfterMillis(valid, 0), Some(Int64.Max))
            for (invalid in ["x" + valid, valid + "x", valid + "x0", "+" + valid, "-" + valid, valid + ".0"]) {
                @Expect(parseSseRetryMillis(invalid).isNone(), true); @Expect(parseRetryAfterMillis(invalid, 0).isNone(), true)
            }
        }
        for (invalid in ["", "+1", "-1", "1x2", " 1", "1 ", "\t1", "１"]) { @Expect(parseSseRetryMillis(invalid).isNone(), true) }
        @Expect(parseSseRetryMillis("0"), Some(0)); @Expect(parseRetryAfterMillis(" 1 ", 0), Some(1000))
        let decoder = SseDecoder()
        let events = streamRegressionValue(decoder.push("retry: 7\ndata: first\n\nretry: 9223372036854775808x\ndata: second\n\n".toArray()))
        @Expect(events.size, 2); @Expect(events[0].retryMillis, Some(7)); @Expect(events[1].retryMillis, Some(7))
    }
}
