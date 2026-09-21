package llm4cj

import std.collection.*
import std.deriving.Derive

@Derive[Equatable]
public enum LlmWireToolVisibility { Active | Deferred }

public class LlmWireToolRef {
    public let name: String
    public let version: String
    public init(name: String, version: String) {
        if (name == "" || version == "") {
            throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.tool_reference_invalid", "tool references require a name and version")
        }
        if (!validToolVersion(version)) {
            throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.tool_version_invalid", "tool versions must be 1-64 ASCII identity bytes")
        }
        this.name = name
        this.version = version
    }
}

public class LlmWireToolDeclaration {
    public let tool: LlmWireTool
    public let visibility: LlmWireToolVisibility
    public init(tool: LlmWireTool, visibility!: LlmWireToolVisibility = LlmWireToolVisibility.Active) {
        this.tool = tool
        this.visibility = visibility
    }
}

public class LlmWireInitialContext {
    private let instructionsValue: Array<LlmWireInstruction>
    private let toolsValue: Array<LlmWireToolDeclaration>
    public init(instructions!: Array<LlmWireInstruction> = [], tools!: Array<LlmWireToolDeclaration> = []) {
        this.instructionsValue = copyValues(instructions)
        this.toolsValue = copyValues(tools)
    }
    public prop instructions: Array<LlmWireInstruction> { get() { copyValues(instructionsValue) } }
    public prop tools: Array<LlmWireToolDeclaration> { get() { copyValues(toolsValue) } }
}

public enum LlmWireInputItem {
    Message(LlmWireMessage)
    | InstructionUpdate(LlmWireInstruction)
    | ToolDeclaration(LlmWireToolDeclaration)
    | ToolActivation(LlmWireToolRef)
    | ToolDeactivation(LlmWireToolRef)
    | ToolReplacement(LlmWireToolRef, LlmWireTool)
}

public class LlmWireTranscript {
    private let initialContextValue: LlmWireInitialContext
    private let itemsValue: Array<LlmWireInputItem>
    public init(initialContext: LlmWireInitialContext, items!: Array<LlmWireInputItem> = []) {
        this.initialContextValue = initialContext
        this.itemsValue = copyValues(items)
    }
    public prop initialContext: LlmWireInitialContext { get() { initialContextValue } }
    public prop items: Array<LlmWireInputItem> { get() { copyValues(itemsValue) } }
    public func effectiveTools(): LlmWireResult<Array<LlmWireTool>> { effectiveToolsForTranscript(this) }
    public func snapshot(): LlmWireResult<String> { snapshotTranscript(this) }
    public static func restore(source: String): LlmWireResult<LlmWireTranscript> { restoreTranscript(source) }
}

public class LlmWireTranscriptBuilder {
    private let initialContextValue: LlmWireInitialContext
    private let itemsValue = ArrayList<LlmWireInputItem>()
    public init(initialContext: LlmWireInitialContext) { this.initialContextValue = initialContext }
    public func append(item: LlmWireInputItem): Unit { itemsValue.add(item) }
    public func build(): LlmWireResult<LlmWireTranscript> {
        let transcript = LlmWireTranscript(initialContextValue, items: itemsValue.toArray())
        try {
            validateTranscript(transcript)
            LlmWireResult.Ok(transcript)
        } catch (error: LlmWireError) {
            LlmWireResult.Err(error)
        }
    }
}

@Derive[Equatable]
public enum LlmWireTranscriptOperation {
    InstructionUpdate | ToolDeclaration | ToolActivation | ToolDeactivation | ToolReplacement
}

@Derive[Equatable]
public enum LlmWireTranscriptEncoding {
    Unsupported
    | OpenAiDeveloperInput
    | OpenAiAdditionalTools
    | AnthropicSystemText
    | AnthropicToolReference
    | KimiSystemText
    | KimiSystemTools
}

public class LlmWireTranscriptCapability {
    public let operation: LlmWireTranscriptOperation
    public let encoding: LlmWireTranscriptEncoding
    public init(operation: LlmWireTranscriptOperation, encoding: LlmWireTranscriptEncoding) {
        this.operation = operation
        this.encoding = encoding
    }
}

public class LlmWireTranscriptCapabilities {
    public let endpointProfileId: String
    public let contractVersion: String
    private let entriesValue: Array<LlmWireTranscriptCapability>
    public init(endpointProfileId: String, contractVersion: String, entries!: Array<LlmWireTranscriptCapability> = []) {
        if (endpointProfileId.trimAscii() == "" || contractVersion.trimAscii() == "") {
            throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.transcript_capability_identity_invalid", "transcript capabilities require endpoint and contract identities")
        }
        let seen = ArrayList<LlmWireTranscriptOperation>()
        for (entry in entries) {
            var duplicate = false
            for (existing in seen where existing == entry.operation) { duplicate = true }
            if (duplicate) {
                throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.transcript_capability_duplicate", "transcript capability operations must be unique")
            }
            seen.add(entry.operation)
        }
        this.endpointProfileId = endpointProfileId
        this.contractVersion = contractVersion
        this.entriesValue = copyValues(entries)
    }
    public prop entries: Array<LlmWireTranscriptCapability> { get() { copyValues(entriesValue) } }
    public func encodingFor(operation: LlmWireTranscriptOperation): LlmWireResult<LlmWireTranscriptEncoding> {
        for (entry in entriesValue where entry.operation == operation) { return LlmWireResult.Ok(entry.encoding) }
        LlmWireResult.Err(LlmWireError(
            LlmWireErrorKind.Unsupported,
            "llm.context_update_unsupported",
            "the bound transcript capability does not encode this operation"
        ))
    }
}
