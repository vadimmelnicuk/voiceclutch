import Foundation

public enum ModelRegistry {
    public enum Error: Swift.Error, CustomStringConvertible {
        case invalidURL(String)

        public var description: String {
            switch self {
            case .invalidURL(let urlString):
                return "Invalid URL construction: \(urlString)"
            }
        }
    }

    nonisolated(unsafe) private static var customBaseURL: String?

    public static var baseURL: String {
        get {
            customBaseURL
                ?? ProcessInfo.processInfo.environment["REGISTRY_URL"]
                ?? ProcessInfo.processInfo.environment["MODEL_REGISTRY_URL"]
                ?? "https://huggingface.co"
        }
        set {
            customBaseURL = newValue
        }
    }

    public static func apiModels(_ repoPath: String, _ apiPath: String) throws -> URL {
        try makeURL("\(baseURL)/api/models/\(repoPath)/\(apiPath)")
    }

    public static func resolveModel(_ repoPath: String, _ filePath: String) throws -> URL {
        try makeURL("\(baseURL)/\(repoPath)/resolve/main/\(filePath)")
    }

    private static func makeURL(_ value: String) throws -> URL {
        guard let url = URL(string: value) else {
            throw Error.invalidURL(value)
        }
        return url
    }
}
