import Foundation

indirect enum SteamValue: Equatable {
    case string(String)
    case object([String: SteamValue])

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var fields: [String: SteamValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    subscript(_ key: String) -> SteamValue? {
        fields?[key]
    }
}

struct SteamKeyValues {
    enum ParseError: Error {
        case invalidEncoding
        case invalidSyntax
        case nestingLimit
        case sizeLimit
    }

    private let characters: [Character]
    private var index = 0
    private let maxDepth = 64

    init(_ data: Data) throws {
        guard data.count <= 1 << 20 else { throw ParseError.sizeLimit }
        guard let string = String(data: data, encoding: .utf8) else { throw ParseError.invalidEncoding }
        characters = Array(string)
    }

    mutating func read() throws -> SteamValue {
        let result = try readObject(depth: 0, nested: false)
        skipWhitespaceAndComments()
        guard index == characters.count else { throw ParseError.invalidSyntax }
        return .object(result)
    }

    private mutating func readObject(depth: Int, nested: Bool) throws -> [String: SteamValue] {
        guard depth <= maxDepth else { throw ParseError.nestingLimit }
        var fields: [String: SteamValue] = [:]
        while true {
            skipWhitespaceAndComments()
            guard index < characters.count else {
                if nested { throw ParseError.invalidSyntax }
                return fields
            }
            if characters[index] == "}" {
                guard nested else { throw ParseError.invalidSyntax }
                index += 1
                return fields
            }
            let key = try readString()
            skipWhitespaceAndComments()
            guard index < characters.count else { throw ParseError.invalidSyntax }
            if characters[index] == "{" {
                index += 1
                fields[key] = .object(try readObject(depth: depth + 1, nested: true))
            } else {
                fields[key] = .string(try readString())
            }
        }
    }

    private mutating func readString() throws -> String {
        skipWhitespaceAndComments()
        guard index < characters.count, characters[index] == "\"" else { throw ParseError.invalidSyntax }
        index += 1
        var value = ""
        while index < characters.count {
            let character = characters[index]
            index += 1
            if character == "\"" { return value }
            if character == "\\" {
                guard index < characters.count else { throw ParseError.invalidSyntax }
                let escaped = characters[index]
                index += 1
                switch escaped {
                case "n": value.append("\n")
                case "t": value.append("\t")
                case "r": value.append("\r")
                case "\\": value.append("\\")
                case "\"": value.append("\"")
                default: value.append("\\"); value.append(escaped)
                }
            } else {
                value.append(character)
            }
        }
        throw ParseError.invalidSyntax
    }

    private mutating func skipWhitespaceAndComments() {
        while index < characters.count {
            if characters[index].isWhitespace || characters[index] == "\u{feff}" {
                index += 1
                continue
            }
            if index + 1 < characters.count, characters[index] == "/", characters[index + 1] == "/" {
                index += 2
                while index < characters.count, characters[index] != "\n" { index += 1 }
                continue
            }
            break
        }
    }
}
