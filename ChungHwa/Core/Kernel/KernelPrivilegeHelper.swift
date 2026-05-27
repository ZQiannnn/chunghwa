import Foundation
import OSLog

/// Manages the setuid-root mihomo binary that lives at a stable, app-independent
/// location: `/Library/PrivilegedHelperTools/org.clash.ChungHwa.mihomo`.
///
/// Why a dedicated location instead of stamping setuid onto the bundled /
/// managed / custom binary directly:
///   - touching the binary inside the .app bundle invalidates the ad-hoc
///     signature and gets reset on every brew upgrade or Xcode rebuild.
///   - setuid state was previously per-source; switching custom/managed/bundled
///     would silently un-root TUN.
/// `/Library/PrivilegedHelperTools/` is the Apple-blessed home for privileged
/// helpers, so the file survives app reinstalls, brew upgrades, Xcode rebuilds,
/// and is orthogonal to which source the resolver picked.
///
/// We delegate the actual privilege escalation to
/// `osascript … with administrator privileges`, which surfaces the system auth
/// prompt — no separate XPC helper to install or maintain.
///
/// NOT `@MainActor`: `Process.waitUntilExit()` is a synchronous blocking call.
/// Pinning this struct to MainActor would freeze the entire UI for the duration
/// of the auth prompt and leave it stuck if the user cancels (this was the
/// "can't retry after cancel" bug).
struct KernelPrivilegeHelper {
    static let log = Logger(subsystem: "org.clash.ChungHwa", category: "privilege")

    /// Stable, root-owned path the setuid kernel lives at after the user
    /// authorizes. Survives app reinstalls, brew upgrades, Xcode rebuilds.
    static let privilegedBinaryPath = "/Library/PrivilegedHelperTools/org.clash.ChungHwa.mihomo"

    /// Companion setuid helper for system-proxy toggling. Same install
    /// flow / same osascript prompt as mihomo — granting once installs
    /// both so the user never has to type their password to flip the
    /// system-proxy switch again either.
    static let netproxyHelperPath = "/Library/PrivilegedHelperTools/org.clash.ChungHwa.netproxy"

    /// True iff the file at `privilegedBinaryPath` exists, is owned by root,
    /// and has the setuid bit set. Synchronous; cheap stat call.
    static func isPrivileged() -> Bool {
        return isSetuidRoot(privilegedBinaryPath)
    }

    static func isNetproxyHelperPrivileged() -> Bool {
        return isSetuidRoot(netproxyHelperPath)
    }

    private static func isSetuidRoot(_ path: String) -> Bool {
        var st = stat()
        guard stat(path, &st) == 0 else { return false }
        let isRoot = st.st_uid == 0
        let isSetuid = (st.st_mode & UInt16(S_ISUID)) != 0
        return isRoot && isSetuid
    }

