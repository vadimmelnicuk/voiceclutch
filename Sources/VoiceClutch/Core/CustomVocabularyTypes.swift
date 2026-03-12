import Foundation

public struct CustomVocabularyTerm: Codable, Sendable {
    public let text: String
    public let weight: Float?
    public let aliases: [String]?
    public let tokenIds: [Int]?
    public let ctcTokenIds: [Int]?
    public let textLowercased: String

    private enum CodingKeys: String, CodingKey {
        case text, weight, aliases, tokenIds, ctcTokenIds
    }

    public init(
        text: String,
        weight: Float? = nil,
        aliases: [String]? = nil,
        tokenIds: [Int]? = nil,
        ctcTokenIds: [Int]? = nil
    ) {
        self.text = text
        self.weight = weight
        self.aliases = aliases
        self.tokenIds = tokenIds
        self.ctcTokenIds = ctcTokenIds
        self.textLowercased = text.lowercased()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        weight = try container.decodeIfPresent(Float.self, forKey: .weight)
        aliases = try container.decodeIfPresent([String].self, forKey: .aliases)
        tokenIds = try container.decodeIfPresent([Int].self, forKey: .tokenIds)
        ctcTokenIds = try container.decodeIfPresent([Int].self, forKey: .ctcTokenIds)
        textLowercased = text.lowercased()
    }
}

public struct CustomVocabularyContext: Sendable {
    public let terms: [CustomVocabularyTerm]

    public init(terms: [CustomVocabularyTerm]) {
        self.terms = terms
    }
}
