package llm4cj

import std.unittest.*
import std.unittest.testmacro.*

private func jsonRepeated(byte: Byte, count: Int64): String {
    String.fromUtf8(Array<Byte>(count, repeat: byte))
}

@Test
class JsonConstructionLimitsRegressionTest {
    @TestCase
    func stringFactoriesEnforceEncodedBytesIncludingEscaping() {
        let budget: Int64 = 8388608
        let exact = jsonFactoryValue(LlmWireJson.string(jsonRepeated(b'a', budget - 2)))
        @Expect(exact.stringify().size, budget)
        @Expect(exact.stringValue().getOrThrow().size, budget - 2)
        @Expect(LlmWireJson.string(jsonRepeated(b'a', budget - 1)).isOk(), false)
        @Expect(LlmWireJson.string(jsonRepeated(b'a', budget + 1)).isOk(), false)
        let escaped = jsonFactoryValue(LlmWireJson.string(jsonRepeated(b'"', (budget - 2) / 2)))
        @Expect(escaped.stringify().size, budget)
        @Expect(LlmWireJson.string(jsonRepeated(b'"', budget / 2)).isOk(), false)
        @Expect(LlmWireJson.parse(exact.stringify()).isOk(), true)
        @Expect(LlmWireJson.parse(exact.stringify() + " ").isOk(), false)
        @Expect(LlmWireJson.number(jsonRepeated(b'9', budget + 1)).isOk(), false)
    }

    @TestCase
    func utf8AndControlEscapesUseEncodedByteBudget() {
        let budget: Int64 = 8388608
        let utf8 = String.fromUtf8(Array<Byte>(budget - 2, {index => if (index % 2 == 0) { 0xc3u8 } else { 0xa9u8 }}))
        let exact = jsonFactoryValue(LlmWireJson.string(utf8))
        @Expect(exact.stringify().size, budget)
        @Expect(exact.stringValue(), Some(utf8))
        @Expect(LlmWireJson.string(utf8 + "a").isOk(), false)
        let controls = jsonRepeated(0x01u8, (budget - 2) / 6)
        @Expect(jsonFactoryValue(LlmWireJson.string(controls)).stringify().size, budget)
        @Expect(LlmWireJson.string(controls + "a").isOk(), false)
    }

    @TestCase
    func parentFactoriesBoundCombinedChildrenAndEscapedKeys() {
        let budget: Int64 = 8388608
        let child = jsonFactoryValue(LlmWireJson.string(jsonRepeated(b'a', budget - 4)))
        let parent = jsonFactoryValue(LlmWireJson.array([child]))
        @Expect(parent.stringify().size, budget)
        let oversized = jsonFactoryValue(LlmWireJson.string(jsonRepeated(b'a', budget - 3)))
        @Expect(LlmWireJson.array([oversized]).isOk(), false)
        @Expect(LlmWireJson.array([child, child]).isOk(), false)
        let exactKey = jsonRepeated(b'a', budget - 9)
        let object = jsonFactoryValue(LlmWireJson.object([LlmWireJsonField(exactKey, LlmWireJson.nullValue())]))
        @Expect(object.stringify().size, budget)
        @Expect(LlmWireJson.object([LlmWireJsonField(exactKey + "a", LlmWireJson.nullValue())]).isOk(), false)
        @Expect(LlmWireJson.object([LlmWireJsonField(jsonRepeated(b'"', budget / 2), LlmWireJson.nullValue())]).isOk(), false)
        @Expect(LlmWireJson.object([LlmWireJsonField("x", child), LlmWireJsonField("y", child)]).isOk(), false)
        match (LlmWireJson.object([LlmWireJsonField("x", LlmWireJson.nullValue()), LlmWireJsonField("x", LlmWireJson.nullValue())])) {
            case LlmWireResult.Err(error) => @Expect(error.code, "llm.json_duplicate_key")
            case _ => @Fail("duplicate fields must fail")
        }
    }

    @TestCase
    func constructionAndParseAgreeAtDepthBoundary() {
        var value = LlmWireJson.nullValue()
        for (_ in 0..256) { value = jsonFactoryValue(LlmWireJson.array([value])) }
        @Expect(LlmWireJson.parse(value.stringify()).isOk(), true)
        @Expect(LlmWireJson.array([value]).isOk(), false)
        @Expect(LlmWireJson.object([LlmWireJsonField("child", value)]).isOk(), false)
        @Expect(LlmWireJson.parse("[" + value.stringify() + "]").isOk(), false)
    }

    @TestCase
    func parentSeparatorsAreIncludedAtExactCombinedBoundary() {
        let budget: Int64 = 8388608
        let arrayChild = jsonFactoryValue(LlmWireJson.string(jsonRepeated(b'a', budget - 9)))
        @Expect(jsonFactoryValue(LlmWireJson.array([arrayChild, LlmWireJson.nullValue()])).stringify().size, budget)
        let arrayOverflow = jsonFactoryValue(LlmWireJson.string(jsonRepeated(b'a', budget - 8)))
        @Expect(LlmWireJson.array([arrayOverflow, LlmWireJson.nullValue()]).isOk(), false)
        let objectChild = jsonFactoryValue(LlmWireJson.string(jsonRepeated(b'a', budget - 16)))
        @Expect(jsonFactoryValue(LlmWireJson.object([LlmWireJsonField("a", LlmWireJson.nullValue()), LlmWireJsonField("", objectChild)])).stringify().size, budget)
        let objectOverflow = jsonFactoryValue(LlmWireJson.string(jsonRepeated(b'a', budget - 15)))
        @Expect(LlmWireJson.object([LlmWireJsonField("a", LlmWireJson.nullValue()), LlmWireJsonField("", objectOverflow)]).isOk(), false)
    }

    @TestCase
    func immutableGettersAndInputArraysCannotMutateValues() {
        let source = [jsonFactoryValue(LlmWireJson.string("original"))]
        let array = jsonFactoryValue(LlmWireJson.array(source))
        source[0] = LlmWireJson.boolean(false)
        let children = array.values()
        children[0] = LlmWireJson.nullValue()
        @Expect(array.values()[0].stringValue(), Some("original"))
        let fields = [LlmWireJsonField("child", array)]
        let object = jsonFactoryValue(LlmWireJson.object(fields))
        fields[0] = LlmWireJsonField("replaced", LlmWireJson.nullValue())
        let returned = object.fields()
        returned[0] = LlmWireJsonField("replaced", LlmWireJson.nullValue())
        @Expect(object.field("child").getOrThrow().values()[0].stringValue(), Some("original"))
        @Expect(object.field("replaced").isNone(), true)
        @Expect(object.stringify(), "{\"child\":[\"original\"]}")
        let number = jsonFactoryValue(LlmWireJson.number("-1.2300e+999999999999999999999999999999"))
        @Expect(number.numberLiteral(), Some("-1.2300e+999999999999999999999999999999"))
    }
}
