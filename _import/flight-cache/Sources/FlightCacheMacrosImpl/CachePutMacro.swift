import SwiftSyntax
import SwiftSyntaxMacros

/// `@CachePut`: always call the body, then overwrite the cached
/// value — never short-circuits. The cross-method key contract is what
/// makes the put land on the entry a `@Cacheable` method reads; remember
/// `excluding:` for the new-value parameter.
public struct CachePutMacro: BodyMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingBodyFor declaration: some DeclSyntaxProtocol & WithOptionalCodeBlockSyntax,
        in context: some MacroExpansionContext
    ) throws -> [CodeBlockItemSyntax] {
        guard
            let arguments = CacheMacroSupport.parseArguments(
                of: node, supportsTTL: true, in: context),
            let namespace = arguments.namespace,
            let target = CacheMacroSupport.analyze(
                declaration: declaration, attribute: node, macroName: "CachePut",
                requiresResult: true, excluding: arguments.excluded, in: context)
        else {
            return CacheMacroSupport.existingBody(of: declaration)
        }

        let effect = target.isThrowing ? "try await" : "await"
        let closureThrows = target.isThrowing ? " throws" : ""
        // The body runs first — a throw means nothing is cached. The
        // explicit closure signature keeps `return` and inference exactly as
        // @Transactional's expansion does.
        let run: DeclSyntax = """
            let _flightCacheValue: \(raw: target.returnType) = \(raw: effect) { () async\(raw: closureThrows) -> \(raw: target.returnType) in
                \(raw: target.bodyText)
            }()
            """
        let put: ExprSyntax = """
            await FlightCache.FlightCaches.current.cachePut(
                namespace: \(raw: namespace),
                parts: \(raw: CacheMacroSupport.partsLiteral(for: target)),
                ttl: \(raw: arguments.ttl ?? "nil"),
                value: _flightCacheValue
            )
            """
        let giveBack: StmtSyntax = "return _flightCacheValue"
        return [
            CodeBlockItemSyntax(item: .decl(run)),
            CodeBlockItemSyntax(item: .expr(put)),
            CodeBlockItemSyntax(item: .stmt(giveBack)),
        ]
    }
}
