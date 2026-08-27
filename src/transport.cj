package llm4cj

import std.collection.*
import std.convert.*
import std.io.*

public enum LlmTransportErrorKind {
    InvalidWire | InvalidRequest | Unsupported | InvalidState |
    Http | BodyLimit | Sse | Cancelled | Deadline | Transport
}

public class LlmTransportError <: Exception {
    public let kind: LlmTransportErrorKind
    public let code: String
    public let retryable: Bool
    public let httpStatus: ?Int64
    public let retryAfterMillis: ?Int64
    public let provider: String
    public let providerErrorCode: String
    public let providerErrorType: String
    public init(
        kind: LlmTransportErrorKind, code: String, message: String,
        retryable!: Bool = false, httpStatus!: ?Int64 = None,
        retryAfterMillis!: ?Int64 = None, provider!: String = "",
        providerErrorCode!: String = "", providerErrorType!: String = ""
    ) {
        super(message)
        this.kind = kind; this.code = code; this.retryable = retryable
        this.httpStatus = httpStatus; this.retryAfterMillis = retryAfterMillis
        this.provider = provider; this.providerErrorCode = providerErrorCode
        this.providerErrorType = providerErrorType
    }
}

public enum LlmResult<T> {
    Ok(T) | Err(LlmTransportError)
    public func isOk(): Bool { match (this) { case Ok(_) => true; case Err(_) => false } }
}

public class SseEvent {
    public let event: String
    public let data: String
    public let id: String
    public let retryMillis: ?Int64
    public init(event: String, data: String, id: String, retryMillis: ?Int64) {
        this.event = event; this.data = data; this.id = id; this.retryMillis = retryMillis
    }
}

public class SseDecoder {
    private let maxEventBytes: Int64
    private let maxBufferedBytes: Int64
    private let line = ArrayList<Byte>()
    private let dataLines = ArrayList<String>()
    private var eventType = ""
    private var lastEventId = ""
    private var lastRetry: ?Int64 = None
    private var hasDataField = false
    private var eventBytes: Int64 = 0
    private var sawCarriageReturn = false
    private var firstLine = true
    private var closed = false

    public init(maxEventBytes!: Int64 = 8388608, maxBufferedBytes!: Int64 = 16777216) {
        if (maxEventBytes < 1 || maxBufferedBytes < maxEventBytes) { throw IllegalArgumentException("invalid SSE limits") }
        this.maxEventBytes = maxEventBytes; this.maxBufferedBytes = maxBufferedBytes
    }

    public func push(chunk: String): LlmResult<Array<SseEvent>> { push(chunk.toArray()) }

    public func push(chunk: Array<Byte>): LlmResult<Array<SseEvent>> {
        if (closed) { return llmFailure<Array<SseEvent>>(LlmTransportErrorKind.InvalidState, "llm.sse_closed", "SSE decoder is closed") }
        let output = ArrayList<SseEvent>()
        try {
            for (byte in chunk) {
                if (sawCarriageReturn) {
                    sawCarriageReturn = false
                    if (byte == 10) { continue }
                }
                if (byte == 13) { processLine(output); sawCarriageReturn = true }
                else if (byte == 10) { processLine(output) }
                else { line.add(byte); eventBytes++; enforceLimits() }
            }
            LlmResult.Ok(output.toArray())
        } catch (error: LlmTransportError) { LlmResult.Err(error) }
        catch (error: Exception) { llmFailure<Array<SseEvent>>(LlmTransportErrorKind.Sse, "llm.sse_utf8_invalid", error.message) }
    }

    public func finish(): LlmResult<Array<SseEvent>> {
        if (closed) { return llmFailure<Array<SseEvent>>(LlmTransportErrorKind.InvalidState, "llm.sse_closed", "SSE decoder is closed") }
        closed = true
        line.clear()
        resetEvent()
        LlmResult.Ok([])
    }

