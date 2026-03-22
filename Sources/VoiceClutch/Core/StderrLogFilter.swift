import Foundation

final class StderrLogFilter: @unchecked Sendable {
    @MainActor private static var shared: StderrLogFilter?

    private let pipe = Pipe()
    private let originalStderr: FileHandle
    private let excludedPatterns: [String]
    private let lock = NSLock()
    private var pendingData = Data()

    private init(excludedPatterns: [String]) {
        self.excludedPatterns = excludedPatterns
        self.originalStderr = FileHandle(fileDescriptor: dup(STDERR_FILENO), closeOnDealloc: true)
    }

    @MainActor
    static func install(excluding excludedPatterns: [String]) {
        guard shared == nil else { return }

        let filter = StderrLogFilter(excludedPatterns: excludedPatterns)
        filter.start()
        shared = filter
    }

    private func start() {
        let readHandle = pipe.fileHandleForReading
        let writeDescriptor = pipe.fileHandleForWriting.fileDescriptor

        guard dup2(writeDescriptor, STDERR_FILENO) != -1 else { return }

        readHandle.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData)
        }
    }

    private func consume(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }

        if chunk.isEmpty {
            flushPendingData()
            pipe.fileHandleForReading.readabilityHandler = nil
            return
        }

        pendingData.append(chunk)

        while let newlineIndex = pendingData.firstIndex(of: 0x0A) {
            let lineData = pendingData.prefix(through: newlineIndex)
            pendingData.removeSubrange(...newlineIndex)
            forwardIfNeeded(Data(lineData))
        }
    }

    private func flushPendingData() {
        guard !pendingData.isEmpty else { return }
        forwardIfNeeded(pendingData)
        pendingData.removeAll(keepingCapacity: false)
    }

    private func forwardIfNeeded(_ lineData: Data) {
        guard let line = String(data: lineData, encoding: .utf8) else {
            try? originalStderr.write(contentsOf: lineData)
            return
        }

        guard excludedPatterns.allSatisfy({ !line.contains($0) }) else { return }
        try? originalStderr.write(contentsOf: lineData)
    }
}
