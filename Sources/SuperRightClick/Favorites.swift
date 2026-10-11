import AppKit

/// 用户配置的「常用目录」与「常用 App」：**在主界面配置，在右键菜单里使用**。
///
/// 持久化在 UserDefaults（存路径字符串）。缺文件时**不删配置**：
/// 外接硬盘/网络卷没挂载时只是菜单里不显示（`available*`），配置仍在，插回来就恢复。
enum Favorites {

    /// 配置变化通知：主界面改完后右键菜单立即生效。
    static let didChange = Notification.Name("com.superrightclick.favoritesDidChange")

    private static let directoriesKey = "favoriteDirectoryPaths"
    private static let appsKey = "favoriteAppPaths"

    // MARK: - 读取

    static var directories: [URL] { urls(forKey: directoriesKey) }
    static var apps: [URL] { urls(forKey: appsKey) }

    /// 菜单里真正可用的条目：过滤掉当前不存在的路径（配置本身保留）。
    static var availableDirectories: [URL] {
        directories.filter { url in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }
    }

    static var availableApps: [URL] {
        apps.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - 修改（主界面调用）

    static func addDirectory(_ url: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return }
        insert(url, key: directoriesKey)
    }

    static func addApp(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path), url.pathExtension.lowercased() == "app" else { return }
        insert(url, key: appsKey)
    }

    static func removeDirectory(at index: Int) { remove(at: index, key: directoriesKey) }
    static func removeApp(at index: Int) { remove(at: index, key: appsKey) }

    /// 与相邻位置交换（主界面上的 ↑ / ↓）。
    static func moveDirectory(from index: Int, by offset: Int) { move(from: index, by: offset, key: directoriesKey) }
    static func moveApp(from index: Int, by offset: Int) { move(from: index, by: offset, key: appsKey) }

    // MARK: - 实现

    private static func urls(forKey key: String) -> [URL] {
        let paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        return paths.map { URL(fileURLWithPath: $0) }
    }

    private static func store(_ urls: [URL], key: String) {
        UserDefaults.standard.set(urls.map(\.path), forKey: key)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    private static func insert(_ url: URL, key: String) {
        var current = urls(forKey: key)
        let path = url.standardizedFileURL.path
        guard !current.contains(where: { $0.standardizedFileURL.path == path }) else { return }   // 去重
        current.append(URL(fileURLWithPath: path))
        store(current, key: key)
    }

    private static func remove(at index: Int, key: String) {
        var current = urls(forKey: key)
        guard current.indices.contains(index) else { return }
        current.remove(at: index)
        store(current, key: key)
    }

    private static func move(from index: Int, by offset: Int, key: String) {
        var current = urls(forKey: key)
        let target = index + offset
        guard current.indices.contains(index), current.indices.contains(target) else { return }
        current.swapAt(index, target)
        store(current, key: key)
    }
}
