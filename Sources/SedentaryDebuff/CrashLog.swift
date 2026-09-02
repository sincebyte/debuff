import Foundation
import Darwin

enum CrashLog {
    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs")
            .appendingPathComponent("SedentaryDebuff_crash.log")
    }

    static func install() {
        NSSetUncaughtExceptionHandler(uncaughtExceptionHandler)
        for sig in [SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGTRAP] {
            signal(sig, crashSignalHandler)
        }
    }

    static func write(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: logURL.path) {
            defer { handle.closeFile() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try? data.write(to: logURL)
        }
    }
}

private func uncaughtExceptionHandler(_ exception: NSException) {
    let callStack = exception.callStackSymbols.joined(separator: "\n")
    let body = "UNCAUGHT OBJC EXCEPTION: \(exception.name.rawValue): \(exception.reason ?? "")\n\(callStack)\n"
    CrashLog.write("[\(Date())]\n\(body)\n")
}

private func crashSignalHandler(_ signalNumber: Int32) {
    let path = CrashLog.logURL.path
    let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    guard fd >= 0 else {
        signal(signalNumber, SIG_DFL)
        raise(signalNumber)
        return
    }
    let message = "[\(time(nil))] CRASH signal=\(signalNumber)\n"
    _ = message.withCString { ptr in
        write(fd, ptr, strlen(ptr))
    }
    var callStack = [UnsafeMutableRawPointer?](repeating: nil, count: 128)
    let count = backtrace(&callStack, 128)
    backtrace_symbols_fd(&callStack, count, fd)
    close(fd)
    signal(signalNumber, SIG_DFL)
    raise(signalNumber)
}
