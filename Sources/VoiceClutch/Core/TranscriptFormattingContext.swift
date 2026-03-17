import AppKit
import Foundation

enum TranscriptFormattingDomain: String, Sendable {
    case general
    case messaging
    case documents
    case email
    case code
    case terminal

    static func infer(from bundleIdentifier: String?) -> TranscriptFormattingDomain {
        guard let bundleIdentifier = bundleIdentifier?.lowercased(), !bundleIdentifier.isEmpty else {
            return .general
        }

        if bundleIdentifier.contains("xcode")
            || bundleIdentifier.contains("code")
            || bundleIdentifier.contains("jetbrains")
        {
            return .code
        }

        if bundleIdentifier.contains("terminal")
            || bundleIdentifier.contains("iterm")
            || bundleIdentifier.contains("warp")
            || bundleIdentifier.contains("hyper")
        {
            return .terminal
        }

        if bundleIdentifier.contains("mail")
            || bundleIdentifier.contains("outlook")
            || bundleIdentifier.contains("sparkmail")
            || bundleIdentifier.contains("airmail")
        {
            return .email
        }

        if bundleIdentifier.contains("messages")
            || bundleIdentifier.contains("mobilesms")
            || bundleIdentifier.contains("telegram")
            || bundleIdentifier.contains("slack")
            || bundleIdentifier.contains("discord")
            || bundleIdentifier.contains("whatsapp")
            || bundleIdentifier.contains("signal")
        {
            return .messaging
        }

        if bundleIdentifier.contains("textedit")
            || bundleIdentifier.contains("pages")
            || bundleIdentifier.contains("word")
            || bundleIdentifier.contains("notion")
            || bundleIdentifier.contains("obsidian")
        {
            return .documents
        }

        return .general
    }
}

struct TranscriptFormattingContext: Sendable {
    let bundleIdentifier: String?
    let appName: String?
    let domain: TranscriptFormattingDomain
    let requiresCodeSyntaxPostEdit: Bool

    init(
        bundleIdentifier: String? = nil,
        appName: String? = nil,
        domain: TranscriptFormattingDomain? = nil,
        requiresCodeSyntaxPostEdit: Bool? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.domain = domain ?? TranscriptFormattingDomain.infer(from: bundleIdentifier)
        self.requiresCodeSyntaxPostEdit = requiresCodeSyntaxPostEdit ?? Self.requiresCodeSyntaxPostEdit(
            from: self.domain,
            bundleIdentifier: bundleIdentifier
        )
    }

    static func requiresCodeSyntaxPostEdit(
        from domain: TranscriptFormattingDomain,
        bundleIdentifier: String?
    ) -> Bool {
        let lowercasedBundleIdentifier = bundleIdentifier?.lowercased() ?? ""
        if lowercasedBundleIdentifier.contains("terminal")
            || lowercasedBundleIdentifier.contains("iterm")
            || lowercasedBundleIdentifier.contains("warp")
            || lowercasedBundleIdentifier.contains("hyper") {
            return true
        }

        return domain == .code || domain == .terminal
    }
}

@MainActor
protocol TranscriptFormattingContextProviding {
    func currentContext() -> TranscriptFormattingContext
}

@MainActor
struct FrontmostTranscriptFormattingContextProvider: TranscriptFormattingContextProviding {
    func currentContext() -> TranscriptFormattingContext {
        let app = NSWorkspace.shared.frontmostApplication
        return TranscriptFormattingContext(
            bundleIdentifier: app?.bundleIdentifier,
            appName: app?.localizedName
        )
    }
}
