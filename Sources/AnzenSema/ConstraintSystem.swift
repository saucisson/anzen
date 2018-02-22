import AnzenTypes

public class ConstraintSystem {

    public typealias Solution = [TypeVariable: SemanticType]

    public init<S>(constraints: S, partialSolution: Solution = [:])
        where S: Sequence, S.Element == Constraint
    {
        self.constraints = Array(constraints)
        self.solution    = partialSolution
    }

    public func next() throws -> Solution? {
        // If there's a non-depleted sub-system, first iterate through its solutions.
        if let solution = try self.subSystem?.next() {
            return solution
        } else {
            self.subSystem = nil
        }

        // Make sure we still have solutions to iterate over.
        guard !self.done else { return nil }

        // Otherwise, try to solve as many constraints as possible before creating one.
        while self.index < self.constraints.count {
            let constraint = self.constraints[self.index]
            switch constraint {
            // Equality constraints can generally be solved immediately, as they do not require
            // any prior knowledge. They simply consist of a unification of both types.
            case .equals(let x, let y):
                let a = self.walk(x)
                let b = self.walk(y)

                // Unifying a type alias with a function type isn't necessary inconsistent. It may
                // happen when a equality constraint is placed on a callee that represents a type
                // initializer. In that case, instead of unifying both types, we must look for the
                // type's initializers and try to unify each of them.
                if let alias = a as? TypeAlias, let fun = b as? FunctionType {
                    guard let initializers = self.find(member: "__new__", in: alias.type) else {
                        self.subSystem = self.deferringCurrentConstraint
                        self.done      = true
                        return try self.subSystem?.next()
                    }

                    switch initializers.count {
                    case 0:
                        let walked = self.walk(alias.type)
                        throw InferenceError(reason: "'\(walked)' has no initializer")

                    case 1:
                        try self.unify(fun, initializers[0])

                    default:
                        let head = Constraint.or(initializers.map({ ty in
                            Constraint.equals(fun, ty)
                        }))
                        let remaining  = self.constraints.dropFirst(self.index + 1)
                        self.subSystem = ConstraintSystem(
                            constraints    : [head] + remaining,
                            partialSolution: self.solution)
                        self.done = true
                        return try self.subSystem!.next()
                    }
                } else {
                    try self.unify(x, y)
                }

            // TODO: For the time being, we process conformance constraint the same way we process
            // equality constraints. However, when we'll implement interfaces, we'll have to use a
            // different kind of unification. Moreover, this will probably require some knowledge
            // on the type profiles to have already been inferred.
            case .conforms(let x, let y):
                try self.unify(x, y)

            case .specializes(let x, let y):
                let wl = self.walk(x)
                let wr = self.walk(y)
                guard !(wr is TypeVariable) else {
                    self.subSystem = self.deferringCurrentConstraint
                    self.done      = true
                    return try self.subSystem?.next()
                }
                guard let specialized = self.specialize(wl, wr) else {
                    throw InferenceError(reason: "'\(wl)' is not a specialization of '\(wr)'")
                }

                try self.unify(wl, specialized)

            // Membership constraints require the profile of the owning type to have already been
            // inferred. When that's the case, it can be solved immediately, unless the targetted
            // member is overloaded, in which case a sub-system will be created with a disjunction
            // of constraints for each of the overloads. If the owning type hasn't been inferred
            // yet, the constraint is deferred.
            case .belongs(let symbol, let type):
                // FIXME: Deep walk the type.
                guard let members = self.find(member: symbol.name, in: type) else {
                    self.subSystem = self.deferringCurrentConstraint
                    self.done      = true
                    return try self.subSystem?.next()
                }

                switch members.count {
                case 0:
                    let walked = self.walk(type)
                    throw InferenceError(reason: "'\(walked)' has no member '\(symbol.name)'")

                case 1:
                    try self.unify(symbol.type, members[0])

                default:
                    let head = Constraint.or(members.map({ ty in
                        Constraint.equals(symbol.type, ty)
                    }))
                    let remaining  = self.constraints.dropFirst(self.index + 1)
                    self.subSystem = ConstraintSystem(
                        constraints    : [head] + remaining,
                        partialSolution: self.solution)
                    self.done = true
                    return try self.subSystem!.next()
                }

            // A disjunction of constraints represents possible backtracking points. Whenever we
            // encounter one, we explore all solutions that can be produced for each choice,
            // backtracking whenever there we've iterated through all.
            case .disjunction(let choices):
                guard self.disjunctionIndex < choices.count else {
                    self.done = true
                    return nil
                }

                let head       = choices[self.disjunctionIndex]
                let remaining  = self.constraints.dropFirst(self.index + 1)
                self.subSystem = ConstraintSystem(
                    constraints    : [head] + remaining,
                    partialSolution: self.solution)
                self.disjunctionIndex += 1
                return try self.subSystem!.next()
            }

            self.index += 1
        }

        let memo = Memo()
        var reified: Solution = [:]
        for (key, value) in self.solution {
            reified[key] = self.deepWalk(value, memo: memo)
        }

        self.done = true
        return reified
    }

