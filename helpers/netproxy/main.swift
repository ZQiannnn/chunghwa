import Foundation

// chunghwa-netproxy — minimal setuid-root helper that toggles macOS
// system proxy on every active network service via `networksetup`.
// Installed at /Library/PrivilegedHelperTools/org.clash.ChungHwa.netproxy
// alongside the privileged mihomo binary, granted the same way (one
// osascript-with-admin prompt copies + chowns + chmod u+s both files).
//
// Argv shape:
//   chunghwa-netproxy enable  <host> <port> [bypass1 bypass2 …]
//   chunghwa-netproxy disable
//
// stdout: one log line per touched service. stderr: errors.
// Exit 0 on success, non-zero on any service failing.

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: chunghwa-netproxy enable <host> <port> [bypass…] | disable\n".utf8))
    exit(2)
}

@discardableResult
func run(_ argv: [String]) -> Int32 {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
    proc.arguments = argv
    let err = Pipe()
    proc.standardError = err
    proc.standardOutput = Pipe()
    do {
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let data = err.fileHandleForReading.readDataToEndOfFile()
            FileHandle.standardError.write(Data("networksetup \(argv.joined(separator: " ")) -> \(proc.terminationStatus): ".utf8))
            FileHandle.standardError.write(data)
            FileHandle.standardError.write(Data("\n".utf8))
        }
        return proc.terminationStatus
    } catch {
        FileHandle.standardError.write(Data("spawn networksetup failed: \(error)\n".utf8))
        return -1
    }
}

func listServices() -> [String] {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
    proc.arguments = ["-listallnetworkservices"]
    let out = Pipe()
    proc.standardOutput = out
    proc.standardError = Pipe()
    do {
        try proc.run()
        proc.waitUntilExit()
    } catch {
        return []
    }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    guard let text = String(data: data, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").compactMap { line -> String? in
        let s = String(line).trimmingCharacters(in: .whitespaces)
        // First line is a banner: "An asterisk (*) denotes that…".
        // Disabled services are prefixed with `*` and skipped.
        if s.isEmpty || s.hasPrefix("An asterisk") || s.hasPrefix("*") { return nil }
        return s
    }
}

let mode = args[1]
let services = listServices()
guard !services.isEmpty else {
    FileHandle.standardError.write(Data("no enabled network services found\n".utf8))
    exit(3)
}

// We treat per-service failures as best-effort: some services
// (Thunderbolt Bridge, FireWire, certain VPN clients) accept HTTP/HTTPS
// but reject `-setsocksfirewallproxy` with errno 14, and a single such
// non-zero return shouldn't take the whole toggle down — the UI would
// latch `enabled = false` and the user could never turn the proxy back
// on. Track touched/failed counts and only fail the whole command when
// not a single service accepted any change.
var touched = 0
var subCallFailures = 0

@discardableResult
func tryRun(_ argv: [String]) -> Bool {
    if run(argv) == 0 { return true }
    subCallFailures += 1
    return false
}

switch mode {
case "enable":
    guard args.count >= 4 else {
        FileHandle.standardError.write(Data("enable needs <host> <port>\n".utf8))
        exit(2)
    }
    let host = args[2]
    let port = args[3]
    let bypass = Array(args.dropFirst(4))
    for svc in services {
        var anyOk = false
        if tryRun(["-setwebproxy", svc, host, port]) { anyOk = true }
        if tryRun(["-setsecurewebproxy", svc, host, port]) { anyOk = true }
        // SOCKS is the flaky one — keep trying it but don't count it
        // against this service's "took at least one setting" check.
        _ = tryRun(["-setsocksfirewallproxy", svc, host, port])
        if !bypass.isEmpty {
            tryRun(["-setproxybypassdomains", svc] + bypass)
        }
        if tryRun(["-setwebproxystate", svc, "on"]) { anyOk = true }
        if tryRun(["-setsecurewebproxystate", svc, "on"]) { anyOk = true }
        _ = tryRun(["-setsocksfirewallproxystate", svc, "on"])
        if anyOk {
            touched += 1
            print("enabled on \(svc)")
        }
    }

case "disable":
    for svc in services {
        var anyOk = false
        if tryRun(["-setwebproxystate", svc, "off"]) { anyOk = true }
        if tryRun(["-setsecurewebproxystate", svc, "off"]) { anyOk = true }
        _ = tryRun(["-setsocksfirewallproxystate", svc, "off"])
        if anyOk {
            touched += 1
            print("disabled on \(svc)")
        }
    }

default:
    FileHandle.standardError.write(Data("unknown mode: \(mode)\n".utf8))
    exit(2)
}

if touched == 0 {
    FileHandle.standardError.write(Data("no service accepted any change (\(subCallFailures) sub-call failures)\n".utf8))
    exit(4)
}
// Some sub-calls may have failed, but at least one service took the
// change — that's success from the UI's perspective.
exit(0)
