import Foundation
import UIKit

/// HID 模式（网易云 / QQ 音乐）拿不到系统封面：iOS 不开放其它 App 的 artwork。
/// 这里用 AMS 送到手机的歌名 + 歌手去公开曲库搜同名专辑图，命中后编码成 type 6 封面包推给圆屏。
/// 开关关闭、没有完整歌曲信息时不发任何请求；所有状态都在主线程使用。
final class CoverLookup {
    static let shared = CoverLookup()

    private struct Track {
        let title: String
        let artist: String
        let album: String
        let seconds: Double?
        var key: String { "\(title)\n\(artist)\n\(album)" }
    }

    private struct Hit {
        let title: String
        let artist: String
        let album: String
        let seconds: Double?
        let art: URL
        let referer: String
        let source: String
    }

    private struct Cached { let encoded: CoverEncoder.Encoded; let source: String }
    private struct Miss { let status: String; let expires: TimeInterval }

    /// 依次尝试的曲库。QQ 音乐匿名搜索最好用（中文、英文都命中），网易云补网易独家，
    /// iTunes 兜底。注意：网易云匿名搜索只返回翻唱，所以放在 QQ 后面。
    private enum Source: Int, CaseIterable {
        case qq, netease, itunes
        var name: String {
            switch self {
            case .qq: return "QQ 音乐"
            case .netease: return "网易云"
            case .itunes: return "iTunes"
            }
        }
        var referer: String {
            switch self {
            case .qq: return "https://y.qq.com/"
            case .netease: return "https://music.163.com/"
            case .itunes: return ""
            }
        }
        var next: Source? { Source(rawValue: rawValue + 1) }
    }

    private static let browserUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    private static let appUA = "MotoNav/0.15.0 (iOS; album cover lookup)"

    private var cache: [String: Cached] = [:]
    private var misses: [String: Miss] = [:]
    private var key = "", token = UUID(), pushedKey = ""
    private var task: URLSessionDataTask?, work: DispatchWorkItem?
    /// 固件按 (id,total,parts) 判重；App 重启后编号若从固定值重来，同尺寸封面会被当成重发丢弃，
    /// 所以每个进程用随机起点。
    private var coverBulkId = Int.random(in: 0...255)

    private init() {}

    // MARK: - 入口

