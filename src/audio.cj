package llm4cj

import std.collection.*
import std.deriving.Derive
import yjson.*

const AUDIO_MAX_BYTES: Int64 = 4194304

@Derive[Equatable]
public enum LlmWireAudioFormat { Wav | Mp3 | Aac | Flac | Opus | Pcm16 }
@Derive[Equatable]
public enum LlmWireAudioVoice { Alloy | Ash | Ballad | Coral | Echo | Fable | Nova | Onyx | Sage | Shimmer | Verse | Marin | Cedar }
@Derive[Equatable]
public enum LlmWireAudioCompletion { Complete | Partial }

public class LlmWireAudioInputBlock {
    public let format: LlmWireAudioFormat
    private let data: Array<Byte>
    private init(format: LlmWireAudioFormat, data: Array<Byte>) { this.format = format; this.data = copyValues(data) }
    public static func fromBytes(format: LlmWireAudioFormat, bytes: Array<Byte>): LlmWireResult<LlmWireAudioInputBlock> {
        if (format != LlmWireAudioFormat.Wav && format != LlmWireAudioFormat.Mp3) {
            return LlmWireResult.Err(LlmWireError(LlmWireErrorKind.Unsupported, "llm.audio_input_format_unsupported", "audio input supports WAV and MP3"))
        }
        if (bytes.isEmpty()) { return LlmWireResult.Err(LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.audio_input_empty", "audio input must not be empty")) }
        if (bytes.size > AUDIO_MAX_BYTES) { return LlmWireResult.Err(audioLimit()) }
        LlmWireResult.Ok(LlmWireAudioInputBlock(format, bytes))
    }
    public prop bytes: Array<Byte> { get() { copyValues(data) } }
    func audioBytes(): Array<Byte> { data }
}

public class LlmWireAudioOutputOptions {
    public let format: LlmWireAudioFormat
    public let voice: LlmWireAudioVoice
    public init(format: LlmWireAudioFormat, voice: LlmWireAudioVoice) { this.format = format; this.voice = voice }
}

public class LlmWireAudioCapabilities {
    private let inputValue: Array<LlmWireAudioFormat>
    private let fixedValue: Array<LlmWireAudioFormat>
    private let streamValue: Array<LlmWireAudioFormat>
    private let voicesValue: Array<LlmWireAudioVoice>
    public let assistantReplay: Bool
    public init(inputFormats!: Array<LlmWireAudioFormat> = [], fixedOutputFormats!: Array<LlmWireAudioFormat> = [],
        streamOutputFormats!: Array<LlmWireAudioFormat> = [], voices!: Array<LlmWireAudioVoice> = [], assistantReplay!: Bool = false) {
        if (hasDuplicate(inputFormats) || hasDuplicate(fixedOutputFormats) || hasDuplicate(streamOutputFormats) || hasDuplicate(voices)) {
            throw IllegalArgumentException("audio capabilities must not contain duplicate values")
        }
        this.inputValue = copyValues(inputFormats); this.fixedValue = copyValues(fixedOutputFormats)
        this.streamValue = copyValues(streamOutputFormats); this.voicesValue = copyValues(voices); this.assistantReplay = assistantReplay
    }
    public prop inputFormats: Array<LlmWireAudioFormat> { get() { copyValues(inputValue) } }
    public prop fixedOutputFormats: Array<LlmWireAudioFormat> { get() { copyValues(fixedValue) } }
    public prop streamOutputFormats: Array<LlmWireAudioFormat> { get() { copyValues(streamValue) } }
    public prop voices: Array<LlmWireAudioVoice> { get() { copyValues(voicesValue) } }
}

public class LlmWireResponseContext {
    public let protocol: LlmWireProtocol
    public let dialectId: String
    public let provider: String
    public let model: String
    public let requestedAudioFormat: ?LlmWireAudioFormat
    init(codec: LlmWireCodec, request: LlmWireRequest) {
        this.protocol = codec.protocol; this.dialectId = codec.dialect.compatibilityId; this.provider = codec.provider; this.model = request.model
        this.requestedAudioFormat = match (request.audioOutput) { case Some(value) => Some(value.format); case None => None }
    }
}

public class LlmWireAssistantAudioReplayBlock {
    public let format: LlmWireAudioFormat
    public let id: String
    public let transcript: String
    public let expiresAtEpochSeconds: Int64
    public let provider: String
    public let model: String
    private let data: Array<Byte>
    public let blockOrder: Int64
    init(format: LlmWireAudioFormat, id: String, transcript: String, expiry: Int64, provider: String, model: String, data: Array<Byte>, blockOrder: Int64) {
        this.format = format; this.id = id; this.transcript = transcript; this.expiresAtEpochSeconds = expiry
        this.provider = provider; this.model = model; this.data = data; this.blockOrder = blockOrder
    }
    public prop bytes: Array<Byte> { get() { copyValues(data) } }
    func audioBytes(): Array<Byte> { data }
}

public class LlmWireAudioOutputBlock {
    public let format: LlmWireAudioFormat
    public let id: String
    public let transcript: String
    public let expiresAtEpochSeconds: Int64
    public let completion: LlmWireAudioCompletion
    private let data: Array<Byte>
    let replay: ?LlmWireAssistantAudioReplayBlock
    init(format: LlmWireAudioFormat, id: String, transcript: String, expiry: Int64, data: Array<Byte>, context: LlmWireResponseContext, complete: Bool, blockOrder: Int64) {
        this.format = format; this.id = id; this.transcript = transcript; this.expiresAtEpochSeconds = expiry; this.data = data
        this.completion = if (complete) { LlmWireAudioCompletion.Complete } else { LlmWireAudioCompletion.Partial }
        this.replay = if (complete) { Some(LlmWireAssistantAudioReplayBlock(format, id, transcript, expiry, context.provider, context.model, data, blockOrder)) } else { None }
    }
    public prop bytes: Array<Byte> { get() { copyValues(data) } }
    func audioBytes(): Array<Byte> { data }
}

func audioLimit(): LlmWireError { LlmWireError(LlmWireErrorKind.LimitExceeded, "llm.audio_too_large", "decoded audio exceeds the 4 MiB limit") }
func audioFormatName(value: LlmWireAudioFormat): String {
    match (value) { case LlmWireAudioFormat.Wav => "wav"; case LlmWireAudioFormat.Mp3 => "mp3"; case LlmWireAudioFormat.Aac => "aac"; case LlmWireAudioFormat.Flac => "flac"; case LlmWireAudioFormat.Opus => "opus"; case LlmWireAudioFormat.Pcm16 => "pcm16" }
}
func parseAudioFormat(value: String): LlmWireAudioFormat {
    match (value) { case "wav" => LlmWireAudioFormat.Wav; case "mp3" => LlmWireAudioFormat.Mp3; case "aac" => LlmWireAudioFormat.Aac; case "flac" => LlmWireAudioFormat.Flac; case "opus" => LlmWireAudioFormat.Opus; case "pcm16" => LlmWireAudioFormat.Pcm16
        case _ => unsupportedRequest("llm.audio_format_unsupported", "unknown audio format") }
}
func audioVoiceName(value: LlmWireAudioVoice): String {
    match (value) { case LlmWireAudioVoice.Alloy => "alloy"; case LlmWireAudioVoice.Ash => "ash"; case LlmWireAudioVoice.Ballad => "ballad"; case LlmWireAudioVoice.Coral => "coral"; case LlmWireAudioVoice.Echo => "echo"; case LlmWireAudioVoice.Fable => "fable"; case LlmWireAudioVoice.Nova => "nova"; case LlmWireAudioVoice.Onyx => "onyx"; case LlmWireAudioVoice.Sage => "sage"; case LlmWireAudioVoice.Shimmer => "shimmer"; case LlmWireAudioVoice.Verse => "verse"; case LlmWireAudioVoice.Marin => "marin"; case LlmWireAudioVoice.Cedar => "cedar" }
}

// Each JSON data value is one canonical RFC 4648 segment. No cross-field
// carry, whitespace, URL alphabet, non-zero pad bits, or decode fallback.
func audioBase64Size(value: String, remaining: Int64, streaming!: Bool = false): Int64 {
    let n = Int64(value.size)
    if (n > 5592408) { throw audioLimit() }
    if (n % 4 != 0) {
        if (streaming) { unsupportedRequest("llm.audio_framing_unsupported", "audio data must contain a complete base64 segment in each JSON field") }
        invalidWire("llm.audio_base64_invalid", "audio base64 length must be a multiple of four")
    }
    if (n == 0) { return 0 }
    if ((n / 4) * 3 - 2 > remaining) { throw audioLimit() }
    let padding: Int64 = if (value[n - 2] == 61u8) { 2 } else if (value[n - 1] == 61u8) { 1 } else { 0 }
    let size = (n / 4) * 3 - padding
    if (size > remaining) { throw audioLimit() }
    for (index in 0..n - padding) { let _ = audioBase64Digit(value[index]) }
    for (index in n - padding..n where value[index] != 61u8) { invalidWire("llm.audio_base64_invalid", "audio base64 padding is invalid") }
    if ((padding == 2 && (audioBase64Digit(value[n - 3]) & 15u32) != 0u32) ||
        (padding == 1 && (audioBase64Digit(value[n - 2]) & 3u32) != 0u32)) { invalidWire("llm.audio_base64_invalid", "audio base64 has non-zero padding bits") }
    size
}
func audioBase64Digit(value: Byte): UInt32 {
    if (value >= 65u8 && value <= 90u8) { return UInt32(value - 65u8) }
    if (value >= 97u8 && value <= 122u8) { return UInt32(value - 97u8) + 26u32 }
    if (value >= 48u8 && value <= 57u8) { return UInt32(value - 48u8) + 52u32 }
    if (value == 43u8) { return 62u32 }
    if (value == 47u8) { return 63u32 }
    invalidWire("llm.audio_base64_invalid", "audio base64 contains an invalid character")
}
func decodeAudioBase64(value: String, size: Int64): Array<Byte> {
    let input = value; let output = Array<Byte>(size, repeat: 0)
    var cursor: Int64 = 0
    for (offset in 0..input.size : 4) {
        var bits: UInt32 = 0
        for (index in 0..4) { bits = (bits << 6) | if (input[offset + index] == 61u8) { 0u32 } else { audioBase64Digit(input[offset + index]) } }
        for (shift in [16u32, 8u32, 0u32] where cursor < size) { output[cursor] = UInt8((bits >> shift) & 255u32); cursor++ }
    }
    output
}
func encodeAudioBase64(input: Array<Byte>): String {
    if (input.size > AUDIO_MAX_BYTES) { throw audioLimit() }
    let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".toArray()
    let output = Array<Byte>(((input.size + 2) / 3) * 4, repeat: 61u8)
    var target: Int64 = 0
    for (offset in 0..input.size : 3) {
        let count = min(3, input.size - offset)
        var bits = UInt32(input[offset]) << 16
        if (count > 1) { bits = bits | (UInt32(input[offset + 1]) << 8) }
        if (count > 2) { bits = bits | UInt32(input[offset + 2]) }
        output[target] = alphabet[Int64((bits >> 18) & 63u32)]; output[target + 1] = alphabet[Int64((bits >> 12) & 63u32)]
        if (count > 1) { output[target + 2] = alphabet[Int64((bits >> 6) & 63u32)] }
        if (count > 2) { output[target + 3] = alphabet[Int64(bits & 63u32)] }
        target += 4
    }
    String.fromUtf8(output)
}

func requireAudioDialect(codec: LlmWireCodec): Unit {
    if (codec.dialect.compatibilityId != "openai.chat.v1") { unsupportedRequest("llm.audio_dialect_unsupported", "audio is supported only by OpenAI Chat Completions") }
}
func validateAudioContext(codec: LlmWireCodec, context: ?LlmWireResponseContext): Unit {
    match (context) {
        case Some(value) =>
            if (value.protocol != codec.protocol || value.dialectId != codec.dialect.compatibilityId || value.provider != codec.provider) { unsupportedRequest("llm.audio_context_mismatch", "response context belongs to a different codec") }
            match (codec.modelProfile) { case Some(profile) => if (profile.model != value.model) { unsupportedRequest("llm.audio_context_mismatch", "response context belongs to a different requested model") }; case None => () }
        case None => ()
    }
}
func requireAudioContext(codec: LlmWireCodec, context: ?LlmWireResponseContext, streaming: Bool): LlmWireResponseContext {
    requireAudioDialect(codec); validateAudioContext(codec, context)
    let value = match (context) { case Some(found) => found; case None => throw LlmWireError(LlmWireErrorKind.InvalidState, "llm.audio_context_required", "audio decoding requires prepared request response context") }
    let format = match (value.requestedAudioFormat) { case Some(found) => found; case None => unsupportedRequest("llm.audio_output_unrequested", "response contains unrequested audio") }
    let formats = if (streaming) { codec.capabilities.audio.streamOutputFormats } else { codec.capabilities.audio.fixedOutputFormats }
    if (!containsAudioFormat(formats, format)) { unsupportedRequest("llm.audio_output_format_unsupported", "model capability does not declare this audio output format") }
    value
}
func containsAudioFormat(values: Array<LlmWireAudioFormat>, value: LlmWireAudioFormat): Bool { for (entry in values where entry == value) { return true }; false }

func validateAudioRequest(codec: LlmWireCodec, request: LlmWireRequest, streaming: Bool, anyOutputMode!: Bool = false): Unit {
    var size: Int64 = 0
    for (item in request.transcript.items) { match (item) { case LlmWireInputItem.Message(message) =>
        var replaySeen = false
        for (blockIndex in 0..message.blocks.size) { match (message.blocks[blockIndex]) {
            case LlmWireBlock.AudioInput(value) =>
                requireAudioDialect(codec)
                if (message.role != LlmWireRole.User) { unsupportedRequest("llm.audio_input_role_invalid", "audio input must belong to a user message") }
                var audioModality = false
                for (modality in codec.capabilities.input.modalities where modality == LlmWireInputModality.Audio) { audioModality = true }
                if (!audioModality) { unsupportedRequest("llm.audio_input_capability_missing", "audio input requires the audio modality capability") }
                if (!containsAudioFormat(codec.capabilities.audio.inputFormats, value.format)) { unsupportedRequest("llm.audio_input_capability_missing", "model capability does not declare this audio input format") }
                if (value.audioBytes().size > AUDIO_MAX_BYTES - size) { throw audioLimit() }; size += value.audioBytes().size
            case LlmWireBlock.AudioReplay(value) =>
                requireAudioDialect(codec)
                if (message.role != LlmWireRole.Assistant || replaySeen) { unsupportedRequest("llm.audio_replay_position_invalid", "one audio replay is allowed in each assistant message") }
                if (value.blockOrder != blockIndex || blockIndex != message.blocks.size - 1) { unsupportedRequest("llm.audio_replay_position_invalid", "audio replay must retain its canonical final block order") }
                for (before in 0..blockIndex) { match (message.blocks[before]) { case LlmWireBlock.Text(_) => (); case _ => unsupportedRequest("llm.audio_replay_position_invalid", "audio replay can follow only canonical text content") } }
                replaySeen = true
                if (!codec.capabilities.audio.assistantReplay) { unsupportedRequest("llm.audio_replay_capability_missing", "model capability does not declare assistant audio replay") }
                if (value.provider != codec.provider || value.model != request.model) { unsupportedRequest("llm.audio_replay_origin_mismatch", "audio replay must retain its provider and requested model") }
            case _ => ()
        } }
        case _ => ()
    } }
    match (request.audioOutput) { case Some(value) =>
        requireAudioDialect(codec)
        let formats = if (streaming) { codec.capabilities.audio.streamOutputFormats } else { codec.capabilities.audio.fixedOutputFormats }
        if (!containsAudioFormat(formats, value.format) && !(anyOutputMode && containsAudioFormat(codec.capabilities.audio.streamOutputFormats, value.format))) { unsupportedRequest("llm.audio_output_format_unsupported", "model capability does not declare this audio output format") }
        var voiceFound = false
        for (voice in codec.capabilities.audio.voices where voice == value.voice) { voiceFound = true }
        if (!voiceFound) { unsupportedRequest("llm.audio_voice_unsupported", "model capability does not declare this audio voice") }
        match (request.structuredOutput) { case LlmWireStructuredOutput.ProviderDefault | LlmWireStructuredOutput.Text => (); case _ => unsupportedRequest("llm.audio_structured_output_unsupported", "audio cannot be combined with structured output") }
        case None => ()
    }
}

func audioReplayDeadlines(request: LlmWireRequest): Array<Int64> {
    let deadlines = ArrayList<Int64>()
    for (item in request.transcript.items) { match (item) { case LlmWireInputItem.Message(message) => for (block in message.blocks) { match (block) {
        case LlmWireBlock.AudioReplay(value) => deadlines.add(value.expiresAtEpochSeconds)
        case _ => ()
    } }; case _ => () } }
    deadlines.toArray()
}
func validateAudioReplayClock(deadlines: Array<Int64>, now: ?Int64): Unit {
    for (expiry in deadlines) {
            let current = match (now) { case Some(found) => found; case None => throw LlmWireError(LlmWireErrorKind.InvalidState, "llm.audio_replay_clock_required", "audio replay requires an explicit current Unix time in seconds") }
            if (current < 0) { unsupportedRequest("llm.audio_replay_clock_invalid", "audio replay time must be non-negative") }
            if (current >= expiry) { throw LlmWireError(LlmWireErrorKind.InvalidState, "llm.audio_replay_expired", "audio replay has expired") }
    }
}

func audioFields(codec: LlmWireCodec, raw: JsonNode): Unit {
    for (field in raw.fields) {
        if (field.name != "id" && field.name != "data" && field.name != "transcript" && field.name != "expires_at") {
            unsupportedSemantic(codec, field.name, field.value, "llm.audio_field_unsupported")
        }
    }
}

func decodeFixedChatAudio(codec: LlmWireCodec, raw: JsonNode, context: ?LlmWireResponseContext, complete: Bool, remaining: Int64, blockOrder: Int64): LlmWireAudioOutputBlock {
    let bound = requireAudioContext(codec, context, false)
    let audio = wireObject(raw, "Chat audio", provider: codec.provider); audioFields(codec, audio)
    let id = wireRequiredString(audio, "id", provider: codec.provider)
    if (id == "") { invalidWire("llm.audio_id_missing", "audio requires a non-empty ID") }
    let encoded = wireRequiredString(audio, "data", provider: codec.provider)
    let size = audioBase64Size(encoded, remaining)
    let transcript = wireRequiredString(audio, "transcript", provider: codec.provider)
    let expiry = wireRequiredInt(audio, "expires_at", provider: codec.provider)
    if (expiry < 0) { invalidWire("llm.audio_expiry_invalid", "audio expiry must be non-negative") }
    LlmWireAudioOutputBlock(bound.requestedAudioFormat.getOrThrow(), id, transcript, expiry,
        decodeAudioBase64(encoded, size), bound, complete, blockOrder)
}

class ChatAudioState {
    var observed = false
    var id: ?String = None
    var expiry: ?Int64 = None
    var transcriptObserved = false
    var dataObserved = false
    let data = ArrayList<Byte>()
    let transcript = StringBuilder()

    func push(codec: LlmWireCodec, raw: JsonNode, context: ?LlmWireResponseContext, budget: StreamBudget,
        events: ArrayList<LlmWireEvent>, identity: LlmWireEventIdentity): Unit {
        let _ = requireAudioContext(codec, context, true)
        let audio = wireObject(raw, "Chat audio delta", provider: codec.provider); audioFields(codec, audio)
        if (expiry.isSome()) { invalidWire("llm.audio_after_expiry", "audio data appeared after its expiry update") }
        let nextId = wireOptionalString(audio, "id", provider: codec.provider)
        let nextTranscript = wireOptionalString(audio, "transcript", provider: codec.provider)
        let encoded = wireOptionalString(audio, "data", provider: codec.provider)
        let nextExpiry = wireOptionalInt(audio, "expires_at", provider: codec.provider)
        match (nextId) { case Some(value) =>
            if (value == "" || (id.isSome() && id != nextId)) { invalidWire("llm.audio_id_mismatch", "audio ID must be non-empty and immutable") }
            case None => ()
        }
        match (nextExpiry) { case Some(value) => if (value < 0) { invalidWire("llm.audio_expiry_invalid", "audio expiry must be non-negative") }; case None => () }
        let size = match (encoded) { case Some(value) => audioBase64Size(value, AUDIO_MAX_BYTES - data.size, streaming: true); case None => 0 }
        budget.audio(size)
        match (nextId) { case Some(value) => if (id.isNone()) { budget.retain(value) }; case None => () }
        match (nextTranscript) { case Some(value) => budget.semantic(value, "text"); case None => () }
        if (!observed) { budget.block(); observed = true; events.add(LlmWireEvent.ContentBlockStarted(LlmWireStreamBlockKind.Audio, identity)) }
        match (nextId) { case Some(value) => id = Some(value); events.add(LlmWireEvent.AudioIdObserved(value, identity)); case None => () }
        match (encoded) { case Some(value) =>
            let bytes = decodeAudioBase64(value, size); data.add(all: bytes); dataObserved = true
            events.add(LlmWireEvent.AudioDataDelta(LlmWireAudioChunk(bytes), identity))
            case None => ()
        }
        match (nextTranscript) { case Some(value) => transcriptObserved = true; transcript.append(value); events.add(LlmWireEvent.AudioTranscriptDelta(value, identity)); case None => () }
        match (nextExpiry) { case Some(value) =>
            expiry = Some(value); events.add(LlmWireEvent.AudioExpiryObserved(value, identity))
            events.add(LlmWireEvent.ContentBlockCompleted(LlmWireStreamBlockKind.Audio, identity))
            case None => ()
        }
    }
    func materialize(codec: LlmWireCodec, context: ?LlmWireResponseContext, complete: Bool, blockOrder: Int64): LlmWireAudioOutputBlock {
        let bound = requireAudioContext(codec, context, true)
        if (id.isNone() || expiry.isNone() || !transcriptObserved || !dataObserved) { invalidWire("llm.audio_metadata_missing", "audio must observe ID, data, transcript and expiry before DONE") }
        LlmWireAudioOutputBlock(bound.requestedAudioFormat.getOrThrow(), id.getOrThrow(), transcript.toString(),
            expiry.getOrThrow(), data.toArray(), bound, complete, blockOrder)
    }
}

public class LlmWireAudioChunk {
    private let data: Array<Byte>
    init(data: Array<Byte>) { this.data = data }
    public prop bytes: Array<Byte> { get() { copyValues(data) } }
}

func transcriptHasAudio(transcript: LlmWireTranscript): Bool {
    for (item in transcript.items) { match (item) { case LlmWireInputItem.Message(message) => for (block in message.blocks) { match (block) {
        case LlmWireBlock.AudioInput(_) | LlmWireBlock.AudioReplay(_) => return true
        case _ => ()
    } }; case _ => () } }
    false
}
func validateSnapshotAudioMessage(role: LlmWireRole, blocks: Array<LlmWireBlock>): Unit {
    for (index in 0..blocks.size) { match (blocks[index]) {
        case LlmWireBlock.AudioInput(_) => if (role != LlmWireRole.User) { snapshotInvalid("audio input requires a user message") }
        case LlmWireBlock.AudioReplay(value) =>
            if (role != LlmWireRole.Assistant || value.blockOrder != index || index != blocks.size - 1) { snapshotInvalid("audio replay must retain its final assistant block order") }
            for (before in 0..index) { match (blocks[before]) { case LlmWireBlock.Text(_) => (); case _ => snapshotInvalid("audio replay can follow only text content") } }
        case _ => ()
    } }
}
func preflightAudioSnapshot(transcript: LlmWireTranscript): Unit {
    var remaining = LLM_JSON_MAX_BYTES
    for (item in transcript.items) { match (item) { case LlmWireInputItem.Message(message) =>
        validateSnapshotAudioMessage(message.role, message.blocks)
        for (block in message.blocks) {
        let bytes = match (block) { case LlmWireBlock.AudioInput(value) => value.audioBytes().size; case LlmWireBlock.AudioReplay(value) => value.audioBytes().size; case _ => 0 }
        let encoded = ((bytes + 2) / 3) * 4
        if (encoded > remaining) { throw transcriptSnapshotLimit() }; remaining -= encoded
    }; case _ => () } }
}
func snapshotAudioInput(value: LlmWireAudioInputBlock): JsonNode {
    wireJsonObject([WireJsonField("format", wireJsonString(audioFormatName(value.format))), WireJsonField("data", wireJsonString(encodeAudioBase64(value.audioBytes())))])
}
func restoreAudioInput(value: JsonNode): LlmWireAudioInputBlock {
    snapshotFields(value, ["format", "data"])
    let format = parseAudioFormat(wireRequiredString(value, "format")); let encoded = wireRequiredString(value, "data")
    let bytes = decodeAudioBase64(encoded, audioBase64Size(encoded, AUDIO_MAX_BYTES))
    match (LlmWireAudioInputBlock.fromBytes(format, bytes)) { case LlmWireResult.Ok(audio) => audio; case LlmWireResult.Err(error) => throw error }
}
func snapshotAudioReplay(value: LlmWireAssistantAudioReplayBlock): JsonNode {
    wireJsonObject([
        WireJsonField("protocol", wireJsonString("chat_completions")), WireJsonField("dialect_id", wireJsonString("openai.chat.v1")),
        WireJsonField("format", wireJsonString(audioFormatName(value.format))), WireJsonField("data", wireJsonString(encodeAudioBase64(value.audioBytes()))),
        WireJsonField("id", wireJsonString(value.id)), WireJsonField("transcript", wireJsonString(value.transcript)),
        WireJsonField("expires_at", wireJsonNumber(value.expiresAtEpochSeconds.toString())), WireJsonField("provider", wireJsonString(value.provider)),
        WireJsonField("model", wireJsonString(value.model)), WireJsonField("block_order", wireJsonNumber(value.blockOrder.toString()))
    ])
}
func restoreAudioReplay(value: JsonNode): LlmWireAssistantAudioReplayBlock {
    snapshotFields(value, ["protocol", "dialect_id", "format", "data", "id", "transcript", "expires_at", "provider", "model", "block_order"])
    if (wireRequiredString(value, "protocol") != "chat_completions" || wireRequiredString(value, "dialect_id") != "openai.chat.v1") { snapshotInvalid("audio replay belongs to an unsupported protocol or dialect") }
    let id = wireRequiredString(value, "id"); let model = wireRequiredString(value, "model"); let expiry = wireRequiredInt(value, "expires_at")
    let order = wireRequiredInt(value, "block_order")
    if (id == "" || model.trimAscii() == "" || expiry < 0 || order < 0) { snapshotInvalid("audio replay requires complete identity, expiry and order") }
    let encoded = wireRequiredString(value, "data")
    LlmWireAssistantAudioReplayBlock(parseAudioFormat(wireRequiredString(value, "format")), id, wireRequiredString(value, "transcript"), expiry,
        wireRequiredString(value, "provider"), model, decodeAudioBase64(encoded, audioBase64Size(encoded, AUDIO_MAX_BYTES)), order)
}

func audioExpiryTail(choice: JsonNode, state: ChatAudioState): Bool {
    if (!state.observed || state.expiry.isSome()) { return false }
    for (field in choice.fields where field.name != "index" && field.name != "delta") {
        if ((field.name != "finish_reason" && field.name != "logprobs") || field.value.wireKind != WireJsonKind.Null) { return false }
    }
    let delta = match (wireOptionalObject(choice, "delta")) { case Some(value) => value; case None => return false }
    if (delta.fields.size != 1) { return false }
    let audio = match (wireOptionalObject(delta, "audio")) { case Some(value) => value; case None => return false }
    audio.fields.size == 1 && audio.field("expires_at").isSome()
}
