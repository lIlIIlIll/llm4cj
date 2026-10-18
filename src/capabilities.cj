package llm4cj

import std.collection.*
import std.deriving.Derive

@Derive[Equatable]
public enum LlmWireCapabilityDiagnosticKind { Requirement | Unsupported | Invalid }

// Diagnostics contain library-owned descriptions, never request contents.
public class LlmWireCapabilityDiagnostic {
    public let kind: LlmWireCapabilityDiagnosticKind
    public let featureId: String
    public let code: String
    public let message: String
    public let inputItemIndex: Int64
    public let blockIndex: Int64
    public let requirementState: ?LlmWireRequirementState
    init(kind: LlmWireCapabilityDiagnosticKind, featureId: String, code: String, message: String,
        inputItemIndex: Int64, blockIndex: Int64, requirementState!: ?LlmWireRequirementState = None) {
        this.kind = kind; this.featureId = featureId; this.code = code; this.message = message
        this.inputItemIndex = inputItemIndex; this.blockIndex = blockIndex; this.requirementState = requirementState
    }
}

public class LlmWireRequestCapabilityReport {
    private let diagnosticsValue: Array<LlmWireCapabilityDiagnostic>
    public let profileId: String
    public let contractVersion: Int64
    public let complete: Bool
    public let truncated: Bool
    init(diagnostics: Array<LlmWireCapabilityDiagnostic>, profileId: String, contractVersion: Int64, complete: Bool, truncated: Bool) {
        diagnosticsValue = copyValues(diagnostics); this.profileId = profileId; this.contractVersion = contractVersion
        this.complete = complete; this.truncated = truncated
    }
    public prop diagnostics: Array<LlmWireCapabilityDiagnostic> { get() { copyValues(diagnosticsValue) } }
}

class RequestInspectionStopped <: Exception { init() { super("request inspection budget exhausted") } }

class RankedRequestDiagnostic {
    let value: LlmWireCapabilityDiagnostic
    let rank: Int64
    let structural: Bool
    init(value: LlmWireCapabilityDiagnostic, rank: Int64, structural: Bool) {
        this.value = value; this.rank = rank; this.structural = structural
    }
}

// Both encoding and inspection execute these checks. The default sink preserves
// first-error behavior. Collection has separate work and retention budgets.
class RequestCheckSink {
    let collecting: Bool
    // Keep option results independent of unrelated failures and diagnostic retention.
    var generationSpeedAccepted: Bool = false
    var promptCacheAccepted: Bool = false
    private let diagnostics = ArrayList<RankedRequestDiagnostic>()
    private var visits: Int64 = 0
    private var scannedBytes: Int64 = 0
    private var rank: Int64 = 0
    private var pinnedRank: Int64 = -1
    private var failures: Int64 = 0
    private var incomplete: Bool = false
    private var truncated: Bool = false
    private var feature: String = "request"
    private var item: Int64 = -1
    private var block: Int64 = -1
    private var structural: Bool = false
    init(collecting!: Bool = false) { this.collecting = collecting }

    func charge(count!: Int64 = 1, bytes!: Int64 = 0): Unit {
        if (!collecting) { return }
        if (count > 100000 - visits || bytes > 16777216 - scannedBytes) {
            incomplete = true; truncated = true; throw RequestInspectionStopped()
        }
        visits += count; scannedBytes += bytes
    }

    func check(featureId: String, body: () -> Unit, itemIndex!: Int64 = -1, blockIndex!: Int64 = -1, prerequisite!: Bool = false): Bool {
        charge()
        let previous = (feature, item, block, structural)
        feature = featureId; item = itemIndex; block = blockIndex; structural = prerequisite
        let before = failures
        try { body() }
        catch (error: LlmWireError) { reject(error) }
        finally { feature = previous[0]; item = previous[1]; block = previous[2]; structural = previous[3] }
        failures == before
    }

