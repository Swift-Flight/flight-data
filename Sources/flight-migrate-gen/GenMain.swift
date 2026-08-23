import FlightMigrateCore
import Foundation

/// Build-time registry generator, invoked by `FlightMigratePlugin`:
///
///     flight-migrate-gen --target-name <name> --output <path> <input.swift> ...
///
/// Reads every source file of the migrations target, validates the migration set, and
/// writes the `_allMigrations()` registry. Any problem (malformed or duplicate timestamp,
/// filename/type mismatch, ...) prints `error:` diagnostics and exits non-zero, failing
/// the build — which is the whole point.
@main
struct GenMain {
    static func main() {
        do {
            try run(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch let error as RegistryGenerator.GeneratorError {
            FileHandle.standardError.write(Data((error.description + "\n").utf8))
            exit(1)
        } catch {
            FileHandle.standardError.write(
                Data("error: [FlightMigrate] \(error)\n".utf8))
            exit(1)
        }
    }

    static func run(arguments: [String]) throws {
        var targetName: String?
        var outputPath: String?
        var inputPaths: [String] = []

        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--target-name":
                index += 1
                guard index < arguments.count else { throw UsageError.missingValue("--target-name") }
                targetName = arguments[index]
            case "--output":
                index += 1
                guard index < arguments.count else { throw UsageError.missingValue("--output") }
                outputPath = arguments[index]
            default:
                inputPaths.append(arguments[index])
            }
            index += 1
        }

        guard let targetName, let outputPath else {
            throw UsageError.usage
        }

        let files: [RegistryGenerator.InputFile] = try inputPaths.map { path in
            let url = URL(fileURLWithPath: path)
            let contents = try String(contentsOf: url, encoding: .utf8)
            return RegistryGenerator.InputFile(
                path: path, filename: url.lastPathComponent, contents: contents)
        }

        let generated = try RegistryGenerator.generate(targetName: targetName, files: files)
        try generated.write(
            to: URL(fileURLWithPath: outputPath), atomically: true, encoding: .utf8)
    }

    enum UsageError: Error, CustomStringConvertible {
        case usage
        case missingValue(String)

        var description: String {
            switch self {
            case .usage:
                return "usage: flight-migrate-gen --target-name <name> --output <path> <inputs...>"
            case .missingValue(let flag):
                return "missing value for \(flag)"
            }
        }
    }
}
