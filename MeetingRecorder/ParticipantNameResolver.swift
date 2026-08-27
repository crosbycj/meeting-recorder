import Foundation

struct ResolvedParticipant: Sendable {
    let canonicalName: String
    let aliases: [String]
}

struct ResolvedParticipants: Sendable {
    let participants: [ResolvedParticipant]

    var canonicalNames: [String] {
        participants.map(\.canonicalName)
    }
}

enum ParticipantNameResolver {
    static func resolve(attendees: [String]?) -> ResolvedParticipants {
        guard let attendees else {
            return ResolvedParticipants(participants: [])
        }

        var resolvedParticipants: [ResolvedParticipant] = []

        for attendee in attendees {
            let trimmed = normalizeWhitespace(attendee)
            guard !trimmed.isEmpty else {
                continue
            }

            let candidate = isEmail(trimmed) ? buildFromEmail(trimmed) : buildFromDisplayName(trimmed)
            guard !candidate.canonicalName.isEmpty else {
                continue
            }

            if let existingIndex = resolvedParticipants.firstIndex(where: {
                foldedKey(for: $0.canonicalName) == foldedKey(for: candidate.canonicalName)
            }) {
                let mergedAliases = deduplicatingPreservingOrder(
                    resolvedParticipants[existingIndex].aliases + candidate.aliases
                ).filter {
                    foldedKey(for: $0) != foldedKey(for: resolvedParticipants[existingIndex].canonicalName)
                }

                resolvedParticipants[existingIndex] = ResolvedParticipant(
                    canonicalName: resolvedParticipants[existingIndex].canonicalName,
                    aliases: mergedAliases
                )
            } else {
                let aliases = deduplicatingPreservingOrder(candidate.aliases).filter {
                    foldedKey(for: $0) != foldedKey(for: candidate.canonicalName)
                }
                resolvedParticipants.append(
                    ResolvedParticipant(
                        canonicalName: candidate.canonicalName,
                        aliases: aliases
                    )
                )
            }
        }

        return ResolvedParticipants(participants: resolvedParticipants)
    }

    private static func buildFromDisplayName(_ rawName: String) -> ResolvedParticipant {
        let cleaned = sanitizeNameInput(rawName)
        let canonical = toSpokenName(cleaned)
        return ResolvedParticipant(canonicalName: canonical, aliases: [rawName, cleaned])
    }

    private static func buildFromEmail(_ email: String) -> ResolvedParticipant {
        let components = email.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        let fullLocalPart = components.first.map(String.init) ?? ""
        let baseLocalPart = fullLocalPart.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? fullLocalPart

        let canonical = toSpokenName(sanitizeNameInput(baseLocalPart))

        var aliases = [email]
        if !fullLocalPart.isEmpty {
            aliases.append(fullLocalPart)
        }
        if !baseLocalPart.isEmpty {
            aliases.append(baseLocalPart)
        }

        let localAsWords = normalizeLocalPartSeparators(baseLocalPart)
        if !localAsWords.isEmpty {
            aliases.append(localAsWords)
            aliases.append(toSpokenName(localAsWords))
        }

        let condensedLocal = baseLocalPart.replacingOccurrences(
            of: "[._-]+",
            with: "",
            options: .regularExpression
        )
        if !condensedLocal.isEmpty {
            aliases.append(condensedLocal)
        }

        return ResolvedParticipant(canonicalName: canonical, aliases: aliases)
    }

    private static func isEmail(_ value: String) -> Bool {
        value.contains("@")
    }

    private static func sanitizeNameInput(_ value: String) -> String {
        let normalizedSeparators = normalizeLocalPartSeparators(value)
        let cleaned = normalizedSeparators.replacingOccurrences(
            of: "[^A-Za-z0-9 '\\-]",
            with: "",
            options: .regularExpression
        )
        return normalizeWhitespace(cleaned)
    }

    private static func normalizeLocalPartSeparators(_ value: String) -> String {
        let replaced = value.replacingOccurrences(
            of: "[._+\\-]+",
            with: " ",
            options: .regularExpression
        )
        return normalizeWhitespace(replaced)
    }

    private static func toSpokenName(_ value: String) -> String {
        let trimmed = normalizeWhitespace(value)
        guard !trimmed.isEmpty else {
            return ""
        }

        let words = trimmed
            .split(separator: " ")
            .map { titleCaseToken(String($0)) }

        return words.joined(separator: " ")
    }

    private static func titleCaseToken(_ token: String) -> String {
        guard !token.isEmpty else {
            return token
        }

        if token == token.uppercased(), token.count <= 4 {
            return token
        }

        let firstCharacter = String(token.prefix(1)).uppercased()
        let remainder = String(token.dropFirst()).lowercased()
        return firstCharacter + remainder
    }

    private static func normalizeWhitespace(_ value: String) -> String {
        value.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func deduplicatingPreservingOrder(_ values: [String]) -> [String] {
        var deduplicated: [String] = []
        var seen: Set<String> = []

        for value in values {
            let normalized = normalizeWhitespace(value)
            guard !normalized.isEmpty else {
                continue
            }

            let key = foldedKey(for: normalized)
            if seen.insert(key).inserted {
                deduplicated.append(normalized)
            }
        }

        return deduplicated
    }

    private static func foldedKey(for value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