    func reject(error: LlmWireError): Unit {
        if (!collecting) { throw error }
        failures++
        if (structural) { incomplete = true }
        let kind = if (error.kind == LlmWireErrorKind.Unsupported) {
            LlmWireCapabilityDiagnosticKind.Unsupported
        } else { LlmWireCapabilityDiagnosticKind.Invalid }
        let message = if (kind == LlmWireCapabilityDiagnosticKind.Unsupported) {
            "The codec does not declare support for this request feature."
        } else { "The request does not satisfy this static check." }
        retain(LlmWireCapabilityDiagnostic(kind, feature, error.code, message,
            if (error.inputItemIndex >= 0) { error.inputItemIndex } else { item },
            if (error.blockIndex >= 0) { error.blockIndex } else { block }), structural)
    }

    func value<T>(featureId: String, body: () -> T, prerequisite!: Bool = false): ?T {
        let output = ArrayList<T>()
        if (check(featureId, { => output.add(body()) }, prerequisite: prerequisite)) { return Some(output[0]) }
        None
    }

    func requirement(value: LlmWireFeatureRequirement): Unit {
        charge()
        let state = match (value.state) {
            case LlmWireRequirementState.Satisfied => LlmWireRequirementState.Satisfied
            case LlmWireRequirementState.Unsatisfied(_) => LlmWireRequirementState.Unsatisfied("The declared external requirement is not satisfied.")
            case LlmWireRequirementState.Unknown(_) => LlmWireRequirementState.Unknown("An external requirement must be resolved before materialization.")
        }
        let code = match (state) {
            case LlmWireRequirementState.Satisfied => ""
            case LlmWireRequirementState.Unsatisfied(_) => "llm.feature_requirement_unsatisfied"
            case LlmWireRequirementState.Unknown(_) => "llm.feature_requirement_unresolved"
        }
        retain(LlmWireCapabilityDiagnostic(LlmWireCapabilityDiagnosticKind.Requirement, value.featureId, code,
            "This requirement describes a local declaration, not a live provider check.", -1, -1, requirementState: Some(state)), false)
    }

    private func retain(value: LlmWireCapabilityDiagnostic, isStructural: Bool): Unit {
        for (entry in diagnostics) {
            if (entry.value.kind == value.kind && entry.value.featureId == value.featureId && entry.value.code == value.code &&
                entry.value.inputItemIndex == value.inputItemIndex && entry.value.blockIndex == value.blockIndex) { return }
        }
        rank++
        let entry = RankedRequestDiagnostic(value, rank, isStructural)
        let firstStructural = isStructural && pinnedRank < 0
        var bytes: Int64 = 0
        for (candidate in diagnostics) { bytes += diagnosticBytes(candidate.value) }
        let additional = diagnosticBytes(value)
        // Evict before add: the retained array never grows beyond 128 entries.
        // The first structural error can displace another entry even when its
        // input position sorts after the retained diagnostic prefix.
        while (diagnostics.size >= 128 || additional > 65536 - bytes) {
            var remove = diagnostics.size - 1
            if (diagnostics[remove].rank == pinnedRank) { remove-- }
            if (!firstStructural && diagnosticBefore(diagnostics[remove], entry)) {
                truncated = true; incomplete = true; return
            }
            bytes -= diagnosticBytes(diagnostics[remove].value)
            diagnostics.remove(at: remove)
            truncated = true; incomplete = true
        }
        if (firstStructural) { pinnedRank = rank }
        var position = diagnostics.size
        for (index in 0..diagnostics.size) {
            if (diagnosticBefore(entry, diagnostics[index])) { position = index; break }
        }
        diagnostics.add(entry)
        var index = diagnostics.size - 1
        while (index > position) { diagnostics[index] = diagnostics[index - 1]; index-- }
        diagnostics[position] = entry
    }

