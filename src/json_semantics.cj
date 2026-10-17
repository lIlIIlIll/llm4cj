package llm4cj

import std.collection.*
import yjson.*

// JSON numbers are decimal lexemes, not machine integers or floating points.
// Keep an arbitrary-size exponent as signed decimal digits; never expand 10^n.
private class WireDecimal {
    let negative: Bool
    let digits: String
    let exponent: String

    init(negative: Bool, digits: String, exponent: String) {
        this.negative = negative; this.digits = digits; this.exponent = exponent
    }
}

private func wireUnsignedDigits(bytes: Array<Byte>): String {
    var start: Int64 = 0
    while (start < bytes.size && bytes[start] == b'0') { start++ }
    if (start == bytes.size) { return "0" }
    String.fromUtf8(bytes[start..])
}

private func wireUnsignedCompare(left: String, right: String): Int64 {
    if (left.size != right.size) { return if (left.size < right.size) { -1 } else { 1 } }
    if (left == right) { return 0 }
    if (left < right) { -1 } else { 1 }
}

// For subtraction the left magnitude is at least the right magnitude.
private func wireUnsignedSum(left: String, right: String, subtract: Bool): String {
    let result = Array<Byte>(max(left.size, right.size) + 1, repeat: b'0')
    var a = left.size - 1
    var b = right.size - 1
    var out = result.size - 1
    var carry: Int64 = 0
    while (a >= 0 || b >= 0) {
        let x = if (a >= 0) { Int64(left[a]) - 48 } else { 0 }
        let y = if (b >= 0) { Int64(right[b]) - 48 } else { 0 }
        var digit = x + carry
        if (subtract) {
            digit -= y
            carry = if (digit < 0) { -1 } else { 0 }
            if (digit < 0) { digit += 10 }
        } else {
            digit += y
            carry = digit / 10
            digit %= 10
        }
        result[out] = UInt8(digit + 48)
        a--; b--; out--
    }
    // Adding two decimal digits can leave only one leading carry digit.
    if (carry > 0) { result[0] = b'1' }
    wireUnsignedDigits(result)
}

private func wireSignedExponent(raw: String, delta: Int64): String {
    var negative = false
    var start: Int64 = 0
    // The parser has already validated this nonempty exponent lexeme.
    if (raw[0] == b'+' || raw[0] == b'-') {
        negative = raw[0] == b'-'; start = 1
    }
    let magnitude = wireUnsignedDigits(raw.toArray()[start..])
    let deltaNegative = delta < 0
    let deltaMagnitude = (if (deltaNegative) { -delta } else { delta }).toString()
    var digits = ""
    var resultNegative = negative
    if (negative == deltaNegative) {
        digits = wireUnsignedSum(magnitude, deltaMagnitude, false)
    } else if (wireUnsignedCompare(magnitude, deltaMagnitude) >= 0) {
        digits = wireUnsignedSum(magnitude, deltaMagnitude, true)
    } else {
        digits = wireUnsignedSum(deltaMagnitude, magnitude, true)
        resultNegative = deltaNegative
    }
    if (digits == "0") { return "0" }
    if (resultNegative) { "-" + digits } else { digits }
}

private func wireDecimal(literal: String): WireDecimal {
    let bytes = literal.toArray()
    let negative = bytes[0] == b'-'
    var index: Int64 = if (negative) { 1 } else { 0 }
    let coefficient = ArrayList<Byte>()
    var fraction = false
    var fractionDigits: Int64 = 0
    while (index < bytes.size && bytes[index] != b'e' && bytes[index] != b'E') {
        if (bytes[index] == b'.') { fraction = true } else {
            coefficient.add(bytes[index])
            if (fraction) { fractionDigits++ }
        }
        index++
    }
    let rawExponent = if (index < bytes.size) { String.fromUtf8(bytes[index + 1..]) } else { "0" }
    let digits = coefficient.toArray()
    var first: Int64 = 0
    while (first < digits.size && digits[first] == b'0') { first++ }
    if (first == digits.size) { return WireDecimal(false, "0", "0") }
    var end = digits.size
    while (digits[end - 1] == b'0') { end-- }
    WireDecimal(negative, String.fromUtf8(digits[first..end]), wireSignedExponent(rawExponent, digits.size - end - fractionDigits))
}

func wireJsonNumberIsInteger(literal: String): Bool {
    let number = wireDecimal(literal)
    number.digits == "0" || number.exponent[0] != b'-'
}

func wireJsonEquivalent(left: JsonNode, right: JsonNode): Bool {
    if (left.wireKind != right.wireKind) { return false }
    match (left.wireKind) {
        case WireJsonKind.Null => true
        case WireJsonKind.Boolean => left.bool == right.bool
        case WireJsonKind.Text => left.text == right.text
        case WireJsonKind.Number =>
            let a = wireDecimal(left.numberText)
            let b = wireDecimal(right.numberText)
            a.negative == b.negative && a.digits == b.digits && a.exponent == b.exponent
        case WireJsonKind.List =>
            let a = left.asArray(); let b = right.asArray()
            if (a.size() != b.size()) { return false }
            for (index in 0..a.size()) {
                if (!wireJsonEquivalent(a.get(index).getOrThrow(), b.get(index).getOrThrow())) { return false }
            }
            true
        case WireJsonKind.Object =>
            let a = left.asObject(); let b = right.asObject()
            if (a.size() != b.size()) { return false }
            for (index in 0..a.size()) {
                match (b.get(a.nameAt(index))) {
                    case Some(value) => if (!wireJsonEquivalent(a.valueAt(index), value)) { return false }
                    case None => return false
                }
            }
            true
    }
}
