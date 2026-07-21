import Foundation

enum SpokenSubtitleFormatter {
    private static let strongTerminators: Set<Character> = ["。", "！", "？", "!", "?"]
    private static let closingPunctuation: Set<Character> = [
        "\"", "'", "”", "’", "」", "』", "）", ")", "】", "]", "》", "〉"
    ]

    static func format(_ text: String) -> String {
        let characters = Array(
            text.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
        )
        var lines: [String] = []
        var buffer = ""
        var pendingSentenceBreak = false

        func flush() {
            let line = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { lines.append(line) }
            buffer = ""
            pendingSentenceBreak = false
        }

        for index in characters.indices {
            let character = characters[index]
            if character == "\n" {
                flush()
                continue
            }
            if character.isWhitespace {
                if pendingSentenceBreak {
                    flush()
                } else if !buffer.isEmpty, buffer.last != " " {
                    buffer.append(" ")
                }
                continue
            }

            let attachesToCompletedSentence = closingPunctuation.contains(character)
                || strongTerminators.contains(character)
                || character == "…"
                || character == "."
            if pendingSentenceBreak, !attachesToCompletedSentence {
                flush()
            }

            buffer.append(character)
            if isSentenceEnding(character, at: index, in: characters) {
                pendingSentenceBreak = true
            }
        }
        flush()
        return lines.joined(separator: "\n")
    }

    private static func isSentenceEnding(
        _ character: Character,
        at index: Int,
        in characters: [Character]
    ) -> Bool {
        if strongTerminators.contains(character) { return true }
        if character == "…" {
            return nextCharacter(after: index, in: characters) != "…"
        }
        guard character == "." else { return false }

        let previous = previousCharacter(before: index, in: characters)
        let next = nextCharacter(after: index, in: characters)
        if previous?.isNumber == true, next?.isNumber == true { return false }
        if next == "." { return false }
        if previous == "." { return true }
        if next == nil || next == "\n" || next.map(closingPunctuation.contains) == true {
            return true
        }
        if previous.map(isCJK) == true, next.map(isCJK) == true { return true }

        guard next?.isWhitespace == true,
              let nextVisible = nextNonWhitespace(after: index, in: characters) else {
            return false
        }
        if isCJK(nextVisible) { return true }
        if nextVisible.isUppercase {
            let looksLikeInitialism = previous?.isLetter == true
                && index >= 2
                && characters[index - 2] == "."
            return !looksLikeInitialism
        }
        return false
    }

    private static func previousCharacter(before index: Int, in characters: [Character]) -> Character? {
        guard index > characters.startIndex else { return nil }
        return characters[index - 1]
    }

    private static func nextCharacter(after index: Int, in characters: [Character]) -> Character? {
        let nextIndex = index + 1
        guard nextIndex < characters.endIndex else { return nil }
        return characters[nextIndex]
    }

    private static func nextNonWhitespace(after index: Int, in characters: [Character]) -> Character? {
        var cursor = index + 1
        while cursor < characters.endIndex {
            if !characters[cursor].isWhitespace { return characters[cursor] }
            cursor += 1
        }
        return nil
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
                true
            default:
                false
            }
        }
    }
}