    func report(codec: LlmWireCodec): LlmWireRequestCapabilityReport {
        let output = ArrayList<LlmWireCapabilityDiagnostic>()
        for (entry in diagnostics) { output.add(entry.value) }
        let profileId = match (contextEndpointProfile(codec)) { case Some(value) => value.profileId; case None => "" }
        LlmWireRequestCapabilityReport(output.toArray(), profileId, codec.dialect.contract.contextUpdates.version, !incomplete, truncated)
    }
}

func diagnosticBefore(left: RankedRequestDiagnostic, right: RankedRequestDiagnostic): Bool {
    if (left.value.inputItemIndex != right.value.inputItemIndex) { return left.value.inputItemIndex < right.value.inputItemIndex }
    if (left.value.blockIndex != right.value.blockIndex) { return left.value.blockIndex < right.value.blockIndex }
    left.rank < right.rank
}

func diagnosticBytes(value: LlmWireCapabilityDiagnostic): Int64 {
    var size = value.featureId.size + value.code.size + value.message.size
    match (value.requirementState) {
        case Some(LlmWireRequirementState.Unsatisfied(text)) => size += text.size
        case Some(LlmWireRequirementState.Unknown(text)) => size += text.size
        case _ => ()
    }
    size
}

// Pure static inspection. The bound codec profile is the authority. No resolver,
// clock, header values, encoded body, or network access participates in this report.
public func inspectRequestCapabilities(codec: LlmWireCodec, request: LlmWireRequest, streaming!: Bool = false): LlmWireRequestCapabilityReport {
    let checks = RequestCheckSink(collecting: true)
    try {
        codec.dialect.contract.chargeInspection(checks)
        codec.capabilities.chargeInspection(checks)
        request.transcript.chargeInspection(checks)
        checks.charge(bytes: request.model.size)
        let _ = checkWireRequest(codec, request, checks)
        validateEncodingRequestChecks(codec, request, streaming, checks)
        for (requirement in requestFeatureRequirements(codec, request, checks)) { checks.requirement(requirement) }
    } catch (_: RequestInspectionStopped) { () }
    checks.report(codec)
}

func requestFeatureRequirements(codec: LlmWireCodec, request: LlmWireRequest, checks: RequestCheckSink): Array<LlmWireFeatureRequirement> {
    let output = ArrayList<LlmWireFeatureRequirement>()
    if (checks.generationSpeedAccepted) {
        for (value in generationFeatureRequirements(codec, request.generationSpeed)) { output.add(value) }
    }
    if (checks.promptCacheAccepted) {
        for (value in cacheFeatureRequirements(codec, request.promptCache)) { output.add(value) }
    }
    output.toArray()
}

func generationFeatureRequirements(codec: LlmWireCodec, value: LlmWireGenerationSpeed): Array<LlmWireFeatureRequirement> {
    let output = ArrayList<LlmWireFeatureRequirement>()
    if (codec.dialect.contract.requestStyle == LlmWireRequestStyle.AnthropicMessages && value == LlmWireGenerationSpeed.Fast) {
        output.add(LlmWireFeatureRequirement("anthropic.fast_mode", LlmWireRequirementState.Unknown("fast mode requires a supported model, platform, and account")))
    }
    output.toArray()
}

func cacheFeatureRequirements(codec: LlmWireCodec, value: LlmWirePromptCache): Array<LlmWireFeatureRequirement> {
    let output = ArrayList<LlmWireFeatureRequirement>()
    match (value) {
        case LlmWirePromptCache.Automatic(lifetime) => match (codec.dialect.contract.promptCacheStyle) {
            case LlmWirePromptCacheStyle.OpenAi => if (lifetime == LlmWirePromptCacheLifetime.ProviderDefault) {
                output.add(LlmWireFeatureRequirement("openai.prompt_cache_automatic", LlmWireRequirementState.Satisfied))
            }
            case LlmWirePromptCacheStyle.ProviderAutomatic => output.add(LlmWireFeatureRequirement("provider.prompt_cache_automatic", LlmWireRequirementState.Satisfied))
            case _ => ()
        }
        case _ => ()
    }
    output.toArray()
}