    private func processLine(output: ArrayList<SseEvent>): Unit {
        eventBytes++
        enforceLimits()
        var raw = String.fromUtf8(line.toArray())
        line.clear()
        if (firstLine) {
            firstLine = false
            if (raw.startsWith("\u{feff}")) { raw = raw[3..] }
        }
        if (raw == "") {
            if (hasDataField) {
                let builder = StringBuilder()
                for (index in 0..dataLines.size) {
                    if (index > 0) { builder.append("\n") }
                    builder.append(dataLines[index])
                }
                output.add(SseEvent(if (eventType == "") { "message" } else { eventType }, builder.toString(), lastEventId, lastRetry))
            }
            resetEvent()
            return
        }
        if (raw.startsWith(":")) { return }
        let colon = raw.indexOf(":")
        let name: String
        var value: String
        match (colon) {
            case Some(index) => name = raw[..index]; value = raw[index + 1..]
            case None => name = raw; value = ""
        }
        if (value.startsWith(" ")) { value = value[1..] }
        match (name) {
            case "data" => hasDataField = true; dataLines.add(value)
            case "event" => eventType = value
            case "id" => if (!value.contains("\u{0000}")) { lastEventId = value }
            case "retry" => match (parseSseRetryMillis(value)) { case Some(found) => lastRetry = Some(found); case None => () }
            case _ => ()
        }
    }

    private func enforceLimits(): Unit {
        if (eventBytes > maxEventBytes) { throw LlmTransportError(LlmTransportErrorKind.BodyLimit, "llm.sse_event_too_large", "SSE event exceeds configured limit") }
        if (eventBytes > maxBufferedBytes) { throw LlmTransportError(LlmTransportErrorKind.BodyLimit, "llm.sse_buffer_too_large", "SSE buffer exceeds configured limit") }
    }

    private func resetEvent(): Unit {
        dataLines.clear(); eventType = ""
        hasDataField = false; eventBytes = 0
    }
}

public func parseSseRetryMillis(value: String): ?Int64 { parseUnsignedDecimal(value.trimAscii()) }

public func parseRetryAfterMillis(value: String, nowEpochMillis: Int64): ?Int64 {
    let text = value.trimAscii()
    match (parseUnsignedDecimal(text)) {
        case Some(seconds) => if (seconds > Int64.Max / 1000) { Some(Int64.Max) } else { Some(seconds * 1000) }
        case None => match (parseHttpDateEpochMillis(text)) {
            case Some(epoch) => if (epoch <= nowEpochMillis) { Some(0) } else { Some(epoch - nowEpochMillis) }
            case None => None
        }
    }
}

public func extractRetryAfterMillis(headers: String, nowEpochMillis: Int64): ?Int64 {
    var result: ?Int64 = None
    for (line in headers.replace("\r\n", "\n").split("\n")) {
        let trimmed = line.trimAscii()
        if (trimmed.toAsciiLower().startsWith("retry-after:")) {
            match (parseRetryAfterMillis(trimmed[12..], nowEpochMillis)) {
                case Some(value) => result = match (result) { case Some(current) => Some(max(current, value)); case None => Some(value) }
                case None => ()
            }
        }
    }
    result
}

public func sseDataLine(line: String): ?String {
    if (!line.startsWith("data:")) { return None }
    var value = line[5..]
    if (value.startsWith(" ")) { value = value[1..] }
    Some(value)
}

public func readLlmHttpBody(stream: InputStream, declaredSize: ?Int64, maxBytes: Int64): LlmResult<Array<Byte>> {
    if (maxBytes < 1) { return llmFailure<Array<Byte>>(LlmTransportErrorKind.BodyLimit, "llm.body_limit_invalid", "response body limit must be positive") }
    match (declaredSize) {
        case Some(value) => if (value < 0 || value > maxBytes) { return llmFailure<Array<Byte>>(LlmTransportErrorKind.BodyLimit, "llm.body_too_large", "provider response exceeds configured limit") }
        case None => ()
    }
    try {
        let output = ArrayList<Byte>(); let buffer = Array<Byte>(8192, repeat: 0)
        while (true) {
            let count = stream.read(buffer)
            if (count <= 0) { break }
            if (Int64(output.size) + count > maxBytes) { return llmFailure<Array<Byte>>(LlmTransportErrorKind.BodyLimit, "llm.body_too_large", "provider response exceeds configured limit") }
            for (index in 0..count) { output.add(buffer[index]) }
        }
        LlmResult.Ok(output.toArray())
    } catch (error: Exception) { llmFailure<Array<Byte>>(LlmTransportErrorKind.Transport, "llm.body_read_failed", error.message) }
}

