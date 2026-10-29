import Foundation

// MARK: - Values

enum FlagValue: Codable, Equatable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    var boolValue: Bool? { if case .bool(let v) = self { return v }; return nil }
    var intValue: Int? { if case .int(let v) = self { return v }; return nil }
    var doubleValue: Double? { if case .double(let v) = self { return v }; return nil }
    var stringValue: String? { if case .string(let v) = self { return v }; return nil }
}

struct OptionAssignment: Codable, Equatable {
    /// False = "don't pass this flag at all" (server default applies).
    var included: Bool
    var value: FlagValue
}

// MARK: - Launch configuration

struct LaunchConfig: Codable, Equatable {
    var assignments: [String: OptionAssignment] = [:]

    init() {}
    init(assignments: [String: OptionAssignment]) { self.assignments = assignments }

    func assignment(for option: SushiOption) -> OptionAssignment {
        assignments[option.id] ?? LaunchConfig.defaultAssignment(for: option)
    }

    static func defaultAssignment(for option: SushiOption) -> OptionAssignment {
        switch option.kind {
        case .presence:          return OptionAssignment(included: false, value: .bool(false))
        case .onOff:             return OptionAssignment(included: false, value: .bool(true))
        case .int(let d):        return OptionAssignment(included: false, value: .int(d))
        case .double(let d):     return OptionAssignment(included: false, value: .double(d))
        case .text(let d):       return OptionAssignment(included: false, value: .string(d))
        case .choice(let opts):  return OptionAssignment(included: false, value: .string(opts.first ?? ""))
        }
    }

    mutating func set(_ option: SushiOption, included: Bool, value: FlagValue) {
        assignments[option.id] = OptionAssignment(included: included, value: value)
    }

    mutating func setValue(_ option: SushiOption, _ value: FlagValue) {
        let current = assignment(for: option)
        assignments[option.id] = OptionAssignment(included: current.included, value: value)
    }

    mutating func setIncluded(_ option: SushiOption, _ included: Bool) {
        let current = assignment(for: option)
        assignments[option.id] = OptionAssignment(included: included, value: current.value)
    }

    // MARK: Derived conveniences

    var modelText: String {
        assignments["model"]?.value.stringValue?.trimmed.nonEmpty ?? "~/.sushi/models"
    }
    var hostText: String {
        passedString("host") ?? "127.0.0.1"
    }
    var portInt: Int {
        if let a = assignments["port"], a.included, let n = a.value.intValue { return n }
        return 12345
    }
    var family: ModelFamily { ModelFamily.detect(from: modelText) }

    func isSet(_ id: String) -> Bool { assignments[id]?.included == true }

    private func passedString(_ id: String) -> String? {
        guard let a = assignments[id], a.included, let s = a.value.stringValue?.trimmed, !s.isEmpty else { return nil }
        return s
    }

    // MARK: Argument building

    /// Full argv for the sushi executable: ["serve", "--flag", …].
    func arguments() -> [String] {
        var args = ["serve"]
        for option in SushiOptionRegistry.all {
            guard let a = assignments[option.id], a.included else { continue }
            switch a.value {
            case .bool(let b):
                switch option.kind {
                case .onOff:
                    args.append(b ? option.flagName : option.negationName)
                default:
                    if b { args.append(option.flagName) }
                }
            case .int(let n):
                args.append(contentsOf: [option.flagName, String(n)])
            case .double(let d):
                args.append(contentsOf: [option.flagName, LaunchConfig.format(d)])
            case .string(let s):
                let t = s.trimmed
                if !t.isEmpty {
                    args.append(contentsOf: [option.flagName, t.expandingTilde])
                }
            }
        }
        return args
    }

    /// A copy-pasteable command line, quoted where needed.
    var commandLinePreview: String {
        "sushi " + arguments()
            .map { arg in
                arg.contains(where: { $0 == " " || $0 == "\t" || $0 == "'" })
                    ? "'\(arg.replacingOccurrences(of: "'", with: "'\\''"))'"
                    : arg
            }
            .joined(separator: " ")
    }

    static func format(_ d: Double) -> String {
        if d.isInteger && abs(d) < 1_000_000_000 { return String(Int(d)) }
        return String(format: "%g", d)
    }
}

private extension Double {
    var isInteger: Bool { rounded() == self && !isNaN && !isInfinite }
}
