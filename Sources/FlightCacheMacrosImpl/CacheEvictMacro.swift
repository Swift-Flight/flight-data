import SwiftSyntax
import SwiftSyntaxMacros

/// `@CacheEvict` (design §3): call the body, then — on normal return, not
/// on a throw — remove the entry derived from the arguments, or the whole
/// namespace with `allEntries: true`. The flag is explicit: `allEntries:
/// false` with zero key-contributing parameters is a compile error, never
/// an implicit namespace wipe.
public struct CacheEvictMacro: BodyMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingBodyFor declaration: some DeclSyntaxProtocol & WithOptionalCodeBlockSyntax,
        in context: some MacroExpansionContext
    ) throws -> [CodeBlockItemSyntax] {
        guard
            let arguments = CacheMacroSupport.parseArguments(
                of: node, supportsTTL: false, in: context),
            let namespace = arguments.namespace,
            let target = CacheMacroSupport.analyze(
                declaration: declaration, attribute: node, macroName: "CacheEvict",
                requiresResult: false, excluding: arguments.excluded, in: context)
        else {
            return CacheMacroSupport.existingBody(of: declaration)
        }

        if !arguments.allEntries && target.keyParameterNames.isEmpty {
            context.diagnoseError(
                "cache.evictnokey",
                "@CacheEvict has no key-contributing parameters to derive an entry from — pass allEntries: true to evict the whole namespace, or add a key parameter.",
                at: node)
            return CacheMacroSupport.existingBody(of: declaration)
        }

        let parts = arguments.allEntries ? "nil" : CacheMacroSupport.partsLiteral(for: target)
        let effect = target.isThrowing ? "try await" : "await"
        let closureThrows = target.isThrowing ? " throws" : ""

        let evict: ExprSyntax = """
            await FlightCache.FlightCaches.current.evict(namespace: \(raw: namespace), parts: \(raw: parts))
            """

        if target.returnType == "Void" {
            let run: ExprSyntax = """
                \(raw: effect) { () async\(raw: closureThrows) -> Void in
                    \(raw: target.bodyText)
                }()
                """
            return [
                CodeBlockItemSyntax(item: .expr(run)),
                CodeBlockItemSyntax(item: .expr(evict)),
            ]
        } else {
            let run: DeclSyntax = """
                let _flightCacheResult: \(raw: target.returnType) = \(raw: effect) { () async\(raw: closureThrows) -> \(raw: target.returnType) in
                    \(raw: target.bodyText)
                }()
                """
            let giveBack: StmtSyntax = "return _flightCacheResult"
            return [
                CodeBlockItemSyntax(item: .decl(run)),
                CodeBlockItemSyntax(item: .expr(evict)),
                CodeBlockItemSyntax(item: .stmt(giveBack)),
            ]
        }
    }
}
