import Foundation

enum WindowsLaunchArguments {
    static func parse(_ command: String) -> [String]? {
        guard command.utf8.count <= 4096,
              !command.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 10 || $0.value == 13 }) else {
            return nil
        }

        let characters = Array(command)
        var index = 0
        var arguments: [String] = []

        while index < characters.count {
            while index < characters.count && characters[index].isWhitespace { index += 1 }
            if index == characters.count { break }

            var value = ""
            var quoted = false

            while index < characters.count {
                let character = characters[index]
                if character == "\\" {
                    var backslashes = 0
                    while index < characters.count && characters[index] == "\\" {
                        backslashes += 1
                        index += 1
                    }

                    if index < characters.count && characters[index] == "\"" {
                        value += String(repeating: "\\", count: backslashes / 2)
                        if backslashes.isMultiple(of: 2) {
                            if quoted && index + 1 < characters.count && characters[index + 1] == "\"" {
                                value.append("\"")
                                index += 2
                            } else {
                                quoted.toggle()
                                index += 1
                            }
                        } else {
                            value.append("\"")
                            index += 1
                        }
                    } else {
                        value += String(repeating: "\\", count: backslashes)
                    }
                } else if character == "\"" {
                    if quoted && index + 1 < characters.count && characters[index + 1] == "\"" {
                        value.append("\"")
                        index += 2
                    } else {
                        quoted.toggle()
                        index += 1
                    }
                } else if character.isWhitespace && !quoted {
                    break
                } else {
                    value.append(character)
                    index += 1
                }
            }

            guard !quoted, value.utf8.count < 1024 else { return nil }
            arguments.append(value)
            if arguments.count > 64 { return nil }
        }

        return arguments
    }
}
