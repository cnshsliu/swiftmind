import Foundation

enum WriteCommands {
    static func run(command: String, path: String, flags: [String: String]) throws {
        throw CLIError.usage("unknown or unimplemented command: \(command)")
    }
}