    public var constraints: [Constraint]

    // MARK: Internals

    /// Unifies two types.
    ///
    /// Unification is the mechanism we use to bind type variables to their actual type. The main
    /// concept is that given two types (possibly aggregates of multiple subtypes), we try to find
    /// one possible binding for which the types are equivalent. If such binding can't be found,
    /// then the constraints are unsatisfiable, meaning that the program is type-inconsistent.
    private func unify(_ x: SemanticType, _ y: SemanticType, memo: Memo = Memo()) throws {
        let a = self.walk(x)
        let b = self.walk(y)

        // Nothing to unify if the types are already equivalent.
        guard !a.equals(to: b) else { return }

        switch (a, b) {
        case (let v as TypeVariable, _):
            self.solution[v] = b
        case (_, let v as TypeVariable):
            self.solution[v] = a

        case (let fnl as FunctionType, let fnr as FunctionType):
            // Make sure the domain of both functions agree.
            guard fnl.domain.count == fnr.domain.count else {
                throw InferenceError(reason: "'\(fnl)' is not '\(fnr)'")
            }

            // Unify the functions' domains.
            for (dl, dr) in zip(fnl.domain, fnr.domain) {
                // Make sure the labels are identical.
                guard dl.label == dr.label else {
                    throw InferenceError(reason: "'\(fnl)' is not '\(fnr)'")
                }

                try self.unify(dl.type.type, dr.type.type, memo: memo)
            }

            // Unify the functions' codomains.
            try self.unify(fnl.codomain.type, fnr.codomain.type, memo: memo)

        case (let sl as StructType, let sr as StructType):
            guard sl.name == sr.name else {
                throw InferenceError(reason: "'\(sl)' is not '\(sr)'")
            }

        default:
            fatalError("TODO")
        }
    }

    /// Attempts to specialize `y` so that it is compatible with `x`.
    private func specialize(_ x: SemanticType, _ y: SemanticType, memo: Memo = Memo())
        -> SemanticType?
    {
        let a = self.walk(x)
        let b = self.walk(y)

        // Nothing to specialize if the types are already equivalent.
        guard !a.equals(to: b) else { return a }

        switch (a, b) {
        case (let p as TypePlaceholder, _):
            if let specialization = memo[p] {
                return specialization
            } else {
                memo[p] = b
                return b
            }

        case (_, _ as TypePlaceholder):
            return self.specialize(b, a, memo: memo)

        case (let fnl as FunctionType, let fnr as FunctionType):
            // Make sure the domain of both functions agree.
            guard fnl.domain.count == fnr.domain.count else { return nil }

            var domain: [FunctionType.ParameterDescription] = []
            for (dl, dr) in zip(fnl.domain, fnr.domain) {
                // Make sure the labels are identical.
                guard dl.label == dr.label else { return nil }

                // Make sure the parameters' qualifiers are identical (if any).
                guard  dl.type.qualifiers.isEmpty
                    || dr.type.qualifiers.isEmpty
                    || dl.type.qualifiers == dr.type.qualifiers else { return nil }

                // Specialize the parameter.
                guard let specialized = self.specialize(dl.type.type, dr.type.type, memo: memo)
                    else { return nil }
                domain.append((
                    dl.label,
                    specialized.qualified(by: dl.type.qualifiers.union(dr.type.qualifiers))))
            }

            // Make sure the codomains' qualifiers are identical (if any)
            guard  fnl.codomain.qualifiers.isEmpty
                || fnl.codomain.qualifiers.isEmpty
                || fnl.codomain.qualifiers == fnr.codomain.qualifiers else { return nil }

            // Specialize the codomain
            guard let codomain = self.specialize(fnl.codomain.type, fnr.codomain.type, memo: memo)
                else { return nil }

            return FunctionType(
                from: domain,
                to  : codomain.qualified(
                    by: fnl.codomain.qualifiers.union(fnr.codomain.qualifiers)))

        case (_ as StructType, _ as StructType):
            // TODO: Specialize struct types.
            fatalError("TODO")

        // Other pairs either are incompatible types or involve type variables. In both cases,
        // unification should decide how to proceed, so we return the right type, unchanged.
        default:
            return b
        }
    }