func parseUnsignedDecimal(text: String): ?Int64 {
    if (text == "") { return None }
    var result: Int64 = 0
    for (byte in text.toArray()) {
        if (byte < 48 || byte > 57) { return None }
        let digit = Int64(byte - 48)
        if (result > (Int64.Max - digit) / 10) { return Some(Int64.Max) }
        result = result * 10 + digit
    }
    Some(result)
}

func parseHttpDateEpochMillis(text: String): ?Int64 {
    try {
        match (text.indexOf(",")) {
            case Some(index) =>
                let rest = text[index + 1..].trimAscii()
                if (rest.contains("-")) { parseRfc850Date(rest) } else { parseImfDate(rest) }
            case None => parseAsctimeDate(text)
        }
    } catch (_: Exception) { None }
}

func nonEmptyParts(text: String, separator: String): Array<String> {
    let output = ArrayList<String>()
    for (value in text.split(separator) where value != "") { output.add(value) }
    output.toArray()
}

func parseImfDate(rest: String): ?Int64 {
    let parts = nonEmptyParts(rest, " ")
    if (parts.size != 5 || parts[4] != "GMT") { return None }
    dateEpochMillis(Int64.parse(parts[2]), monthNumber(parts[1]), Int64.parse(parts[0]), parts[3])
}

func parseRfc850Date(rest: String): ?Int64 {
    let parts = nonEmptyParts(rest, " ")
    if (parts.size != 3 || parts[2] != "GMT") { return None }
    let date = parts[0].split("-")
    if (date.size != 3) { return None }
    let shortYear = Int64.parse(date[2])
    dateEpochMillis(if (shortYear >= 70) { 1900 + shortYear } else { 2000 + shortYear }, monthNumber(date[1]), Int64.parse(date[0]), parts[1])
}

func parseAsctimeDate(text: String): ?Int64 {
    let parts = nonEmptyParts(text, " ")
    if (parts.size != 5) { return None }
    dateEpochMillis(Int64.parse(parts[4]), monthNumber(parts[1]), Int64.parse(parts[2]), parts[3])
}

func dateEpochMillis(year: Int64, month: Int64, day: Int64, clock: String): ?Int64 {
    if (year < 1970 || year > 9999 || month < 1 || month > 12 || day < 1 || day > daysInMonth(year, month)) { return None }
    let time = clock.split(":")
    if (time.size != 3) { return None }
    let hour = Int64.parse(time[0]); let minute = Int64.parse(time[1]); let second = Int64.parse(time[2])
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59 || second < 0 || second > 59) { return None }
    var days: Int64 = 0
    for (current in 1970..year) { days += if (isLeapYear(current)) { 366 } else { 365 } }
    for (current in 1..month) { days += daysInMonth(year, current) }
    days += day - 1
    let seconds = days * 86400 + hour * 3600 + minute * 60 + second
    if (seconds > Int64.Max / 1000) { Some(Int64.Max) } else { Some(seconds * 1000) }
}

func monthNumber(value: String): Int64 {
    match (value) {
        case "Jan" => 1; case "Feb" => 2; case "Mar" => 3; case "Apr" => 4
        case "May" => 5; case "Jun" => 6; case "Jul" => 7; case "Aug" => 8
        case "Sep" => 9; case "Oct" => 10; case "Nov" => 11; case "Dec" => 12
        case _ => 0
    }
}

func daysInMonth(year: Int64, month: Int64): Int64 {
    match (month) { case 2 => if (isLeapYear(year)) { 29 } else { 28 }; case 4 | 6 | 9 | 11 => 30; case _ => 31 }
}
func isLeapYear(year: Int64): Bool { year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) }

func llmFailure<T>(kind: LlmTransportErrorKind, code: String, message: String): LlmResult<T> {
    LlmResult.Err(LlmTransportError(kind, code, message))
}
