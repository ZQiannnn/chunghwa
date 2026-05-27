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

var failures = 0

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
        if run(["-setwebproxy", svc, host, port]) != 0 { failures += 1 }
        if run(["-setsecurewebproxy", svc, host, port]) != 0 { failures += 1 }
        if run(["-setsocksfirewallproxy", svc, host, port]) != 0 { failures += 1 }
        if !bypass.isEmpty {
            if run(["-setproxybypassdomains", svc] + bypass) != 0 { failures += 1 }
        }
        if run(["-setwebproxystate", svc, "on"]) != 0 { failures += 1 }
        if run(["-setsecurewebproxystate", svc, "on"]) != 0 { failures += 1 }
        if run(["-setsocksfirewallproxystate", svc, "on"]) != 0 { failures += 1 }
        print("enabled on \(svc)")
    }

case "disable":
    for svc in services {
        if run(["-setwebproxystate", svc, "off"]) != 0 { failures += 1 }
        if run(["-setsecurewebproxystate", svc, "off"]) != 0 { failures += 1 }
        if run(["-setsocksfirewallproxystate", svc, "off"]) != 0 { failures += 1 }
        print("disabled on \(svc)")
    }

default:
    FileHandle.standardError.write(Data("unknown mode: \(mode)\n".utf8))
    exit(2)
}

exit(failures == 0 ? 0 : 4)