    func update(_ metadata: AMSMetadata, force: Bool = false) {
        guard Settings.shared.musicHID, Settings.shared.musicCover, BleLink.shared.isReady else { stop(); return }
        guard metadata.ready, !metadata.title.isEmpty, !metadata.artist.isEmpty,
              !metadata.values[0].partial, !metadata.values[1].partial else {
            cancel()                       // 还没收齐就先不发请求，圆屏保留上一首封面
            let status = metadata.ready ? "等待完整歌曲信息" : ""
            if BleLink.shared.mediaCoverStatus != status { BleLink.shared.mediaCoverStatus = status }
            return
        }
        let seconds = Double(metadata.values[3].text)
        let incoming = Track(title: metadata.title, artist: metadata.artist, album: metadata.album,
                             seconds: seconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil })
        if incoming.key != key {
            // 只有 key（歌名+歌手+专辑）变了才 reset：AMS metadata.generation 是分片字段补全时
            // 就 ++ 的内部版本号，不代表歌曲切换，不能用它触发 reset，否则会在分片到达时反复
            // clearScreen → 清固件上刚推上去的封面（网易云"推送后消失"的根因）。
            reset()
            key = incoming.key
            BleLink.shared.mediaCoverStatus = "正在匹配专辑封面…"
            let current = token
            if let cached = cache[incoming.key] {
                // 缓存命中直接推，不走 asyncAfter——这是切歌无延迟的主路径
                push(cached.encoded, key: incoming.key)
                BleLink.shared.mediaCoverStatus = "封面已缓存 · \(cached.source)"
                return
            }
            let item = DispatchWorkItem { [weak self] in
                guard let self = self, self.token == current else { return }
                self.fetch(incoming, token: current)
            }
            work = item
            // 已有 partial 字段守卫，这里留 0.1s 兜底；命中 cache 已经提前返回不走这里
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: item)
        } else if force, pushedKey.isEmpty, let cached = cache[key] {
            push(cached.encoded, key: key)         // 重连后补发同一首的封面，不用再联网
            BleLink.shared.mediaCoverStatus = "封面已缓存 · \(cached.source)"
        }
    }

    func stop() {
        if !key.isEmpty || !pushedKey.isEmpty || task != nil || work != nil { reset() }
        if !BleLink.shared.mediaCoverStatus.isEmpty { BleLink.shared.mediaCoverStatus = "" }
    }

    // MARK: - 状态

    /// 切歌 / 停止：取消未完成的联网请求，**不主动清固件上的封面**（固件收到新的
    /// type 6 bulk 会自动覆盖；旧图可以留着直到新图到达，用户体验更好）。
    private func reset() {
        cancel()
        pushedKey = ""
    }

    private func cancel() {
        token = UUID(); task?.cancel(); task = nil; work?.cancel(); work = nil; key = ""
    }

    /// 停止 / App 退出 / 明确不再推送封面时，发 #ZCOV,0 让固件恢复黑胶唱片。
    /// 注意：reset（切歌时）**不**调这里——让固件覆盖替换。
    func clearScreen() {
        guard !pushedKey.isEmpty, BleLink.shared.isReady else { return }
        pushedKey = ""
        BleLink.shared.sendOnce("#ZCOV,0")
    }

    private func push(_ encoded: CoverEncoder.Encoded, key: String) {
        guard BleLink.shared.isReady, pushedKey != key else { return }
        pushedKey = key
        coverBulkId = (coverBulkId + 1) & 0xFF
        BleLink.shared.sendBulk(type: CoverEncoder.typeCover, id: coverBulkId, data: encoded.data, prioritize: true)
    }

    // MARK: - 匹配

    private func fetch(_ track: Track, token: UUID) {
        if let cached = cache[track.key] {
            push(cached.encoded, key: track.key)
            BleLink.shared.mediaCoverStatus = "封面已缓存 · \(cached.source)"
            return
        }
        if let miss = misses[track.key], miss.expires > Date().timeIntervalSince1970 {
            BleLink.shared.mediaCoverStatus = miss.status
            return
        }
        lookupParallel(track, token: token)
    }

    private func lookup(_ track: Track, token: UUID, source: Source?) {
        guard let source = source else {
            misses[track.key] = Miss(status: "没有找到匹配的专辑封面", expires: Date().timeIntervalSince1970 + 900)
            BleLink.shared.mediaCoverStatus = "没有找到匹配的专辑封面"
            return
        }
        search(source, track) { [weak self] hit in
            DispatchQueue.main.async {
                guard let self = self, self.token == token, self.key == track.key else { return }
                if let hit = hit { self.download(hit, track: track, token: token) }
                else { self.lookup(track, token: token, source: source.next) }
            }
        }
    }

    /// 并行搜全部源，谁先返回有效 hit 就立刻用，其它请求丢弃。
    /// 之前串行搜 QQ→网易云→iTunes，如果首个源搜不到且网络慢，用户就得等 timeout（10s）才见封面。
    private func lookupParallel(_ track: Track, token: UUID) {
        let group = DispatchGroup()
        var hit: Hit?
        var remaining = 3
        let lock = NSLock()

        for source in Source.allCases {
            group.enter()
            search(source, track) { result in
                lock.lock()
                if hit == nil, let result = result { hit = result; remaining = 0 }
                else { remaining -= 1 }
                lock.unlock()
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self = self, self.token == token, self.key == track.key else { return }
            if let hit = hit {
                self.download(hit, track: track, token: token)
            } else {
                self.misses[track.key] = Miss(status: "没有找到匹配的专辑封面",
                    expires: Date().timeIntervalSince1970 + 900)
                BleLink.shared.mediaCoverStatus = "没有找到匹配的专辑封面"
            }
        }
    }

    // MARK: - 联网

    private static func request(_ source: Source, _ track: Track) -> URLRequest? {
        let query = (track.title + " " + track.artist).trimmingCharacters(in: .whitespacesAndNewlines)
        var components: URLComponents
        var body: Data?
        switch source {
        case .qq:
            components = URLComponents(string: "https://c.y.qq.com/soso/fcgi-bin/client_search_cp")!
            components.queryItems = [.init(name: "w", value: query), .init(name: "format", value: "json"),
                                     .init(name: "new_json", value: "1"), .init(name: "n", value: "8"),
                                     .init(name: "p", value: "1")]
        case .netease:
            // 匿名可用的只有 cloudsearch，且必须 POST
            components = URLComponents(string: "https://music.163.com/api/cloudsearch/pc")!
            var form = URLComponents()
            form.queryItems = [.init(name: "s", value: query), .init(name: "type", value: "1"),
                               .init(name: "limit", value: "8"), .init(name: "offset", value: "0"),
                               .init(name: "total", value: "true")]
            body = form.percentEncodedQuery?.data(using: .utf8)
        case .itunes:
            // 不带 country：默认美区曲库最全，cn 区几乎搜不到歌
            components = URLComponents(string: "https://itunes.apple.com/search")!
            components.queryItems = [.init(name: "term", value: query), .init(name: "entity", value: "song"),
                                     .init(name: "limit", value: "8")]
        }
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4   // 并行搜时 4s 足够；某个源卡不阻塞其它
        request.setValue(source == .itunes ? appUA : browserUA, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !source.referer.isEmpty { request.setValue(source.referer, forHTTPHeaderField: "Referer") }
        if let body = body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func search(_ source: Source, _ track: Track, done: @escaping (Hit?) -> Void) {
        guard let request = Self.request(source, track) else { done(nil); return }
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard error == nil, (response as? HTTPURLResponse)?.statusCode == 200,
                  let data = data, data.count <= 512 * 1024,
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { done(nil); return }
            done(Self.best(Self.parse(source, json), for: track))
        }.resume()
    }

    private func download(_ hit: Hit, track: Track, token: UUID) {
        var request = URLRequest(url: hit.art)
        request.timeoutInterval = 12
        request.setValue(Self.browserUA, forHTTPHeaderField: "User-Agent")
        if !hit.referer.isEmpty { request.setValue(hit.referer, forHTTPHeaderField: "Referer") }
        task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            var encoded: CoverEncoder.Encoded?
            if error == nil, (response as? HTTPURLResponse)?.statusCode == 200,
               let data = data, data.count <= 4 * 1024 * 1024, let image = UIImage(data: data) {
                encoded = CoverEncoder.encode(image: image)
            }
            let result = encoded
            DispatchQueue.main.async {
                guard let self = self, self.token == token, self.key == track.key else { return }
                self.task = nil
                guard let result = result else {
                    self.misses[track.key] = Miss(status: "封面下载失败", expires: Date().timeIntervalSince1970 + 120)
                    BleLink.shared.mediaCoverStatus = "封面下载失败"
                    return
                }
                if self.cache.count >= 16, let oldest = self.cache.keys.first { self.cache.removeValue(forKey: oldest) }
                self.cache[track.key] = Cached(encoded: result, source: hit.source)
                self.push(result, key: track.key)
                BleLink.shared.mediaCoverStatus = "封面已更新 · \(hit.source)"
            }
        }
        task?.resume()
    }

    // MARK: - 解析

    private static func parse(_ source: Source, _ json: [String: Any]) -> [Hit] {
        switch source {
        case .qq:
            guard let data = json["data"] as? [String: Any], let song = data["song"] as? [String: Any],
                  let list = song["list"] as? [[String: Any]] else { return [] }
            return list.compactMap { item in
                guard let album = item["album"] as? [String: Any], let mid = album["mid"] as? String, !mid.isEmpty,
                      let url = URL(string: "https://y.gtimg.cn/music/photo_new/T002R300x300M000\(mid).jpg") else { return nil }
                let singers = (item["singer"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
                return Hit(title: item["title"] as? String ?? item["name"] as? String ?? "",
                           artist: singers.joined(separator: "/"), album: album["name"] as? String ?? "",
                           seconds: item["interval"] as? Double,
                           art: url, referer: source.referer, source: source.name)
            }
        case .netease:
            guard let result = json["result"] as? [String: Any],
                  let songs = result["songs"] as? [[String: Any]] else { return [] }
            return songs.compactMap { song in
                guard let album = song["al"] as? [String: Any],
                      var pic = album["picUrl"] as? String, !pic.isEmpty else { return nil }
                if pic.hasPrefix("http://") { pic = "https://" + pic.dropFirst(7) }
                pic += pic.contains("?") ? "&param=300y300" : "?param=300y300"
                guard let url = URL(string: pic) else { return nil }
                let artists = (song["ar"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
                return Hit(title: song["name"] as? String ?? "", artist: artists.joined(separator: "/"),
                           album: album["name"] as? String ?? "",
                           seconds: (song["dt"] as? Double).map { $0 / 1000 },
                           art: url, referer: source.referer, source: source.name)
            }
        case .itunes:
            guard let results = json["results"] as? [[String: Any]] else { return [] }
            return results.compactMap { item in
                guard let art = item["artworkUrl100"] as? String, !art.isEmpty,
                      let url = URL(string: art.replacingOccurrences(of: "100x100bb", with: "300x300bb")) else { return nil }
                return Hit(title: item["trackName"] as? String ?? "",
                           artist: item["artistName"] as? String ?? "",
                           album: item["collectionName"] as? String ?? "",
                           seconds: (item["trackTimeMillis"] as? Double).map { $0 / 1000 },
                           art: url, referer: "", source: source.name)
            }
        }
    }

    /// 只接受歌名一致、歌手互相包含的结果；时长接近的优先，其次专辑名一致的
    private static func best(_ hits: [Hit], for track: Track) -> Hit? {
        let matched = hits.filter { same($0.title, track.title) && contains($0.artist, track.artist) }
        guard !matched.isEmpty else { return nil }
        if let seconds = track.seconds,
           let close = matched.first(where: { hit -> Bool in
               guard let value = hit.seconds else { return false }
               return abs(value - seconds) <= 4
           }) { return close }
        if !track.album.isEmpty, let album = matched.first(where: { same($0.album, track.album) }) { return album }
        return matched.first
    }

    /// 去掉 (Live) 这类括号后缀，只留字母数字（含中文），再比较
    private static func norm(_ text: String) -> String {
        var stripped = "", depth = 0
        for ch in text {
            if "（(【[〔".contains(ch) { depth += 1; continue }
            if "）)】]〕".contains(ch) { depth = max(0, depth - 1); continue }
            if depth == 0 { stripped.append(ch) }
        }
        return stripped
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map { String($0) }.joined()
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        let x = norm(a), y = norm(b)
        return !x.isEmpty && x == y
    }

    private static func contains(_ a: String, _ b: String) -> Bool {
        let x = norm(a), y = norm(b)
        return !x.isEmpty && !y.isEmpty && (x.contains(y) || y.contains(x))
    }
}
