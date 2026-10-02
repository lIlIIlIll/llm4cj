package llm4cj

import std.collection.*
import std.deriving.Derive

@Derive[Equatable]
public enum LlmWireContextUpdateStyle { Unsupported | ResponsesAdditionalTools | AnthropicToolReferences | KimiSystemTools }

// These dimensions describe protocol semantics, independently of caching.
public class LlmWireContextUpdateCapabilities {
    public let appendSystemInstruction: Bool
    public let appendDeveloperInstruction: Bool
    public let toolDeclaration: Bool
    public let toolActivation: Bool
    public let toolDeactivation: Bool
    public let toolReplacement: Bool
    public let deferredToolPool: Bool
    public let deferredPoolExtension: Bool
    public init(
        appendSystemInstruction!: Bool = false, appendDeveloperInstruction!: Bool = false,
        toolDeclaration!: Bool = false, toolActivation!: Bool = false, toolDeactivation!: Bool = false,
        toolReplacement!: Bool = false, deferredToolPool!: Bool = false, deferredPoolExtension!: Bool = false
    ) {
        this.appendSystemInstruction = appendSystemInstruction; this.appendDeveloperInstruction = appendDeveloperInstruction
        this.toolDeclaration = toolDeclaration; this.toolActivation = toolActivation; this.toolDeactivation = toolDeactivation
        this.toolReplacement = toolReplacement; this.deferredToolPool = deferredToolPool; this.deferredPoolExtension = deferredPoolExtension
    }
}

public class LlmWireContextUpdateContract {
    public let style: LlmWireContextUpdateStyle
    public let version: Int64
    public let capabilities: LlmWireContextUpdateCapabilities
    public init(style!: LlmWireContextUpdateStyle = LlmWireContextUpdateStyle.Unsupported) {
        this.style = style; this.version = 1
        this.capabilities = match (style) {
            case LlmWireContextUpdateStyle.Unsupported => LlmWireContextUpdateCapabilities()
            case LlmWireContextUpdateStyle.ResponsesAdditionalTools => LlmWireContextUpdateCapabilities(appendSystemInstruction: true, appendDeveloperInstruction: true, toolDeclaration: true)
            case LlmWireContextUpdateStyle.AnthropicToolReferences => LlmWireContextUpdateCapabilities(appendSystemInstruction: true, toolActivation: true, toolDeactivation: true, deferredToolPool: true)
            case LlmWireContextUpdateStyle.KimiSystemTools => LlmWireContextUpdateCapabilities(appendSystemInstruction: true, toolDeclaration: true)
        }
    }
    public prop requiredHeaders: Array<LlmWireHeader> { get() {
        match (style) {
            case LlmWireContextUpdateStyle.AnthropicToolReferences => [LlmWireHeader("anthropic-beta", "mid-conversation-tool-changes-2026-07-01")]
            case _ => []
        }
    } }
}

// A caller's explicit declaration, not a claim that the library probed a server.
@Derive[Equatable]
public enum LlmWireCapabilityEvidence { CallerDeclared }

public class LlmWireEndpointProfile {
    public let profileId: String
    public let model: String
    public let dialectId: String
    public let endpoint: String
    public let contractVersion: Int64
    public let capabilities: LlmWireContextUpdateCapabilities
    public let evidence: LlmWireCapabilityEvidence
    public let evidenceSource: String
    public let checkedAt: String
    public init(
        profileId: String, model: String, dialectId: String, endpoint: String, contractVersion: Int64,
        capabilities: LlmWireContextUpdateCapabilities, evidenceSource: String, checkedAt: String
    ) {
        if (!validCompatibilityId(profileId) || !validCompatibilityId(dialectId) || model.trimAscii() == "" || endpoint.trimAscii() == "" ||
            model.toArray().size > 256 || endpoint.toArray().size > 2048 || evidenceSource.trimAscii() == "" || evidenceSource.toArray().size > 2048 || !validProfileEvidenceDate(checkedAt)) {
            throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.endpoint_profile_invalid", "endpoint profile requires bounded exact identity and dated evidence")
        }
        for (byte in endpoint.toArray()) {
            if (byte < 32u8 || byte == 127u8 || byte == 64u8 || byte == 63u8 || byte == 35u8) {
                throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.endpoint_profile_invalid", "endpoint profile must not contain credentials, query parameters, fragments, or controls")
            }
        }
        if (contractVersion != 1) { throw LlmWireError(LlmWireErrorKind.Unsupported, "llm.context_contract_version_unsupported", "unknown context update contract version", contractVersion: contractVersion) }
        this.profileId = profileId; this.model = model; this.dialectId = dialectId; this.endpoint = endpoint; this.contractVersion = contractVersion
        this.capabilities = capabilities; this.evidence = LlmWireCapabilityEvidence.CallerDeclared
        this.evidenceSource = evidenceSource; this.checkedAt = checkedAt
    }
}

