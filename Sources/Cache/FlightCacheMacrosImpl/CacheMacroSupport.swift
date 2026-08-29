import SwiftSyntax
import SwiftSyntaxMacros

/// The analysis shared by all three cache body macros: attribute-argument
/// parsing and the function-shape checks the design diagnoses at the
/// annotation site.
enum CacheMacroSupport {

    /// Parsed attribute arguments, expressions kept as source text for
    /// verbatim re-emission into the expansion.
    struct Arguments {
        var namespace: String?  // the string-literal expression's source
        var ttl: String?  // the ttl expression's source, if present
        var allEntries = false
        var excluded: [String] = []
    }

    /// The analyzed function: everything the expansions interpolate.
    struct Target {
        let isThrowing: Bool
        let returnType: String  // normalized; "Void" for none/()/Void
        let bodyText: String
        let keyParameterNames: [String]  // internal names, excluded removed
    }

    // MARK: - Attribute arguments

    static func parseArguments(
        of node: AttributeSyntax,
        supportsTTL: Bool,
        in context: some MacroExpansionContext
    ) -> Arguments? {
        var arguments = Arguments()
        guard case .argumentList(let list) = node.arguments else {
            // Grammatically unreachable: namespace: is a required parameter.
            context.diagnoseError(
                "cache.arguments", "Cache annotations require at least namespace:.", at: node)
            return nil
        }
        for argument in list {
            switch argument.label?.text {
            case "namespace":
                guard let literal = argument.expression.as(StringLiteralExprSyntax.self),
                    literal.segments.allSatisfy({ $0.is(StringSegmentSyntax.self) })
                else {
                    context.diagnoseError(
                        "cache.namespaceliteral",
                        "namespace: must be a plain string literal — the namespace is compile-time cache identity, not a runtime value.",
                        at: argument.expression)
                    return nil
                }
                // The charset is enforced here because here is the only place
                // it can be. The namespace is the `cache.namespaces.<name>`
                // config key, and Flight's env-var override layer maps keys
                // through `FLIGHT_` + uppercase + `.` → `_` — so a namespace
                // with a hyphen in it produces a variable name no shell can
                // set, and the TTL for that namespace becomes silently
                // unconfigurable in every deployment that uses environment
                // overrides. The rule was documented and enforced nowhere; the
                // macro already demands a literal, so it can check it.
                let namespace = literal.segments
                    .compactMap { $0.as(StringSegmentSyntax.self)?.content.text }
                    .joined()
                guard !namespace.isEmpty else {
                    context.diagnoseError(
                        "cache.namespaceempty",
                        "namespace: is empty — it is this entry's cache identity and its config key.",
                        at: argument.expression)
                    return nil
                }
                if let bad = namespace.first(where: {
                    !($0.isLowercase && $0.isLetter) && !$0.isNumber && $0 != "_" && $0 != "."
                }) {
                    context.diagnoseError(
                        "cache.namespacecharset",
                        "namespace: '\(namespace)' contains '\(bad)'. Use lowercase letters, digits, underscores and dots: the namespace becomes the config key cache.namespaces.\(namespace), and Flight's environment overrides render that as FLIGHT_CACHE_NAMESPACES_… — anything else produces a variable name a shell cannot set, so the TTL silently cannot be configured.",
                        at: argument.expression)
                    return nil
                }
                arguments.namespace = literal.trimmedDescription
            case "ttl" where supportsTTL:
                arguments.ttl = argument.expression.trimmedDescription
            case "allEntries":
                guard let literal = argument.expression.as(BooleanLiteralExprSyntax.self) else {
                    context.diagnoseError(
                        "cache.allentriesliteral",
                        "allEntries: must be the literal true or false — eviction blast radius is a compile-time decision.",
                        at: argument.expression)
                    return nil
                }
                arguments.allEntries = literal.literal.tokenKind == .keyword(.true)
            case "excluding":
                guard let array = argument.expression.as(ArrayExprSyntax.self) else {
                    context.diagnoseError(
                        "cache.excludingliteral",
                        "excluding: must be an array literal of parameter-name string literals.",
                        at: argument.expression)
                    return nil
                }
                for element in array.elements {
                    guard let literal = element.expression.as(StringLiteralExprSyntax.self),
                        literal.segments.count == 1,
                        let segment = literal.segments.first?.as(StringSegmentSyntax.self)
                    else {
                        context.diagnoseError(
                            "cache.excludingliteral",
                            "excluding: must be an array literal of parameter-name string literals.",
                            at: element.expression)
                        return nil
                    }
                    arguments.excluded.append(segment.content.text)
                }
            default:
                break
            }
        }
        return arguments
    }

