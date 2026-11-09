// 经用户授权后，检查指定主机的本机 favicon 命中情况。不联网，不输出标题、完整网址或浏览记录。
// 用法：FaviconProbe <输出目录> <主机1> [主机2...]
import AppKit

@main enum FaviconProbe {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else { fatalError("需要输出目录和主机名") }
        let out = URL(fileURLWithPath: args[1])
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let store = FaviconStore()
        let bundle = "com.google.Chrome"
        var lines: [String] = []
        for (index, host) in args.dropFirst(2).enumerated() {
            let page = "https://" + host + "/"
            var stats = FaviconStore.Statistics()
            let result = store.load(urls: [page], bundleID: bundle) { stats = $0 }
            let key = FaviconStore.cacheKey(url: page, bundleID: bundle)!
            let image = result[key]
            let line = "site-\(index + 1) icon=\(image != nil) \(stats.text)"
            print(line); lines.append(line)
            if let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
               let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                try png.write(to: out.appendingPathComponent("site-\(index + 1).png"))
            }
        }
        try lines.joined(separator: "\n").write(to: out.appendingPathComponent("图标命中统计.txt"), atomically: true, encoding: .utf8)
    }
}
