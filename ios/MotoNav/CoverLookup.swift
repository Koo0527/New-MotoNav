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
    private var generation: UInt32?

    private init() {}

    // MARK: - 入口

    func update(_ metadata: AMSMetadata, force: Bool = false) {
        guard Settings.shared.musicHID, Settings.shared.musicCover, BleLink.shared.isReady else { stop(); return }
        if generation != metadata.generation { reset(); generation = metadata.generation }
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
            reset()
            key = incoming.key
            BleLink.shared.mediaCoverStatus = "正在匹配专辑封面…"
            let current = token
            let item = DispatchWorkItem { [weak self] in
                guard let self = self, self.token == current else { return }
                self.fetch(incoming, token: current)
            }
            work = item
            // AMS 的歌名、歌手是分片到达的，稍等一下再搜，避免用半截歌名去查
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: item)
        } else if force, pushedKey.isEmpty, let cached = cache[key] {
            push(cached.encoded, key: key)         // 重连后补发同一首的封面，不用再联网
            BleLink.shared.mediaCoverStatus = "封面已缓存 · \(cached.source)"
        }
    }

    func stop() {
        if !key.isEmpty || !pushedKey.isEmpty || task != nil || work != nil { reset() }
        generation = nil
        if !BleLink.shared.mediaCoverStatus.isEmpty { BleLink.shared.mediaCoverStatus = "" }
    }

    // MARK: - 状态

    private func reset() {
        cancel()
        clearScreen()
    }

    private func cancel() {
        token = UUID(); task?.cancel(); task = nil; work?.cancel(); work = nil; key = ""
    }

    /// 圆屏上已经推过封面才需要清，清掉后固件会画回黑胶唱片
    private func clearScreen() {
        guard !pushedKey.isEmpty else { return }
        pushedKey = ""
        guard BleLink.shared.isReady else { return }
        BleLink.shared.sendOnce("#ZCOV,0")
    }

    private func push(_ encoded: CoverEncoder.Encoded, key: String) {
        guard BleLink.shared.isReady, pushedKey != key else { return }
        pushedKey = key
        BleLink.shared.sendBulk(type: CoverEncoder.typeCover, id: 0, data: encoded.data)
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
        lookup(track, token: token, source: .qq)
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
        request.timeoutInterval = 10
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
