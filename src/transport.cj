package llm4cj

import std.collection.*
import std.convert.*
import std.io.*
import std.deriving.Derive

@Derive[Equatable]
public enum LlmWireErrorKind {
    InvalidWire | InvalidRequest | Unsupported | InvalidState |
    Http | BodyLimit | LimitExceeded | Sse | Cancelled | Deadline | Transport
}

@Derive[Equatable]
public enum LlmTransportPhase {
    Encode | Request | ResponseHeaders | StreamFraming | WireDecode | SemanticAssembly | Transport
}

public class LlmWireError <: Exception {
    public let kind: LlmWireErrorKind
    public let code: String
    public let retryable: Bool
    public let httpStatus: ?Int64
    public let retryAfterMillis: ?Int64
    public let provider: String
    public let providerErrorCode: String
    public let providerErrorType: String
    public let diagnosticJson: ?String
    public let phase: ?LlmTransportPhase
    public let protocol: ?LlmWireProtocol
    public let dialectId: String
    public let eventType: String
    public let blockIndex: Int64
    public let toolCallId: String
    public let providerRequestId: String
    public init(
        kind: LlmWireErrorKind, code: String, message: String,
        retryable!: Bool = false, httpStatus!: ?Int64 = None,
        retryAfterMillis!: ?Int64 = None, provider!: String = "",
        providerErrorCode!: String = "", providerErrorType!: String = "",
        diagnosticJson!: ?String = None, phase!: ?LlmTransportPhase = None,
        protocol!: ?LlmWireProtocol = None, dialectId!: String = "",
        eventType!: String = "", blockIndex!: Int64 = -1,
        toolCallId!: String = "", providerRequestId!: String = ""
    ) {
        super(message)
        this.kind = kind; this.code = code; this.retryable = retryable
        this.httpStatus = httpStatus; this.retryAfterMillis = retryAfterMillis
        this.provider = provider; this.providerErrorCode = providerErrorCode
        this.providerErrorType = providerErrorType
        this.diagnosticJson = diagnosticJson
        this.phase = phase; this.protocol = protocol; this.dialectId = dialectId
        this.eventType = eventType; this.blockIndex = blockIndex; this.toolCallId = toolCallId
        this.providerRequestId = providerRequestId
    }
}

public enum LlmWireResult<T> {
    Ok(T) | Err(LlmWireError)
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

public class LlmWireSseLimits {
    public let maxEventBytes: Int64
    public let maxLineBytes: Int64
    public let maxBufferedBytes: Int64
    public let maxEventsPerPush: Int64
    public let maxOutputBytesPerPush: Int64
    public let maxErrorBodyBytes: Int64
    public init(
        maxEventBytes!: Int64 = 8388608, maxLineBytes!: Int64 = 1048576,
        maxBufferedBytes!: Int64 = 16777216, maxEventsPerPush!: Int64 = 1024,
        maxOutputBytesPerPush!: Int64 = 16777216, maxErrorBodyBytes!: Int64 = 8388608
    ) {
        if (maxEventBytes < 1 || maxLineBytes < 1 || maxBufferedBytes < 1 || maxEventsPerPush < 1 || maxOutputBytesPerPush < 1 || maxErrorBodyBytes < 1) {
            throw IllegalArgumentException("invalid SSE limits")
        }
        this.maxEventBytes = maxEventBytes; this.maxLineBytes = maxLineBytes
        this.maxBufferedBytes = maxBufferedBytes; this.maxEventsPerPush = maxEventsPerPush
        this.maxOutputBytesPerPush = maxOutputBytesPerPush; this.maxErrorBodyBytes = maxErrorBodyBytes
    }
}

public class SseDecoder {
    private let maxEventBytes: Int64
    private let maxLineBytes: Int64
    private let maxBufferedBytes: Int64
    private let maxEventsPerPush: Int64
    private let maxOutputBytesPerPush: Int64
    private let line = ArrayList<Byte>()
    private let dataLines = ArrayList<String>()
    private var dataLinesBytes: Int64 = 0
    private var eventType = ""
    private var eventTypeBytes: Int64 = 0
    private var lastEventId = ""
    private var lastEventIdBytes: Int64 = 0
    private var lastRetry: ?Int64 = None
    private var hasDataField = false
    private var eventBytes: Int64 = 0
    private var sawCarriageReturn = false
    private var firstLine = true
    private var closed = false
    private var failed = false
    private var pushOutputBytes: Int64 = 0