func validProfileEvidenceDate(value: String): Bool {
    let bytes = value.toArray()
    if (bytes.size != 10 || bytes[4] != 45u8 || bytes[7] != 45u8) { return false }
    for (index in [0, 1, 2, 3, 5, 6, 8, 9]) { if (bytes[index] < 48u8 || bytes[index] > 57u8) { return false } }
    let year = Int64(bytes[0] - 48u8) * 1000 + Int64(bytes[1] - 48u8) * 100 + Int64(bytes[2] - 48u8) * 10 + Int64(bytes[3] - 48u8)
    let month = Int64(bytes[5] - 48u8) * 10 + Int64(bytes[6] - 48u8)
    let day = Int64(bytes[8] - 48u8) * 10 + Int64(bytes[9] - 48u8)
    if (year == 0 || month < 1 || month > 12 || day < 1) { return false }
    let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
    let days = [31, if (leap) { 29 } else { 28 }, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    day <= days[month - 1]
}

func validateContextUpdateContract(style: LlmWireRequestStyle, contract: LlmWireContextUpdateContract): Unit {
    let valid = match ((style, contract.style)) {
        case (_, LlmWireContextUpdateStyle.Unsupported) |
             (LlmWireRequestStyle.OpenAiResponses, LlmWireContextUpdateStyle.ResponsesAdditionalTools) |
             (LlmWireRequestStyle.AnthropicMessages, LlmWireContextUpdateStyle.AnthropicToolReferences) |
             (LlmWireRequestStyle.KimiChat, LlmWireContextUpdateStyle.KimiSystemTools) => true
        case _ => false
    }
    if (!valid) { throw IllegalArgumentException("context update contract does not match request style") }
}

func declaredContextCapabilitiesFit(value: LlmWireContextUpdateCapabilities, allowed: LlmWireContextUpdateCapabilities): Bool {
    (!value.appendSystemInstruction || allowed.appendSystemInstruction) && (!value.appendDeveloperInstruction || allowed.appendDeveloperInstruction) &&
    (!value.toolDeclaration || allowed.toolDeclaration) && (!value.toolActivation || allowed.toolActivation) && (!value.toolDeactivation || allowed.toolDeactivation) &&
    (!value.toolReplacement || allowed.toolReplacement) && (!value.deferredToolPool || allowed.deferredToolPool) && (!value.deferredPoolExtension || allowed.deferredPoolExtension)
}

func contextEndpointProfile(codec: LlmWireCodec): ?LlmWireEndpointProfile {
    match (codec.modelProfile) { case Some(value) => value.endpointProfile; case None => None }
}

func requireContextCapability(codec: LlmWireCodec, supported: Bool, capability: String, itemIndex: Int64, toolName!: String = "", toolVersion!: String = ""): Unit {
    if (supported) { return }
    let profile = contextEndpointProfile(codec)
    throw LlmWireError(LlmWireErrorKind.Unsupported, "llm.context_update_unsupported", "native transcript operation requires explicit capability: " + capability,
        inputItemIndex: itemIndex, toolName: toolName, toolVersion: toolVersion, missingCapability: capability,
        profileId: match (profile) { case Some(value) => value.profileId; case None => "" }, contractVersion: codec.dialect.contract.contextUpdates.version)
}

func validateTranscriptCapabilities(codec: LlmWireCodec, request: LlmWireRequest): Unit {
    let contract = codec.dialect.contract.contextUpdates
    let profile = contextEndpointProfile(codec)
    let capabilities = match (profile) {
        case Some(value) =>
            if (value.contractVersion != contract.version || !declaredContextCapabilitiesFit(value.capabilities, contract.capabilities)) {
                throw LlmWireError(LlmWireErrorKind.Unsupported, "llm.endpoint_profile_capability_unsupported", "endpoint profile declares capabilities outside the versioned dialect contract", profileId: value.profileId, contractVersion: value.contractVersion)
            }
            if (contract.style == LlmWireContextUpdateStyle.KimiSystemTools && (value.model != "kimi-k3" || value.endpoint != "https://api.moonshot.ai/v1/chat/completions")) {
                throw LlmWireError(LlmWireErrorKind.Unsupported, "llm.endpoint_profile_capability_unsupported", "Kimi dynamic tools contract is scoped to kimi-k3 on the documented endpoint", profileId: value.profileId, contractVersion: value.contractVersion)
            }
            value.capabilities
        case None => LlmWireContextUpdateCapabilities()
    }
    for (declaration in request.transcript.initialContext.tools where declaration.deferred) {
        requireContextCapability(codec, capabilities.deferredToolPool, "deferred_tool_pool", -1, toolName: declaration.tool.name, toolVersion: declaration.version)
    }
    let items = request.transcript.items
    let declaredNames = transcriptDeclaredNames(request.transcript)
    for (index in 0..items.size) { match (items[index]) {
        case LlmWireInputItem.InstructionUpdate(value) =>
            let system = value.role == LlmWireInstructionRole.System
            requireContextCapability(codec, if (system) { capabilities.appendSystemInstruction } else { capabilities.appendDeveloperInstruction }, if (system) { "append_system_instruction" } else { "append_developer_instruction" }, index)
        case LlmWireInputItem.ToolDeclaration(value) =>
            if (declaredNames.add(value.tool.name)) {
                requireContextCapability(codec, capabilities.toolDeclaration, "tool_declaration", index, toolName: value.tool.name, toolVersion: value.version)
                if (value.deferred) { requireContextCapability(codec, capabilities.deferredPoolExtension, "deferred_pool_extension", index, toolName: value.tool.name, toolVersion: value.version) }
            }
        case LlmWireInputItem.ToolActivation(value) => requireContextCapability(codec, capabilities.toolActivation, "tool_activation", index, toolName: value.name, toolVersion: value.version)
        case LlmWireInputItem.ToolDeactivation(value) => requireContextCapability(codec, capabilities.toolDeactivation, "tool_deactivation", index, toolName: value.name, toolVersion: value.version)
        case LlmWireInputItem.Message(_) => ()
    } }
}