    /// Path the netproxy helper ships at inside the running .app bundle.
    /// Nil when the bundle doesn't include it (older builds).
    static func bundledNetproxySource() -> String? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let url = resourceURL.appendingPathComponent("chunghwa-netproxy")
        return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
    }

    /// One-shot privilege grant. Reads `sourcePath`, copies it to
    /// `privilegedBinaryPath`, chowns it to root:wheel, chmod u+s. If
    /// `netproxySource` is non-nil, the same osascript also installs the
    /// netproxy helper to `netproxyHelperPath` — one password prompt,
    /// both binaries get the setuid bit. Throws on user-cancel or any
    /// shell failure (with a Chinese-friendly `localizedDescription`).
    static func grantPrivileges(sourcePath: String, netproxySource: String? = nil) async throws {
        let mihomoSrc = sourcePath.replacingOccurrences(of: "\"", with: "\\\"")
        let mihomoDst = privilegedBinaryPath.replacingOccurrences(of: "\"", with: "\\\"")
        var steps = [
            "mkdir -p /Library/PrivilegedHelperTools",
            "cp \\\"\(mihomoSrc)\\\" \\\"\(mihomoDst)\\\"",
            "chown root:wheel \\\"\(mihomoDst)\\\"",
            "chmod u+s \\\"\(mihomoDst)\\\"",
        ]
        if let netproxySource {
            let npSrc = netproxySource.replacingOccurrences(of: "\"", with: "\\\"")
            let npDst = netproxyHelperPath.replacingOccurrences(of: "\"", with: "\\\"")
            steps.append("cp \\\"\(npSrc)\\\" \\\"\(npDst)\\\"")
            steps.append("chown root:wheel \\\"\(npDst)\\\"")
            steps.append("chmod u+s \\\"\(npDst)\\\"")
        }
        // One osascript invocation = one auth prompt, regardless of how
        // many shell commands we chain inside.
        let shell = steps.joined(separator: " && ")
        let script = "do shell script \"\(shell)\" with administrator privileges"
        try await runOsascript(script: script, failurePrefix: "授权失败")
        // Verify the binaries actually landed setuid-root. osascript can
        // report success but leave the destination missing (SIP/MDM
        // policy, sandbox redirect, transparent overlay); we'd rather
        // throw than silently re-prompt next toggle.
        guard isPrivileged() else {
            throw NSError(
                domain: "ChungHwa.Privilege",
                code: -10,
                userInfo: [NSLocalizedDescriptionKey:
                    "授权未生效：\(privilegedBinaryPath) 不存在或缺少 setuid root 位。请检查 MDM / 系统完整性策略是否阻止了对该路径的写入。"]
            )
        }
        if netproxySource != nil, !isNetproxyHelperPrivileged() {
            throw NSError(
                domain: "ChungHwa.Privilege",
                code: -12,
                userInfo: [NSLocalizedDescriptionKey:
                    "授权未生效：\(netproxyHelperPath) 未变成 setuid root。"]
            )
        }
    }

    /// Convenience used by the toolbar / menubar TUN buttons: if the
    /// privileged binary isn't in place yet, run the osascript grant flow
    /// against whichever non-privileged source (custom / managed / bundled)
    /// the resolver would otherwise pick. On success, refresh the resolver
    /// so subsequent kernel restarts spawn the setuid-root copy. No-op when
    /// already privileged — that's what makes the auth prompt one-time.
    ///
    /// The same prompt also stamps the netproxy helper (if the bundle
    /// ships it and it isn't already privileged), so toggling system
    /// proxy never needs a second password prompt either.
    @MainActor
    static func ensurePrivileged(resolver: KernelBinaryResolver) async throws {
        let mihomoNeeded = !isPrivileged()
        let netproxyBundled = bundledNetproxySource()
        let netproxyNeeded = netproxyBundled != nil && !isNetproxyHelperPrivileged()
        guard mihomoNeeded || netproxyNeeded else { return }

        guard let source = resolver.nonPrivilegedCurrent else {
            throw NSError(
                domain: "ChungHwa.Privilege",
                code: -11,
                userInfo: [NSLocalizedDescriptionKey: "找不到可用的 mihomo 二进制（custom / managed / bundled 三档全空）"]
            )
        }
        // If only the netproxy half is missing (mihomo already privileged)
        // we still ship the existing mihomo source through the osascript —
        // overwriting the privileged copy with the same content is cheap
        // and avoids a separate code path that installs only one binary.
        try await grantPrivileges(
            sourcePath: source.url.path,
            netproxySource: netproxyNeeded ? netproxyBundled : nil
        )
        resolver.refresh()
    }

    /// Removes both privileged files. Same osascript path as grant;
    /// no-op for whichever file is already gone.
    static func revokePrivileges() async throws {
        let dst = privilegedBinaryPath.replacingOccurrences(of: "\"", with: "\\\"")
        let np = netproxyHelperPath.replacingOccurrences(of: "\"", with: "\\\"")
        let shell = "rm -f \\\"\(dst)\\\" \\\"\(np)\\\""
        let script = "do shell script \"\(shell)\" with administrator privileges"
        try await runOsascript(script: script, failurePrefix: "撤销失败")
    }

    /// Runs an admin-authorized shell snippet via osascript. The blocking
    /// `waitUntilExit()` runs on a background thread via `Task.detached` so
    /// the main UI stays responsive while the password prompt is up.
    private static func runOsascript(script: String, failurePrefix: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", script]
            let errPipe = Pipe()
            proc.standardError = errPipe
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus != 0 {
                let data = errPipe.fileHandleForReading.readDataToEndOfFile()
                let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                // osascript user-cancel error is exit code 1 with message
                // "User canceled."; surface a friendlier Chinese message.
                let msg: String
                if raw.contains("User canceled") || raw.contains("用户已取消") || (proc.terminationStatus == 1 && raw.isEmpty) {
                    msg = "已取消授权"
                } else {
                    msg = raw.isEmpty ? failurePrefix : raw
                }
                log.error("privileged op failed: \(msg, privacy: .public)")
                throw NSError(
                    domain: "ChungHwa.Privilege",
                    code: Int(proc.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: msg]
                )
            }
        }.value
    }
}