    public init(maxEventBytes!: Int64 = 8388608, maxLineBytes!: Int64 = 1048576, maxBufferedBytes!: Int64 = 16777216, maxEventsPerPush!: Int64 = 1024, maxOutputBytesPerPush!: Int64 = 16777216) {
        if (maxEventBytes < 1 || maxLineBytes < 1 || maxBufferedBytes < 1 || maxEventsPerPush < 1 || maxOutputBytesPerPush < 1) { throw IllegalArgumentException("invalid SSE limits") }
        this.maxEventBytes = maxEventBytes; this.maxBufferedBytes = maxBufferedBytes
        this.maxLineBytes = maxLineBytes; this.maxEventsPerPush = maxEventsPerPush; this.maxOutputBytesPerPush = maxOutputBytesPerPush
    }

    public func push(chunk: String): LlmWireResult<Array<SseEvent>> { push(chunk.toArray()) }

    public func push(chunk: Array<Byte>): LlmWireResult<Array<SseEvent>> {
        if (failed) { return llmFailure<Array<SseEvent>>(LlmWireErrorKind.InvalidState, "llm.sse_failed", "SSE decoder is poisoned by an earlier error") }
        if (closed) { return llmFailure<Array<SseEvent>>(LlmWireErrorKind.InvalidState, "llm.sse_closed", "SSE decoder is closed") }
        let output = ArrayList<SseEvent>()
        pushOutputBytes = 0
        try {
            for (byte in chunk) {
                if (sawCarriageReturn) {
                    sawCarriageReturn = false
                    if (byte == 10) {
                        eventBytes++
                        enforceLimits(output)
                        processLine(output)
                        continue
                    }
                    processLine(output)
                }
                if (byte == 13) { eventBytes++; enforceLimits(output); sawCarriageReturn = true }
                else if (byte == 10) { eventBytes++; enforceLimits(output); processLine(output) }
                else { line.add(byte); eventBytes++; enforceLimits(output) }
            }
            LlmWireResult.Ok(output.toArray())
        } catch (error: LlmWireError) { failed = true; LlmWireResult.Err(error) }
        catch (error: Exception) { failed = true; llmFailure<Array<SseEvent>>(LlmWireErrorKind.Sse, "llm.sse_utf8_invalid", error.message) }
    }

    public func finish(): LlmWireResult<Array<SseEvent>> {
        if (failed) { return llmFailure<Array<SseEvent>>(LlmWireErrorKind.InvalidState, "llm.sse_failed", "SSE decoder is poisoned by an earlier error") }
        if (closed) { return llmFailure<Array<SseEvent>>(LlmWireErrorKind.InvalidState, "llm.sse_closed", "SSE decoder is closed") }
        pushOutputBytes = 0
        let output = ArrayList<SseEvent>()
        try {
            if (sawCarriageReturn) { sawCarriageReturn = false; processLine(output) }
            closed = true
            line.clear()
            resetEvent()
            LlmWireResult.Ok(output.toArray())
        } catch (error: LlmWireError) { failed = true; LlmWireResult.Err(error) }
        catch (error: Exception) { failed = true; llmFailure<Array<SseEvent>>(LlmWireErrorKind.Sse, "llm.sse_utf8_invalid", error.message) }
    }

    private func processLine(output: ArrayList<SseEvent>): Unit {
        enforceLimits(output)
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
                let emitted = SseEvent(if (eventType == "") { "message" } else { eventType }, builder.toString(), lastEventId, lastRetry)
                pushOutputBytes += Int64(emitted.data.toArray().size + emitted.event.toArray().size + emitted.id.toArray().size)
                output.add(emitted)
                enforceLimits(output)
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
            case "data" => hasDataField = true; dataLines.add(value); dataLinesBytes += Int64(value.toArray().size)
            case "event" => eventType = value; eventTypeBytes = Int64(value.toArray().size)
            case "id" => if (!value.contains("\u{0000}")) { lastEventId = value; lastEventIdBytes = Int64(value.toArray().size) }
            case "retry" => match (parseSseRetryMillis(value)) { case Some(found) => lastRetry = Some(found); case None => () }
            case _ => ()
        }
        enforceLimits(output)
    }

