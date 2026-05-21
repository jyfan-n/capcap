import Darwin
import Foundation

/// Small, synchronous diagnostic log for failures that do not produce macOS
/// crash reports, such as UI hangs followed by Force Quit.
enum DiagnosticLog {
    struct Entry {
        let url: URL
        let date: Date
    }

    private static let directoryName = "capcap"
    private static let fileName = "error.log"
    private static let maxLogBytes = 1_000_000
    private static let trimToBytes = 700_000
    private static let lock = NSLock()

    static var logURL: URL? {
        guard let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            return nil
        }
        return logs
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    static func latestFile() -> Entry? {
        guard let url = logURL else { return nil }
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        guard (values?.fileSize ?? 0) > 0 else { return nil }
        return Entry(url: url, date: values?.contentModificationDate ?? .distantPast)
    }

    static func deleteFile() {
        guard let url = logURL else { return }
        lock.lock()
        defer { lock.unlock() }

        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: url)
        }
        let directory = url.deletingLastPathComponent()
        if let remaining = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil),
           remaining.isEmpty {
            try? fm.removeItem(at: directory)
        }
    }

    static func log(
        _ category: String,
        _ event: String,
        metadata: [String: Any] = [:],
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        guard let data = makeLine(
            category: category,
            event: event,
            metadata: metadata,
            file: String(describing: file),
            line: line
        ).data(using: .utf8) else {
            return
        }

        lock.lock()
        defer { lock.unlock() }
        append(data)
    }

    static func systemSnapshot() -> [String: Any] {
        let info = ProcessInfo.processInfo
        var snapshot: [String: Any] = [
            "os": info.operatingSystemVersionString,
            "process": info.processName,
            "pid": info.processIdentifier,
            "processorCount": info.processorCount,
            "activeProcessorCount": info.activeProcessorCount,
            "memoryGB": String(format: "%.1f", Double(info.physicalMemory) / 1_073_741_824.0),
        ]
        if let model = sysctlString("hw.model") {
            snapshot["model"] = model
        }
        if let machine = sysctlString("hw.machine") {
            snapshot["machine"] = machine
        }
        return snapshot
    }

    private static func makeLine(
        category: String,
        event: String,
        metadata: [String: Any],
        file: String,
        line: UInt
    ) -> String {
        let timestamp = ISO8601DateFormatter.diagnostic.string(from: Date())
        let thread = Thread.isMainThread ? "main" : "background"
        var parts = [
            "\(timestamp)",
            "pid=\(ProcessInfo.processInfo.processIdentifier)",
            "thread=\(thread)",
            "category=\(sanitize(category))",
            "event=\(sanitize(event))",
        ]
        if !metadata.isEmpty {
            let fields = metadata.keys.sorted().map { key in
                "\(sanitize(key))=\(sanitize(String(describing: metadata[key] ?? "")))"
            }
            parts.append(contentsOf: fields)
        }
        parts.append("source=\(sanitize(file)):\(line)")
        return parts.joined(separator: " ") + "\n"
    }

    private static func append(_ data: Data) {
        guard let url = logURL else { return }
        let directory = url.deletingLastPathComponent()
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: url.path) {
                _ = fm.createFile(atPath: url.path, contents: nil)
            }
            trimIfNeeded(at: url)
            let handle = try FileHandle(forWritingTo: url)
            handle.seekToEndOfFile()
            handle.write(data)
            handle.synchronizeFile()
            handle.closeFile()
        } catch {
            NSLog("[capcap] DiagnosticLog append failed: \(error.localizedDescription)")
        }
    }

    private static func trimIfNeeded(at url: URL) {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        guard (values?.fileSize ?? 0) > maxLogBytes,
              let existing = try? Data(contentsOf: url),
              existing.count > trimToBytes else {
            return
        }

        var trimmed = Data()
        if let marker = "\n--- earlier diagnostic log lines truncated ---\n".data(using: .utf8) {
            trimmed.append(marker)
        }
        trimmed.append(existing.suffix(trimToBytes))
        try? trimmed.write(to: url, options: .atomic)
    }

    private static func sanitize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        return String(cString: buffer)
    }
}

private extension ISO8601DateFormatter {
    static var diagnostic: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone.current
        return formatter
    }
}
