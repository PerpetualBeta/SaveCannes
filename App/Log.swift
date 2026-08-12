import Foundation

// Diagnostic logging — off by default, enabled per-machine via:
//
//   defaults write cc.jorviksoftware.SaveCannes debugLogging -bool YES
//   defaults delete cc.jorviksoftware.SaveCannes debugLogging   # turn off
//
// When on, timestamped lines are appended to
//   ~/Library/Logs/Save Cannes/savecannes.log
// (per-user, owner-only directory — not /private/tmp, where a
// predictable filename invites a symlink-target-overwrite by any
// same-user process.) The flag is read once per call so toggling it
// takes effect on the next log line.

private let scLogPath: String = {
    let logs = FileManager.default
        .urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs", isDirectory: true)
        .appendingPathComponent("Save Cannes", isDirectory: true)
    try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    return logs.appendingPathComponent("savecannes.log").path
}()
private let scLogQueue = DispatchQueue(label: "cc.jorviksoftware.SaveCannes.log")
private let scLogFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return f
}()

func scLog(_ msg: String) {
    guard UserDefaults.standard.bool(forKey: "debugLogging") else { return }
    let line = "\(scLogFmt.string(from: Date()))  \(msg)\n"
    scLogQueue.async {
        guard let data = line.data(using: .utf8) else { return }
        // O_NOFOLLOW: refuse to follow a symlink at this path. Combined
        // with the 0700 parent directory created above, this closes the
        // symlink-attack vector entirely.
        let fd = open(scLogPath, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        data.withUnsafeBytes { buf in
            _ = write(fd, buf.baseAddress, buf.count)
        }
    }
}