    private func walk(_ x: SemanticType) -> SemanticType {
        guard let v = x as? TypeVariable else { return x }
        if let walked = self.solution[v] {
            return self.walk(walked)
        } else {
            return v
        }
    }

    private func deepWalk(_ x: SemanticType, memo: Memo) -> SemanticType {
        switch x {
        case let v as TypeVariable:
            if let walked = self.solution[v] {
                return self.deepWalk(walked, memo: memo)
            } else {
                return v
            }

        case let a as TypeAlias:
            return TypeAlias(name: a.name, aliasing: self.deepWalk(a.type, memo: memo))

        case let f as FunctionType:
            return FunctionType(
                placeholders: f.placeholders,
                from: f.domain.map({
                    ($0.label, self.deepWalk($0.type.type, memo: memo)
                        .qualified(by: $0.type.qualifiers))
                }),
                to: self.deepWalk(f.codomain.type, memo: memo)
                    .qualified(by: f.codomain.qualifiers))

        case let s as StructType:
            if let walked = memo[s] { return walked }
            let walked = StructType(name: s.name, placeholders: s.placeholders)
            memo[s] = walked

            for (key, value) in s.properties {
                walked.properties[key] = self.deepWalk(value.type, memo: memo)
                    .qualified(by: value.qualifiers)
            }
            for (key, values) in s.methods {
                walked.methods[key] = values.map { self.deepWalk($0, memo: memo) }
            }

            return walked

        default:
            return x
        }
    }

    /// Retrieve the type of the named member(s) of a type.
    private func find(member: String, in type: SemanticType) -> [SemanticType]? {
        switch self.walk(type) {
        case let alias as TypeAlias:
            guard let members = self.find(member: member, in: alias.type) else { return nil }
            return members.map { ty in
                FunctionType(
                    from: [(nil, alias.type.qualified(by: .mut))],
                    to  : ty.qualified(by: .cst))
            }

        case let structType as StructType:
            if let propType = structType.properties[member]?.type {
                return [propType]
            } else if let methTypes = structType.methods[member] {
                return methTypes
            } else {
                return []
            }

        default:
            return nil
        }
    }

    /// A sub-system that defers the current constraint.
    private var deferringCurrentConstraint: ConstraintSystem {
        let constraint = self.constraints[self.index]
        let head       = self.constraints.dropFirst(self.index + 1)
        return ConstraintSystem(
            constraints    : head + [constraint],
            partialSolution: self.solution)
    }

    private var subSystem: ConstraintSystem? = nil
    private var solution : Solution

    private var index           : Int = 0
    private var disjunctionIndex: Int = 0
    private var done            : Bool = false

}

fileprivate class Memo: Sequence {

    typealias Element = (key: AnyObject, value: SemanticType)

    var content: [Element] = []

    func makeIterator() -> Array<Element>.Iterator {
        return self.content.makeIterator()
    }

    subscript(object: AnyObject) -> SemanticType? {
        get {
            return self.content.first(where: { $0.key === object })?.value
        }

        set {
            if let index = self.content.index(where: { $0.key === object }) {
                if let value = newValue {
                    self.content[index] = (key: object, value: value)
                } else {
                    self.content.remove(at: index)
                }
            } else if let value = newValue {
                self.content.append((key: object, value: value))
            }
        }
    }

}