import Foundation
import FluidAudio
import OSLog

/// Manages Nemotron ASR model downloads with progress tracking.
@MainActor
class ModelDownloadManager: ObservableObject {

    private static let logger = AppLogger(category: "ModelDownloadManager")
    nonisolated private static var targetRepo: Repo { .nemotronStreaming560 }
    nonisolated private static var requiredModelPaths: Set<String> { ModelNames.NemotronStreaming.requiredModels }

    /// Download progress from 0.0 to 1.0
    @Published private(set) var progress: Double = 0.0

    /// Current download status message
    @Published private(set) var statusMessage: String = ""

    /// Total bytes to download
    private var totalBytes: Int64 = 0

    /// Bytes downloaded so far (from completed files)
    private var completedBytes: Int64 = 0

    /// Bytes downloaded for current file
    private var currentFileBytes: Int64 = 0

    /// Number of files downloaded
    private var filesCompleted: Int = 0

    /// Total number of files to download
    private var totalFiles: Int = 0

    private var downloadTask: Task<Void, Error>?

    /// URLSession for downloads (kept alive to prevent cancellation)
    private var downloadSession: URLSession?

    /// Download delegate (kept alive to prevent cancellation)
    private var currentDelegate: DownloadDelegate?

    nonisolated static var asrModelDirectory: URL {
        modelsRootDirectory.appendingPathComponent(targetRepo.folderName, isDirectory: true)
    }

    nonisolated private static var modelsRootDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("voiceclutch", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
    }

    nonisolated static func areModelsInstalled() -> Bool {
        requiredModelPaths.allSatisfy { modelPath in
            let fullPath = asrModelDirectory.appendingPathComponent(modelPath)
            return FileManager.default.fileExists(atPath: fullPath.path)
        }
    }

    /// Download ASR models for Nemotron 560ms.
    func downloadAsrModels() async throws {
        downloadTask?.cancel()

        downloadTask = Task {
            try await performDownload()
        }

        try await downloadTask?.value
    }

    /// Get total download size in bytes for missing files.
    func getDownloadSize() async throws -> Int64 {
        let files = try await listFilesToDownload()
        return Int64(files.reduce(0) { $0 + max($1.size, 0) })
    }