    private func enforceLimits(output: ArrayList<SseEvent>): Unit {
        if (eventBytes > maxEventBytes) { throw LlmWireError(LlmWireErrorKind.LimitExceeded, "llm.sse_event_too_large", "SSE event exceeds configured limit") }
        if (line.size > maxLineBytes) { throw LlmWireError(LlmWireErrorKind.LimitExceeded, "llm.sse_line_too_large", "SSE line exceeds configured limit") }
        let retained = Int64(line.size) + dataLinesBytes + eventTypeBytes + lastEventIdBytes
        if (retained > maxBufferedBytes) { throw LlmWireError(LlmWireErrorKind.LimitExceeded, "llm.sse_buffer_too_large", "SSE parser retention exceeds configured limit") }
        if (output.size > maxEventsPerPush) { throw LlmWireError(LlmWireErrorKind.LimitExceeded, "llm.sse_output_too_large", "SSE push produced too many events") }
        if (pushOutputBytes > maxOutputBytesPerPush) { throw LlmWireError(LlmWireErrorKind.LimitExceeded, "llm.sse_output_bytes_too_large", "SSE push produced too many output bytes") }
    }

    private func resetEvent(): Unit {
        dataLines.clear(); dataLinesBytes = 0; eventType = ""; eventTypeBytes = 0
        hasDataField = false; eventBytes = 0
    }
}

public func parseSseRetryMillis(value: String): ?Int64 { parseUnsignedDecimal(value) }

public func parseRetryAfterMillis(value: String, nowEpochMillis: Int64): ?Int64 {
    let text = value.trimAscii()
    match (parseUnsignedDecimal(text)) {
        case Some(seconds) => if (seconds > Int64.Max / 1000) { Some(Int64.Max) } else { Some(seconds * 1000) }
        case None => match (parseHttpDateEpochMillis(text, nowEpochMillis)) {
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

public func readLlmHttpBody(stream: InputStream, declaredSize: ?Int64, maxBytes: Int64): LlmWireResult<Array<Byte>> {
    if (maxBytes < 1) { return llmFailure<Array<Byte>>(LlmWireErrorKind.BodyLimit, "llm.body_limit_invalid", "response body limit must be positive") }
    match (declaredSize) {
        case Some(value) => if (value < 0 || value > maxBytes) { return llmFailure<Array<Byte>>(LlmWireErrorKind.BodyLimit, "llm.body_too_large", "provider response exceeds configured limit") }
        case None => ()
    }
    try {
        let output = ArrayList<Byte>(); let buffer = Array<Byte>(8192, repeat: 0)
        while (true) {
            let count = stream.read(buffer)
            if (count <= 0) { break }
            if (Int64(output.size) + count > maxBytes) { return llmFailure<Array<Byte>>(LlmWireErrorKind.BodyLimit, "llm.body_too_large", "provider response exceeds configured limit") }
            for (index in 0..count) { output.add(buffer[index]) }
        }
        LlmWireResult.Ok(output.toArray())
    } catch (error: Exception) { llmFailure<Array<Byte>>(LlmWireErrorKind.Transport, "llm.body_read_failed", error.message) }
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

func parseHttpDateEpochMillis(text: String, nowEpochMillis: Int64): ?Int64 {
    try {
        match (text.indexOf(",")) {
            case Some(index) =>
                let rest = text[index + 1..].trimAscii()
                if (rest.contains("-")) { parseRfc850Date(rest, nowEpochMillis) } else { parseImfDate(rest) }
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

func parseRfc850Date(rest: String, nowEpochMillis: Int64): ?Int64 {
    let parts = nonEmptyParts(rest, " ")
    if (parts.size != 3 || parts[2] != "GMT") { return None }
    let date = parts[0].split("-")
    if (date.size != 3) { return None }
    let shortYear = Int64.parse(date[2])
    if (shortYear < 0 || shortYear > 99) { return None }
    let currentYear = yearAtEpochMillis(nowEpochMillis)
    var year = (currentYear / 100) * 100 + shortYear
    if (year > currentYear + 50) { year -= 100 }
    dateEpochMillis(year, monthNumber(date[1]), Int64.parse(date[0]), parts[1])
}

func yearAtEpochMillis(epochMillis: Int64): Int64 {
    if (epochMillis <= 0) { return 1970 }
    let z = epochMillis / 1000 / 86400 + 719468
    let era = z / 146097
    let dayOfEra = z - era * 146097
    let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146096) / 365
    var year = yearOfEra + era * 400
    let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
    let monthPrime = (5 * dayOfYear + 2) / 153
    let month = monthPrime + if (monthPrime < 10) { 3 } else { -9 }
    if (month <= 2) { year++ }
    year
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

func llmFailure<T>(kind: LlmWireErrorKind, code: String, message: String): LlmWireResult<T> {
    LlmWireResult.Err(LlmWireError(kind, code, message))
}
