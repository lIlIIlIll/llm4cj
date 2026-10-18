package llm4cj

import yjson.*

// The already-validated native DOM supplies this saturated count at ingress.
// Inspection reads the count without reparsing or traversing the payload.
func nativeInspectionNodeCount(value: JsonNode, limit: Int64): Int64 {
    var count: Int64 = 1
    if (value.wireKind == WireJsonKind.List) {
        let array = value.asArray()
        for (index in 0..array.size()) {
            if (count >= limit) { return limit }
            count += nativeInspectionNodeCount(array.get(index).getOrThrow(), limit - count)
        }
    } else if (value.wireKind == WireJsonKind.Object) {
        let object = value.asObject()
        for (index in 0..object.size()) {
            if (count >= limit) { return limit }
            count += nativeInspectionNodeCount(object.valueAt(index), limit - count)
        }
    }
    count
}

// Declaration equality sorts object keys. Account for its comparison work
// before entering the existing canonicalizer, including repeated comparisons.
func chargeJsonOrdering(checks: RequestCheckSink, value: JsonNode): Unit {
    checks.charge()
    if (value.wireKind == WireJsonKind.Object) {
        let object = value.asObject()
        let count = object.size()
        checks.charge(count: count * (count - 1) / 2)
        for (index in 0..count) {
            checks.charge(bytes: object.nameAt(index).size * count)
            chargeJsonOrdering(checks, object.valueAt(index))
        }
    } else if (value.wireKind == WireJsonKind.List) {
        let array = value.asArray()
        for (index in 0..array.size()) { chargeJsonOrdering(checks, array.get(index).getOrThrow()) }
    }
}

func chargeJsonInspection(checks: RequestCheckSink, value: JsonNode): Unit {
    checks.charge()
    match (value.wireKind) {
        case WireJsonKind.List =>
            let array = value.asArray()
            for (index in 0..array.size()) { chargeJsonInspection(checks, array.get(index).getOrThrow()) }
        case WireJsonKind.Object =>
            let object = value.asObject()
            for (index in 0..object.size()) { chargeJsonInspection(checks, object.valueAt(index)) }
        case _ => ()
    }
}

// Charge private transcript storage before public observation allocates copies.
// This is a resource pass, not a second semantic validator.
func chargeDeclarationInspection(checks: RequestCheckSink, value: LlmWireToolDeclaration): Unit {
    checks.charge(bytes: value.tool.name.size)
    checks.charge(bytes: value.version.size)
    checks.charge(bytes: value.tool.description.size)
    match (value.tool) {
        case LlmWireToolDefinition.Function(tool) => tool.inputSchema.chargeInspection(checks)
        case LlmWireToolDefinition.Custom(tool) => match (tool.format) {
            case LlmWireCustomToolFormat.Grammar(grammar) => checks.charge(bytes: grammar.definition.size)
            case _ => ()
        }
    }
}

func chargeItemInspection(checks: RequestCheckSink, item: LlmWireInputItem): Unit {
    checks.charge()
    match (item) {
        case LlmWireInputItem.InstructionUpdate(value) => checks.charge(bytes: value.text.size)
        case LlmWireInputItem.ToolDeclaration(value) => chargeDeclarationInspection(checks, value)
        case LlmWireInputItem.ToolActivation(value) =>
            checks.charge(bytes: value.name.size); checks.charge(bytes: value.version.size)
        case LlmWireInputItem.ToolDeactivation(value) =>
            checks.charge(bytes: value.name.size); checks.charge(bytes: value.version.size)
        case LlmWireInputItem.Message(value) =>
            checks.charge(count: value.messageSpanCount())
            for (block in value.blocks) { chargeBlockInspection(checks, block) }
    }
}

func chargeCitationInspection(checks: RequestCheckSink, value: LlmWireCitation): Unit {
    for (text in [value.citedText, value.documentTitle, value.url, value.title, value.fileId, value.filename]) {
        checks.charge(bytes: text.size)
    }
}

func chargeLogprobsInspection(checks: RequestCheckSink, values: Array<LlmWireTokenLogprob>): Unit {
    for (value in values) {
        checks.charge(count: value.bytes.size + 1, bytes: value.token.size)
        value.logprob.chargeInspection(checks)
        for (candidate in value.topLogprobs) {
            checks.charge(count: candidate.bytes.size + 1, bytes: candidate.token.size)
            candidate.logprob.chargeInspection(checks)
        }
    }
}

func chargeTextInspection(checks: RequestCheckSink, value: LlmWireTextBlock): Unit {
    checks.charge(bytes: value.text.size)
    for (citation in value.citations) { chargeCitationInspection(checks, citation) }
    for (annotation in value.annotations) { match (annotation) {
        case LlmWireAnnotation.UrlCitation(citation) => chargeCitationInspection(checks, citation)
        case LlmWireAnnotation.FileCitation(citation) => chargeCitationInspection(checks, citation)
    } }
    chargeLogprobsInspection(checks, value.logprobs)
}

func chargeImageInspection(checks: RequestCheckSink, value: LlmWireImageBlock): Unit {
    checks.charge(bytes: value.data.size); checks.charge(bytes: value.mediaType.size)
}

func chargeBlockInspection(checks: RequestCheckSink, block: LlmWireBlock): Unit {
    checks.charge()
    match (block) {
        case LlmWireBlock.Text(value) => chargeTextInspection(checks, value)
        case LlmWireBlock.Image(value) => chargeImageInspection(checks, value)
        case LlmWireBlock.Reasoning(value) => checks.charge(bytes: value.text.size)
        case LlmWireBlock.Refusal(value) =>
            checks.charge(bytes: value.text.size); chargeLogprobsInspection(checks, value.logprobs)
            for (text in [value.category, value.explanation]) { match (text) { case Some(data) => checks.charge(bytes: data.size); case None => () } }
        case LlmWireBlock.Opaque(value) => checks.charge(bytes: value.snapshot().size)
        case LlmWireBlock.NativeReplay(value) =>
            value.chargeInspection(checks)
            match (value.modelConstraint) { case Some(model) => checks.charge(bytes: model.size); case None => () }
        case LlmWireBlock.AudioInput(value) => checks.charge(bytes: value.audioBytes().size)
        case LlmWireBlock.AudioReplay(value) =>
            checks.charge(bytes: value.audioBytes().size)
            for (text in [value.id, value.transcript, value.provider, value.model]) { checks.charge(bytes: text.size) }
        case LlmWireBlock.ToolCall(value) =>
            checks.charge(bytes: value.callId.size); checks.charge(bytes: value.name.size)
            match (value.arguments) {
                case LlmWireToolArguments.Complete(json) => json.chargeInspection(checks)
                case LlmWireToolArguments.InvalidShape(json) => json.chargeInspection(checks)
                case LlmWireToolArguments.InvalidJson(text) => checks.charge(bytes: text.size)
                case LlmWireToolArguments.Partial(text) => checks.charge(bytes: text.size)
                case LlmWireToolArguments.Text(text) => checks.charge(bytes: text.size)
                case LlmWireToolArguments.PartialText(text) => checks.charge(bytes: text.size)
            }
        case LlmWireBlock.ToolResult(value) =>
            checks.charge(bytes: value.callId.size)
            for (part in value.content) { checks.charge(); match (part) {
                case LlmWireToolResultContent.Text(text) => chargeTextInspection(checks, text)
                case LlmWireToolResultContent.Image(image) => chargeImageInspection(checks, image)
            } }
    }
}
