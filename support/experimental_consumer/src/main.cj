package llm4cj_experimental_consumer

import llm4cj.experimental.*

main(): Int64 {
    let grammar = LlmWireGrammar(LlmWireGrammarSyntax.Regex, "[a-z]+")
    let tool = LlmWireCustomTool(
        "emit_word",
        format: LlmWireCustomToolFormat.Grammar(grammar)
    )
    if (tool.name != "emit_word" || grammar.definition != "[a-z]+") { return 1 }
    0
}
