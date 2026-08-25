import SwiftSyntax
import SwiftSyntaxMacros

/// `@Cacheable`: check cache; on hit return it; on miss call
/// the body, store the result, return it — expanded INTO the method body
///, the same shape as Core's `@Transactional`: the original body
/// rides an immediately-invoked-style closure (here, the runtime's trailing
/// closure) with an explicit signature, and the expansion reaches runtime
/// state through the fully-qualified `FlightCache.FlightCaches` seam.
public struct CacheableMacro: BodyMacro {
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
                declaration: declaration, attribute: node, macroName: "Cacheable",
                requiresResult: true, excluding: arguments.excluded, in: context)
        else {
            return CacheMacroSupport.existingBody(of: declaration)
        }

        let effect = target.isThrowing ? "try await" : "await"
        let closureThrows = target.isThrowing ? " throws" : ""
        let statement: StmtSyntax = """
            return \(raw: effect) FlightCache.FlightCaches.current.cacheable(
                namespace: \(raw: namespace),
                parts: \(raw: CacheMacroSupport.partsLiteral(for: target)),
                ttl: \(raw: arguments.ttl ?? "nil"),
                as: \(raw: target.returnType).self
            ) { () async\(raw: closureThrows) -> \(raw: target.returnType) in
                \(raw: target.bodyText)
            }
            """
        return [CodeBlockItemSyntax(item: .stmt(statement))]
    }
}