    private func performDownload() async throws {
        let repoPath = Self.asrModelDirectory

        Self.logger.info("Starting ASR model download to: \(repoPath.path)")

        // Create target directory
        try FileManager.default.createDirectory(at: repoPath, withIntermediateDirectories: true)

        // Reset progress
        progress = 0.0
        completedBytes = 0
        currentFileBytes = 0
        filesCompleted = 0
        statusMessage = "Preparing ASR model download"

        let filesToDownload = try await listFilesToDownload()

        guard !filesToDownload.isEmpty else {
            Self.logger.info("All ASR model files already present")
            progress = 1.0
            statusMessage = "Download complete!"
            return
        }

        totalBytes = Int64(filesToDownload.reduce(0) { $0 + max($1.size, 0) })
        totalFiles = filesToDownload.count

        Self.logger.info("Downloading \(totalFiles) ASR files (\(totalBytes / 1_048_576) MB)")

        // Create all parent directories upfront
        try createParentDirectories(for: filesToDownload, at: repoPath)

        // Download each file
        for file in filesToDownload {
            try Task.checkCancellation()

            let destPath = repoPath.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(
                at: destPath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            // Skip if already exists with correct size.
            if FileManager.default.fileExists(atPath: destPath.path) {
                let attrs = try? FileManager.default.attributesOfItem(atPath: destPath.path)
                let fileSize = attrs?[.size] as? Int64 ?? 0
                if file.size > 0, fileSize == Int64(file.size) {
                    completedBytes += Int64(file.size)
                    filesCompleted += 1
                    updateProgress()
                    continue
                }
            }

            statusMessage = "Downloading \(destPath.lastPathComponent)"

            let fileURL = try resolveModelURL(forLocalPath: file.path)
            try await downloadFile(to: destPath, url: fileURL)

            completedBytes += Int64(max(file.size, 0))
            currentFileBytes = 0
            filesCompleted += 1
            updateProgress()
        }

        // Verify all required model assets are present
        for modelPath in Self.requiredModelPaths {
            let fullPath = repoPath.appendingPathComponent(modelPath)
            guard FileManager.default.fileExists(atPath: fullPath.path) else {
                throw ModelDownloadError.modelNotFound(modelPath)
            }
        }

        progress = 1.0
        statusMessage = "Download complete!"
        Self.logger.info("ASR model download complete")
    }

    private func createParentDirectories(for files: [(path: String, size: Int)], at repoPath: URL) throws {
        let parentDirs = Set(files.compactMap { file -> String? in
            let components = file.path.components(separatedBy: "/")
            guard components.count > 1 else { return nil }
            return components.dropLast().joined(separator: "/")
        })

        for parentDir in parentDirs.sorted() {
            let parentPath = repoPath.appendingPathComponent(parentDir)
            try FileManager.default.createDirectory(at: parentPath, withIntermediateDirectories: true)
        }
    }

    private func listFilesToDownload() async throws -> [(path: String, size: Int)] {
        var files: [(path: String, size: Int)] = []
        try await listDirectory(path: Self.targetRepo.subPath ?? "", files: &files)
        return files
    }

    private func listDirectory(path: String, files: inout [(path: String, size: Int)]) async throws {
        let apiPath = path.isEmpty ? "tree/main" : "tree/main/\(path)"
        let dirURL = try ModelRegistry.apiModels(Self.targetRepo.remotePath, apiPath)

        var request = URLRequest(url: dirURL)
        request.timeoutInterval = 30

        if let token = ProcessInfo.processInfo.environment["HF_TOKEN"] {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (dirData, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse,
           httpResponse.statusCode == 429 || httpResponse.statusCode == 503 {
            throw ModelDownloadError.rateLimited
        }

        guard let items = try JSONSerialization.jsonObject(with: dirData) as? [[String: Any]] else {
            return
        }

        for item in items {
            guard let itemPath = item["path"] as? String,
                  let itemType = item["type"] as? String else { continue }

            if itemType == "directory" {
                try await listDirectory(path: itemPath, files: &files)
                continue
            }

            guard itemType == "file", let localPath = stripRepoSubPath(from: itemPath) else {
                continue
            }

            let isRequired = Self.requiredModelPaths.contains(where: {
                localPath == $0 || localPath.hasPrefix("\($0)/")
            })
            let isMetadata = localPath.hasSuffix(".json") || localPath.hasSuffix(".txt") || localPath.hasSuffix(".bin")
            guard isRequired || isMetadata else {
                continue
            }

            let fileSize = max(item["size"] as? Int ?? 0, 0)
            files.append((path: localPath, size: fileSize))
        }
    }

    private func stripRepoSubPath(from remotePath: String) -> String? {
        guard let subPath = Self.targetRepo.subPath, !subPath.isEmpty else {
            return remotePath
        }

        let prefix = subPath + "/"
        guard remotePath.hasPrefix(prefix) else {
            return nil
        }

        let localPath = String(remotePath.dropFirst(prefix.count))
        return localPath.isEmpty ? nil : localPath
    }

    private func resolveModelURL(forLocalPath localPath: String) throws -> URL {
        let remotePath: String
        if let subPath = Self.targetRepo.subPath, !subPath.isEmpty {
            remotePath = "\(subPath)/\(localPath)"
        } else {
            remotePath = localPath
        }

        return try ModelRegistry.resolveModel(
            Self.targetRepo.remotePath,
            remotePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? remotePath
        )
    }

    private func downloadFile(to destPath: URL, url: URL) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 1800

        if let token = ProcessInfo.processInfo.environment["HF_TOKEN"] {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let manager = self

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let delegate = DownloadDelegate(
                progressHandler: { bytes in
                    Task { @MainActor in
                        manager.currentFileBytes = bytes
                        manager.updateProgress()
                    }
                },
                completionHandler: { result in
                    Task { @MainActor in
                        manager.cleanup()
                    }

                    switch result {
                    case .success(let data):
                        do {
                            try FileManager.default.createDirectory(
                                at: destPath.deletingLastPathComponent(),
                                withIntermediateDirectories: true
                            )
                            if FileManager.default.fileExists(atPath: destPath.path) {
                                try FileManager.default.removeItem(at: destPath)
                            }
                            try data.write(to: destPath, options: .atomic)
                            continuation.resume()
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            )

            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 1800
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)

            Task { @MainActor in
                manager.currentDelegate = delegate
                manager.downloadSession = session
            }

            session.downloadTask(with: request).resume()
        }
    }

    private func cleanup() {
        currentDelegate = nil
        downloadSession = nil
    }

    private func updateProgress() {
        guard totalBytes > 0 else {
            progress = Double(filesCompleted) / Double(max(totalFiles, 1))
            return
        }
        let totalDownloaded = completedBytes + currentFileBytes
        progress = Double(totalDownloaded) / Double(totalBytes)
    }
}

/// URLSession download delegate for progress tracking
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progressHandler: @Sendable (Int64) -> Void
    private let completionHandler: @Sendable (Result<Data, Error>) -> Void
    private var downloadedData: Data?

    init(
        progressHandler: @escaping @Sendable (Int64) -> Void,
        completionHandler: @escaping @Sendable (Result<Data, Error>) -> Void
    ) {
        self.progressHandler = progressHandler
        self.completionHandler = completionHandler
        super.init()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Read file data immediately before temp file is deleted
        downloadedData = try? Data(contentsOf: location)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progressHandler(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            completionHandler(.failure(error))
        } else if let data = downloadedData {
            completionHandler(.success(data))
        } else {
            completionHandler(.failure(ModelDownloadError.downloadFailed("No data received")))
        }
    }
}

/// Model download errors
enum ModelDownloadError: LocalizedError {
    case modelNotFound(String)
    case downloadFailed(String)
    case rateLimited

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let model):
            return "Required model not found: \(model)"
        case .downloadFailed(let file):
            return "Failed to download: \(file)"
        case .rateLimited:
            return "Download rate limited. Please try again later."
        }
    }
}
