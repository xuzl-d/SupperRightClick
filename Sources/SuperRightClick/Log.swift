import Foundation

/// 简易文件日志（写入 /tmp/superrightclick.log），便于排查运行期问题。
enum SLog {
    private static let url = URL(fileURLWithPath: "/tmp/superrightclick.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func log(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        NSLog("[SuperRightClick] %@", message)
        if let data = line.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
