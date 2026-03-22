import AppKit
import Foundation

autoreleasepool {
    StderrLogFilter.install(excluding: [
        " [DEBUG] [FluidAudio.MLArrayCache] "
    ])

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
