package codex_subscription

main(args: Array<String>): Int64 {
    if (args.isEmpty() || args[0] == "--help") {
        println("codex_subscription login LABEL | accounts | logout LABEL | models LABEL | chat LABEL MODEL [sse|ws] [--demo-tool]")
        return 0
    }
    try {
        let store = AccountStore.userStore(); let auth = AuthManager(store)
        match (args[0]) {
            case "login" => require(args.size == 2, "login requires an account label"); auth.login(args[1])
            case "accounts" =>
                require(args.size == 1, "accounts takes no arguments")
                store.locked({ => for (account in field(store.load(), "accounts").values()) { println(text(account, "label") + if (optionalText(account, "access_token") == "") { " (signed out)" } else { " (signed in)" }) } })
            case "logout" =>
                require(args.size == 2, "logout requires an account label")
                if (auth.logout(args[1])) { println("Signed out locally; renewable session revoked.") } else { println("Signed out locally; remote revocation was not confirmed."); return 3 }
            case "models" =>
                require(args.size == 2, "models requires an account label")
                for (model in modelCatalog(auth.access(args[1]))) { println(text(model, "slug") + "\t" + text(model, "display_name")) }
            case "chat" =>
                require(args.size >= 3 && args.size <= 5, "chat requires an account label and model slug")
                let transport = if (args.size >= 4) { args[3] } else { "sse" }
                require(args.size < 5 || args[4] == "--demo-tool", "Unknown chat option")
                chat(auth, args[1], args[2], transport, args.size == 5)
            case _ => throw ExampleError("Unknown command; use --help")
        }
        0
    } catch (error: ExampleError) { println(error.message); 1 }
    catch (_: Exception) { println("Operation failed. Existing credentials are preserved unless the renewable session was rejected or explicitly signed out."); 1 }
}
