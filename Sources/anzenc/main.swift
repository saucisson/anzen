import Foundation
import AnzenLib

enum CommandError: Error {
    case missingInput
}

func main(args: [String] = CommandLine.arguments) throws {
    // let programName    = args[0]
    let positionalArgs = args.dropFirst().filter { !$0.starts(with: "-") }
    // let optionalArgs   = args.dropFirst().filter { $0.starts(with: "-") }

    if positionalArgs.isEmpty {
        throw CommandError.missingInput
    }

    let source = try String(contentsOf: URL(fileURLWithPath: positionalArgs[0]))
    let module = try AnzenLib.Grammar.module.parse(source)
    print(module)
}

do {
    try main()
} catch(let e) {
    print(e)
    exit(1)
}
exit(0)