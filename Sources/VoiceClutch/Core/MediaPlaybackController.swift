import Dispatch
import Foundation
import Darwin

@MainActor
final class MediaPlaybackController {
    private typealias IsPlayingHandler = @convention(block) (Bool) -> Void
    private typealias GetApplicationIsPlayingFunction = @convention(c) (DispatchQueue, IsPlayingHandler) -> Void
    private typealias SendCommandFunction = @convention(c) (Int32, CFDictionary?) -> Void

    private enum MediaRemoteCommand: Int32 {
        case play = 0
        case pause = 1
        case togglePlayPause = 2
    }

    private enum ResumeAction {
        case playCommand
        case toggleCommand
    }

    private struct Symbols {
        let handle: UnsafeMutableRawPointer
        let getNowPlayingApplicationIsPlaying: GetApplicationIsPlayingFunction
        let getAnyApplicationIsPlaying: GetApplicationIsPlayingFunction?
        let sendCommand: SendCommandFunction
    }

    private final class CompletionGate: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }

            guard !completed else { return false }
            completed = true
            return true
        }
    }

    private lazy var symbols: Symbols? = Self.loadSymbols()
    private let callbackQueue = DispatchQueue(label: "dev.vm.voiceclutch.media-playback")
    private var resumeAction: ResumeAction?

    func pauseIfActive(timeoutMilliseconds: Int = 150) async -> Bool {
        resumeAction = nil

        guard let symbols else {
            return false
        }

        let isPlaying = await queryPlaybackState(
            using: symbols,
            timeoutMilliseconds: timeoutMilliseconds
        )

        guard isPlaying == true else {
            return false
        }

        symbols.sendCommand(MediaRemoteCommand.pause.rawValue, nil)

        let settleTimeout = max(300, timeoutMilliseconds * 2)
        if await waitForPlaybackState(
            false,
            using: symbols,
            timeoutMilliseconds: settleTimeout
        ) {
            resumeAction = .playCommand
            return true
        }

        symbols.sendCommand(MediaRemoteCommand.togglePlayPause.rawValue, nil)

        if await waitForPlaybackState(
            false,
            using: symbols,
            timeoutMilliseconds: settleTimeout
        ) {
            resumeAction = .toggleCommand
            return true
        }

        return false
    }

    func resumeIfNeeded() {
        guard let resumeAction else {
            return
        }

        self.resumeAction = nil

        guard let symbols else {
            return
        }

        switch resumeAction {
        case .playCommand:
            symbols.sendCommand(MediaRemoteCommand.play.rawValue, nil)
        case .toggleCommand:
            symbols.sendCommand(MediaRemoteCommand.togglePlayPause.rawValue, nil)
        }
    }

    private func queryPlaybackState(using symbols: Symbols, timeoutMilliseconds: Int) async -> Bool? {
        let nowPlayingState = await requestPlaybackState(
            using: symbols.getNowPlayingApplicationIsPlaying,
            timeoutMilliseconds: timeoutMilliseconds
        )

        if nowPlayingState == true {
            return true
        }

        if let getAnyApplicationIsPlaying = symbols.getAnyApplicationIsPlaying {
            let anyApplicationState = await requestPlaybackState(
                using: getAnyApplicationIsPlaying,
                timeoutMilliseconds: timeoutMilliseconds
            )

            if anyApplicationState == true {
                return true
            }

            if anyApplicationState == false {
                return false
            }
        }

        if nowPlayingState == false {
            return false
        }

        return nil
    }

    private func requestPlaybackState(
        using function: GetApplicationIsPlayingFunction,
        timeoutMilliseconds: Int
    ) async -> Bool? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool?, Never>) in
            let gate = CompletionGate()
            let callback: IsPlayingHandler = { playing in
                guard gate.claim() else { return }
                continuation.resume(returning: playing)
            }

            function(callbackQueue, callback)

            callbackQueue.asyncAfter(deadline: .now() + .milliseconds(timeoutMilliseconds)) {
                guard gate.claim() else { return }
                continuation.resume(returning: nil)
            }
        }
    }

    private func waitForPlaybackState(
        _ expectedIsPlaying: Bool,
        using symbols: Symbols,
        timeoutMilliseconds: Int
    ) async -> Bool {
        let deadline = DispatchTime.now() + .milliseconds(timeoutMilliseconds)
        let pollIntervalMilliseconds = min(75, max(40, timeoutMilliseconds / 4))

        while true {
            if await queryPlaybackState(
                using: symbols,
                timeoutMilliseconds: pollIntervalMilliseconds
            ) == expectedIsPlaying {
                return true
            }

            if DispatchTime.now() >= deadline {
                return false
            }

            let sleepNanoseconds = UInt64(pollIntervalMilliseconds) * 1_000_000
            try? await Task.sleep(nanoseconds: sleepNanoseconds)
        }
    }

    private static func loadSymbols() -> Symbols? {
        let candidatePaths = [
            "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
            "/System/Library/PrivateFrameworks/MediaRemote.framework/Versions/A/MediaRemote"
        ]

        guard
            let handle = candidatePaths.lazy
                .compactMap({ dlopen($0, RTLD_LAZY | RTLD_LOCAL) })
                .first
        else {
            return nil
        }

        guard
            let getNowPlayingApplicationIsPlayingSymbol = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying"),
            let sendCommandSymbol = dlsym(handle, "MRMediaRemoteSendCommand")
        else {
            dlclose(handle)
            return nil
        }

        let getNowPlayingApplicationIsPlaying = unsafeBitCast(
            getNowPlayingApplicationIsPlayingSymbol,
            to: GetApplicationIsPlayingFunction.self
        )
        let getAnyApplicationIsPlaying = dlsym(handle, "MRMediaRemoteGetAnyApplicationIsPlaying")
            .map { unsafeBitCast($0, to: GetApplicationIsPlayingFunction.self) }
        let sendCommand = unsafeBitCast(sendCommandSymbol, to: SendCommandFunction.self)

        return Symbols(
            handle: handle,
            getNowPlayingApplicationIsPlaying: getNowPlayingApplicationIsPlaying,
            getAnyApplicationIsPlaying: getAnyApplicationIsPlaying,
            sendCommand: sendCommand
        )
    }
}
