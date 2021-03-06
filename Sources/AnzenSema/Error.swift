import AnzenTypes
import Parsey

public protocol SemanticError: Error {

    var location: SourceRange? { get }

}

public struct DuplicateDeclaration: SemanticError, CustomStringConvertible {

    public init(name: String, at location: SourceRange? = nil) {
        self.name     = name
        self.location = location
    }

    public let name    : String
    public let location: SourceRange?

    public var description: String {
        let location = self.location != nil
            ? "\(self.location!.lowerBound)"
            : "?:?"
        return "\(location): duplicate declaration: \(self.name)"
    }

}

public struct UndefinedSymbol: SemanticError, CustomStringConvertible {

    public init(name: String, at location: SourceRange? = nil) {
        self.name     = name
        self.location = location
    }

    public let name    : String
    public let location: SourceRange?

    public var description: String {
        let location = self.location != nil
            ? "\(self.location!.lowerBound)"
            : "?:?"
        return "\(location): undefined symbol: \(self.name)"
    }

}

public struct InferenceError: SemanticError, CustomStringConvertible {

    public init(reason: String? = nil, location: SourceRange? = nil) {
        self.reason   = reason
        self.location = location
    }

    public let reason  : String?
    public let location: SourceRange?

    public var description: String {
        let location = self.location != nil
            ? "\(self.location!.lowerBound)"
            : "?:?"
        return self.reason != nil
            ? "\(location): inference error: \(self.reason!)"
            : "\(location): inference error"
    }

}

public struct AmbiguousType: SemanticError, CustomStringConvertible {

    public init(expr: String, candidates: [SemanticType], location: SourceRange? = nil) {
        self.expr       = expr
        self.candidates = candidates
        self.location   = location
    }

    public let expr      : String
    public let candidates: [SemanticType]
    public let location  : SourceRange?

    public var description: String {
        let location = self.location != nil
            ? "\(self.location!.lowerBound)"
            : "?:?"
        return "\(location): ambiguous type: cannot chose between \(self.candidates)"
    }

}