    // MARK: - Function shape

    /// Validates the annotated declaration and extracts everything the
    /// expansion needs. `requiresResult` is true for @Cacheable/@CachePut
    /// (a cached Void is meaningless).
    static func analyze(
        declaration: some DeclSyntaxProtocol,
        attribute node: AttributeSyntax,
        macroName: String,
        requiresResult: Bool,
        excluding excluded: [String],
        in context: some MacroExpansionContext
    ) -> Target? {
        guard let function = declaration.as(FunctionDeclSyntax.self) else {
            context.diagnoseError(
                "cache.notfunction", "@\(macroName) can only be attached to a method or function.",
                at: node)
            return nil
        }
        guard let body = function.body else {
            context.diagnoseError(
                "cache.nobody", "@\(macroName) requires a function with a body.", at: function)
            return nil
        }

        let effects = function.signature.effectSpecifiers
        guard effects?.asyncSpecifier != nil else {
            context.diagnoseError(
                "cache.notasync",
                "@\(macroName) requires an async method — the Cache protocol is async, and a synchronous caching path would need a blocking store API this package deliberately doesn't have.",
                at: function.name)
            return nil
        }
        let throwsClause = effects?.throwsClause
        if let throwsClause, throwsClause.leftParen != nil {
            context.diagnoseError(
                "cache.typedthrows",
                "@\(macroName) does not support typed throws — the cache runtime propagates coalesced errors as any Error. Use an untyped throws.",
                at: throwsClause)
            return nil
        }

        let declaredReturn = function.signature.returnClause?.type.trimmedDescription
        let isVoid = declaredReturn == nil || declaredReturn == "Void" || declaredReturn == "()"
        if requiresResult && isVoid {
            context.diagnoseError(
                "cache.noreturn",
                "@\(macroName) requires a method that returns a value — caching Void is meaningless. Use @CacheEvict for side-effecting invalidation.",
                at: function.name)
            return nil
        }

        // Key-contributing parameters: internal names, minus exclusions.
        var parameterNames: [String] = []
        for parameter in function.signature.parameterClause.parameters {
            let internalName = (parameter.secondName ?? parameter.firstName).text
            if internalName == "_" {
                // Deliberately not "add it to excluding:": matching is by
                // internal name, and `_` is exactly the absence of one — so
                // that advice sent the reader to a second error rather than a
                // fix. Naming the parameter is the only way out.
                context.diagnoseError(
                    "cache.unnamedparameter",
                    "@\(macroName) cannot key on a parameter with no internal name. Give it one — `func f(_ id: Int)` rather than `func f(_: Int)` — since both keying on it and excluding it are by internal name.",
                    at: parameter)
                return nil
            }
            if !excluded.contains(internalName) {
                parameterNames.append(internalName)
            }
        }
        // Every excluding: name must exist — a typo here would silently
        // change the key (anti-SpEL rule).
        let allNames = function.signature.parameterClause.parameters.map {
            ($0.secondName ?? $0.firstName).text
        }
        for name in excluded where !allNames.contains(name) {
            context.diagnoseError(
                "cache.unknownexcluded",
                "excluding: names parameter '\(name)', but \(function.name.text) has no parameter with that internal name.",
                at: node)
            return nil
        }

        return Target(
            isThrowing: throwsClause != nil,
            returnType: isVoid ? "Void" : declaredReturn!,
            bodyText: body.statements.trimmedDescription,
            keyParameterNames: parameterNames
        )
    }

    /// `[FlightCache.CacheKey.part(a), FlightCache.CacheKey.part(b)]` — the
    /// generic constraint on `part(_:)` is the conformance check.
    static func partsLiteral(for target: Target) -> String {
        "[" + target.keyParameterNames.map { "FlightCache.CacheKey.part(\($0))" }.joined(separator: ", ") + "]"
    }

    /// The original body, for error recovery: returning it after a
    /// diagnostic avoids cascading "missing return" errors.
    static func existingBody(
        of declaration: some DeclSyntaxProtocol & WithOptionalCodeBlockSyntax
    ) -> [CodeBlockItemSyntax] {
        declaration.body.map { Array($0.statements) } ?? []
    }
}
