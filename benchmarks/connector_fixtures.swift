import Foundation

// Deterministic synthetic provider payloads shaped like real Xtream, Stalker
// and ESPN responses (PHP-escaped slashes, numbers-as-strings, nulls, base64
// EPG text, unicode escapes, unused fields the app skips).

struct FixtureRNG {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(max(n, 1))) }
    mutating func chance(_ percent: Int) -> Bool { int(100) < percent }
}

enum ConnectorFixtures {
    static let config = ServerConfig(serverURL: "http://provider.example.com:8080/", username: "user name", password: "p@ss")

    static let words = ["News", "Sport", "Movies", "Kids", "Music", "Drama", "Live", "HD", "FHD", "4K", "Premier", "League",
                        "Cinema", "Action", "Comedy", "Docs", "Nature", "World", "Café", "Über", "Español", "Ελλάδα", "日本", "📺"]

    static func jsonString(_ s: String, phpEscapes: Bool = true) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "/": out += phpEscapes ? "\\/" : "/"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) }
                else if phpEscapes, scalar.value > 0x7F {
                    // PHP json_encode default: \uXXXX (surrogate pairs above BMP).
                    if scalar.value > 0xFFFF {
                        let v = scalar.value - 0x10000
                        out += String(format: "\\u%04x\\u%04x", 0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF))
                    } else {
                        out += String(format: "\\u%04x", scalar.value)
                    }
                } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }

    static func name(_ rng: inout FixtureRNG, _ i: Int) -> String {
        var parts = ["UK:"]
        for _ in 0..<(1 + rng.int(3)) { parts.append(words[rng.int(words.count)]) }
        parts.append("\(i)")
        return parts.joined(separator: " ")
    }

    // MARK: Xtream

    static func liveCategories(count: Int = 200) -> Data {
        var rng = FixtureRNG(1)
        var items: [String] = []
        for i in 1...count {
            let id = rng.chance(5) ? "\(i)" : jsonString("\(i)")
            items.append("{\"category_id\":\(id),\"category_name\":\(jsonString("Category \(words[rng.int(words.count)]) \(i)")),\"parent_id\":0}")
        }
        return Data(("[" + items.joined(separator: ",") + "]").utf8)
    }

    static func liveStreams(count: Int, quirks: Bool = true) -> Data {
        var rng = FixtureRNG(2)
        var out = "["
        out.reserveCapacity(count * 420)
        for i in 0..<count {
            if i > 0 { out += "," }
            let sid = 10_000 + i
            let streamID = quirks && rng.chance(3) ? jsonString("\(sid)") : "\(sid)"
            let category = quirks && rng.chance(3) ? "\(1 + rng.int(220))" : jsonString("\(1 + rng.int(220))")
            let epg: String
            switch quirks ? rng.int(20) : 5 {
            case 0: epg = "null"
            case 1: epg = "\"\""
            case 2: epg = jsonString(" padded.\(i).uk ")
            default: epg = jsonString("channel\(i).uk")
            }
            let archive = rng.chance(30)
            let tvArchive = quirks && rng.chance(10) ? (archive ? "\"1\"" : "\"0\"") : (archive ? "1" : "0")
            let duration = archive ? (quirks && rng.chance(10) ? jsonString("\(rng.int(14))") : "\(rng.int(14))") : "0"
            let icon = quirks && rng.chance(4) ? "\"\"" : jsonString("http://logos.example.com/picons/\(sid % 997)/logo_\(sid).png")
            out += "{\"num\":\(i + 1),\"name\":\(jsonString(name(&rng, i))),\"stream_type\":\"live\",\"stream_id\":\(streamID),"
            out += "\"stream_icon\":\(icon),\"epg_channel_id\":\(epg),\"added\":\"16094\(sid % 100000)\",\"is_adult\":\"0\","
            out += "\"category_id\":\(category),\"category_ids\":[\(1 + rng.int(220))],\"custom_sid\":\"\",\"tv_archive\":\(tvArchive),"
            out += "\"direct_source\":\"\",\"tv_archive_duration\":\(duration)}"
        }
        out += "]"
        return Data(out.utf8)
    }

    static func base64(_ s: String) -> String { Data(s.utf8).base64EncodedString() }

    static func shortEPG(streamID: Int, listings: Int, quirks: Bool = true) -> Data {
        var rng = FixtureRNG(UInt64(1000 + streamID))
        var out = "{\"epg_listings\":["
        var start = 1_700_000_000 + rng.int(3600)
        for j in 0..<listings {
            if j > 0 { out += "," }
            let duration = 900 + rng.int(7200)
            let titleText = "\(words[rng.int(words.count)]) \(words[rng.int(words.count)]) Episode \(j)"
            let title: String
            switch quirks ? rng.int(25) : 5 {
            case 0: title = "null"
            case 1: title = jsonString(titleText) // plain, not base64
            case 2: title = jsonString(" " + base64("  \(titleText)\n") + " ")
            case 3: title = "\"\""
            default: title = jsonString(base64(titleText))
            }
            let description = quirks && rng.chance(10) ? "null" : jsonString(base64("A long description of programme \(j) on channel \(streamID). Featuring \(words[rng.int(words.count)])."))
            let startValue = quirks && rng.chance(4) ? "\(start)" : jsonString("\(start)")
            let stopValue = quirks && rng.chance(4) ? "\(start + duration)" : jsonString("\(start + duration)")
            let id = quirks && rng.chance(5) ? "\(5_000_000 + j)" : jsonString("\(5_000_000 + streamID * 1000 + j)")
            out += "{\"id\":\(id),\"epg_id\":\"\(streamID % 50)\",\"title\":\(title),\"lang\":\"en\",\"start\":\"2023-11-14 22:00:00\",\"end\":\"2023-11-14 23:00:00\","
            out += "\"description\":\(description),\"channel_id\":\"channel\(streamID).uk\",\"start_timestamp\":\(startValue),\"stop_timestamp\":\(stopValue),\"now_playing\":0,\"has_archive\":1}"
            start += duration
        }
        out += "]}"
        return Data(out.utf8)
    }

    static func vodStreams(count: Int, quirks: Bool = true) -> Data {
        var rng = FixtureRNG(3)
        var out = "["
        out.reserveCapacity(count * 500)
        for i in 0..<count {
            if i > 0 { out += "," }
            let sid = 200_000 + i
            let rating = quirks && rng.chance(10) ? "\(rng.int(10))" : (quirks && rng.chance(10) ? "\"\"" : jsonString("\(rng.int(9)).\(rng.int(9))"))
            let ext = ["mkv", "mp4", ".mp4", " avi ", "", "null"][quirks ? rng.int(6) : 0]
            let extJSON = ext == "null" ? "null" : jsonString(ext)
            out += "{\"num\":\(i + 1),\"name\":\(jsonString("Movie \(words[rng.int(words.count)]) \(i) (20\(10 + rng.int(15)))")),\"stream_type\":\"movie\","
            out += "\"stream_id\":\(quirks && rng.chance(3) ? jsonString("\(sid)") : "\(sid)"),\"stream_icon\":\(jsonString("https://image.tmdb.org/t/p/w600_and_h900_bestv2/\(sid)abc.jpg")),"
            out += "\"rating\":\(rating),\"rating_5based\":\(rng.int(5)).\(rng.int(9)),\"added\":\"\(1_600_000_000 + i)\",\"is_adult\":\"0\","
            out += "\"category_id\":\(jsonString("\(1 + rng.int(120))")),\"category_ids\":[\(1 + rng.int(120))],\"container_extension\":\(extJSON),"
            if quirks && rng.chance(30) {
                out += "\"plot\":\(jsonString("Plot \(i)")),\"genre\":\(rng.chance(50) ? jsonString(" ") : jsonString("Drama")),\"year\":\(rng.chance(50) ? "2019" : "\"2019\""),"
                out += "\"release_date\":\(rng.chance(50) ? "null" : "\"2019-01-01\""),\"director\":\"D\",\"cast\":\"A, B\",\"country\":\"US\",\"duration_secs\":\(rng.int(9000)),"
            }
            out += "\"custom_sid\":null,\"direct_source\":\"\"}"
        }
        out += "]"
        return Data(out.utf8)
    }

    static func series(count: Int) -> Data {
        var rng = FixtureRNG(4)
        var items: [String] = []
        items.reserveCapacity(count)
        for i in 0..<count {
            let genre = rng.chance(30) ? "null" : jsonString("Drama, Crime")
            items.append("{\"num\":\(i + 1),\"name\":\(jsonString("Series \(words[rng.int(words.count)]) \(i)")),\"series_id\":\(300_000 + i),\"cover\":\(jsonString("https://image.example.com/s/\(i).jpg")),\"plot\":\(jsonString("A series about \(i)")),\"cast\":\"A, B, C\",\"director\":\"\",\"genre\":\(genre),\"releaseDate\":\"2018-01-01\",\"release_date\":\(rng.chance(50) ? "null" : "\"2018-01-01\""),\"last_modified\":\"1600000000\",\"rating\":\(rng.chance(20) ? "7" : jsonString("\(rng.int(9)).5")),\"rating_5based\":3.8,\"backdrop_path\":[\(jsonString("https://image.example.com/b/\(i).jpg"))],\"youtube_trailer\":\"\",\"episode_run_time\":\"45\",\"category_id\":\(jsonString("\(1 + rng.int(80))")),\"category_ids\":[1]}")
        }
        return Data(("[" + items.joined(separator: ",") + "]").utf8)
    }

    // MARK: Stalker

    static func stalkerGenres(count: Int = 60) -> Data {
        var items = ["{\"id\":\"*\",\"title\":\"All\",\"alias\":\"*\"}"]
        for i in 1...count { items.append("{\"id\":\"\(i)\",\"title\":\(i % 7 == 0 ? "\"N/A\"" : jsonString("Genre \(i)")),\"alias\":\"g\(i)\",\"active_sub\":true,\"censored\":0}") }
        return Data(("{\"js\":[" + items.joined(separator: ",") + "]}").utf8)
    }

    static func stalkerChannels(count: Int) -> Data {
        var rng = FixtureRNG(5)
        var items: [String] = []
        items.reserveCapacity(count)
        for i in 0..<count {
            let cmd = rng.chance(50) ? "ffmpeg http://portal.example.com/play/live.php?mac=00:1A:79:00:00:00&stream=\(i)&extension=ts" : "ffrt http://localhost/ch/\(i)_"
            items.append("{\"id\":\"\(i + 1)\",\"name\":\(jsonString(name(&rng, i))),\"number\":\(rng.chance(50) ? "\"\(i + 1)\"" : "\(i + 1)"),\"censored\":0,\"cmd\":\(jsonString(cmd)),\"cost\":\"0\",\"count\":\"0\",\"status\":1,\"hd\":\"1\",\"tv_genre_id\":\(rng.chance(50) ? "\"\(1 + rng.int(60))\"" : "\(1 + rng.int(60))"),\"base_ch\":\"1\",\"xmltv_id\":\(rng.chance(20) ? "\"\"" : jsonString("stalker\(i).tv")),\"service_id\":\"\",\"bonus_ch\":\"0\",\"volume_correction\":\"0\",\"mc_cmd\":\"\",\"enable_tv_archive\":\(rng.chance(30) ? "1" : "0"),\"wowza_tmp_link\":\"0\",\"wowza_dvr\":\"0\",\"use_http_tmp_link\":\"0\",\"monitoring_status\":\"1\",\"enable_monitoring\":\"0\",\"enable_wowza_load_balancing\":\"0\",\"cmd_1\":\"\",\"cmd_2\":\"\",\"cmd_3\":\"\",\"logo\":\(jsonString("http://portal.example.com/misc/logos/320/\(i).png")),\"correct_time\":\"0\",\"allow_pvr\":\"\",\"allow_local_pvr\":\"\",\"allow_remote_pvr\":0,\"modified\":\"\",\"allow_local_timeshift\":\"1\",\"nginx_secure_link\":\"0\",\"tv_archive_duration\":\(rng.int(10)),\"locked\":0,\"lock\":0,\"fav\":0,\"archive\":1,\"genres_str\":\(rng.chance(30) ? jsonString("Sports") : "\"\""),\"cur_playing\":\"[No channel info]\",\"epg\":[],\"open\":1,\"cmds\":[{\"id\":\"\(i)\",\"ch_id\":\"\(i)\",\"priority\":\"0\",\"url\":\(jsonString(cmd)),\"status\":\"1\"}],\"use_load_balancing\":0,\"pvr\":0}")
        }
        return Data(("{\"js\":{\"total_items\":\(count),\"max_page_items\":\(count),\"selected_item\":0,\"cur_page\":0,\"data\":[" + items.joined(separator: ",") + "]}}").utf8)
    }

    static func stalkerEPG(channels: Int, entries: Int) -> Data {
        var rng = FixtureRNG(6)
        var groups: [String] = []
        for c in 0..<channels {
            var list: [String] = []
            var start = 1_700_000_000 + rng.int(3600)
            for e in 0..<entries {
                let d = 600 + rng.int(5400)
                let chID = rng.chance(10) ? "\"\"" : "\"\(c + 1)\""
                let entryID = rng.chance(5) ? "\"\"" : "\"\(c * 1000 + e)\""
                list.append("{\"id\":\(entryID),\"ch_id\":\(chID),\"correct\":\"2023-11-14 22:00:00\",\"time\":\"2023-11-14 22:00:00\",\"time_to\":\"2023-11-14 23:00:00\",\"duration\":\(d),\"name\":\(rng.chance(3) ? "null" : jsonString("Show \(words[rng.int(words.count)]) \(e)")),\"descr\":\(rng.chance(20) ? "null" : jsonString("Description \(e)")),\"real_id\":\"\(c)_\(start)\",\"category\":\"\",\"director\":\"\",\"actor\":\"\",\"start_timestamp\":\(rng.chance(50) ? "\(start)" : "\"\(start)\""),\"stop_timestamp\":\(rng.chance(50) ? "\(start + d)" : "\"\(start + d)\""),\"t_time\":\"22:00\",\"t_time_to\":\"23:00\",\"mark_memo\":0,\"mark_archive\":0}")
                start += d
            }
            groups.append("\"\(c + 1)\":[" + list.joined(separator: ",") + "]")
        }
        return Data(("{\"js\":{\"data\":{" + groups.joined(separator: ",") + "}}}").utf8)
    }

    static func stalkerMediaPage(count: Int, total: Int, offset: Int = 0) -> Data {
        var rng = FixtureRNG(7 + UInt64(offset))
        var items: [String] = []
        for k in 0..<count {
            let i = offset + k
            let series = rng.chance(30) ? "[1,2,3,4,5,6]" : "[]"
            items.append("{\"id\":\(jsonString(rng.chance(20) ? "\(i):\(1 + rng.int(4))" : "\(i)")),\"owner\":\"\",\"name\":\(jsonString("Media \(words[rng.int(words.count)]) \(i)")),\"old_name\":\"\",\"o_name\":\"\",\"fname\":\"\",\"description\":\(jsonString("About \(i)")),\"pic\":\"\",\"cost\":0,\"time\":\"120\",\"file\":\"\",\"path\":\(jsonString("Media_\(i)")),\"protocol\":\"\",\"rtsp_url\":\"\",\"censored\":0,\"series\":\(series),\"volume_correction\":0,\"category_id\":\(rng.chance(50) ? "\"\(1 + rng.int(60))\"" : "\(1 + rng.int(60))"),\"genre_id\":0,\"genre_id_1\":0,\"year\":\(rng.chance(30) ? "\"N\\/A\"" : "\"2020\""),\"accessed\":1,\"status\":1,\"added\":\"2020-01-01 00:00:00\",\"rating_imdb\":\(rng.chance(30) ? "\"N\\/A\"" : (rng.chance(50) ? "7" : "\"6.5\"")),\"rating_count_imdb\":\"\",\"director\":\"Dir\",\"actors\":\"Act\",\"screenshot_uri\":\(jsonString("http://portal.example.com/screenshots/\(i).jpg")),\"genres_str\":\(rng.chance(50) ? "\"\"" : "\"Drama\""),\"cmd\":\(jsonString("/media/file_\(i).mpg")),\"has_files\":1}")
        }
        return Data(("{\"js\":{\"total_items\":\(total),\"max_page_items\":\(count),\"selected_item\":0,\"cur_page\":1,\"data\":[" + items.joined(separator: ",") + "]}}").utf8)
    }

    // MARK: ESPN

    static func espnTeam(_ rng: inout FixtureRNG, _ id: Int, home: Bool) -> String {
        let city = ["Boston", "Los Angeles", "New York", "Chicago", "Miami", "Denver", "São Paulo", "München"][rng.int(8)]
        let nick = ["Celtics", "Lakers", "Knicks", "Bulls", "Heat", "Nuggets", "Tigers", "Hawks"][rng.int(8)]
        let abbr = String(nick.prefix(3)).uppercased()
        let links = (0..<5).map { _ in "{\"rel\":[\"clubhouse\",\"desktop\",\"team\"],\"href\":\"https://www.espn.com/nba/team/_/name/\(abbr.lowercased())/\(id)\",\"text\":\"Clubhouse\",\"isExternal\":false,\"isPremium\":false}" }.joined(separator: ",")
        let stats = (0..<12).map { "{\"name\":\"stat\($0)\",\"abbreviation\":\"S\($0)\",\"displayValue\":\"\(rng.int(100)).\(rng.int(10))\"}" }.joined(separator: ",")
        let leaders = (0..<3).map { k in "{\"name\":\"points\",\"displayName\":\"Points\",\"shortDisplayName\":\"PTS\",\"abbreviation\":\"PTS\",\"leaders\":[{\"displayValue\":\"\(rng.int(40))\",\"value\":\(rng.int(40)).0,\"athlete\":{\"id\":\"\(id * 10 + k)\",\"fullName\":\"Player \(k)\",\"displayName\":\"Player \(k)\",\"shortName\":\"P. \(k)\",\"links\":[{\"rel\":[\"playercard\"],\"href\":\"https://www.espn.com/nba/player/_/id/\(id)\"}],\"headshot\":\"https://a.espncdn.com/i/headshots/nba/players/full/\(id).png\",\"jersey\":\"\(k)\",\"position\":{\"abbreviation\":\"F\"},\"team\":{\"id\":\"\(id)\"},\"active\":true},\"team\":{\"id\":\"\(id)\"}}]}" }.joined(separator: ",")
        return """
        {"id":"\(id)","uid":"s:40~l:46~t:\(id)","type":"team","order":\(home ? 0 : 1),"homeAway":"\(home ? "home" : "away")","winner":\(rng.chance(50)),"team":{"id":"\(id)","uid":"s:40~l:46~t:\(id)","location":"\(city)","name":"\(nick)","abbreviation":"\(abbr)","displayName":"\(city) \(nick)","shortDisplayName":"\(nick)","color":"007a33","alternateColor":"ffffff","isActive":true,"venue":{"id":"\(id)"},"links":[\(links)],"logo":"https://a.espncdn.com/i/teamlogos/nba/500/scoreboard/\(abbr.lowercased()).png"},"score":"\(80 + rng.int(50))","linescores":[{"value":\(rng.int(40)).0,"displayValue":"\(rng.int(40))","period":1},{"value":\(rng.int(40)).0,"displayValue":"\(rng.int(40))","period":2}],"statistics":[\(stats)],"leaders":[\(leaders)],"records":[{"name":"overall","abbreviation":"Game","type":"total","summary":"\(rng.int(60))-\(rng.int(30))"},{"name":"Home","type":"home","summary":"20-10"},{"name":"Road","type":"road","summary":"15-15"}]}
        """
    }

    static func espnScoreboard(events: Int, seed: UInt64 = 8, baseDate: Date = Date()) -> Data {
        var rng = FixtureRNG(seed)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var list: [String] = []
        for e in 0..<events {
            let date = baseDate.addingTimeInterval(Double(rng.int(6 * 86400)) - 3600)
            var dateString = iso.string(from: date)
            if rng.chance(70) { dateString = String(dateString.dropLast(4)) + "Z" } // ESPN's no-seconds form
            let state = ["pre", "in", "post"][rng.int(3)]
            let detail = state == "pre" ? (rng.chance(10) ? "Postponed" : "Sat, April 15th at 7:30 PM EDT") : (state == "in" ? (rng.chance(20) ? "Halftime" : "Q3 5:42") : "Final")
            let home = espnTeam(&rng, 100 + e * 2, home: true)
            let away = espnTeam(&rng, 101 + e * 2, home: false)
            let geo = rng.chance(70) ? "\"geoBroadcasts\":[{\"type\":{\"id\":\"1\",\"shortName\":\"TV\"},\"market\":{\"id\":\"1\",\"type\":\"National\"},\"media\":{\"shortName\":\"ESPN\"},\"lang\":\"en\",\"region\":\"us\"},{\"type\":{\"id\":\"1\",\"shortName\":\"TV\"},\"market\":{\"id\":\"2\",\"type\":\"Home\"},\"media\":{\"shortName\":\"NBCS-BOS\"},\"lang\":\"en\",\"region\":\"us\"}]," : ""
            list.append("""
            {"id":"40\(1000 + e)","uid":"s:40~l:46~e:40\(1000 + e)","date":"\(dateString)","name":"Event \(e) at Arena","shortName":"AWY @ HOM","season":{"year":2026,"type":2,"slug":"regular-season"},"competitions":[{"id":"40\(1000 + e)","uid":"s:40~l:46~e:40\(1000 + e)~c:40\(1000 + e)","date":"\(dateString)","attendance":19156,"type":{"id":"1","abbreviation":"STD"},"timeValid":true,"neutralSite":false,"conferenceCompetition":false,"playByPlayAvailable":true,"recent":false,"venue":{"id":"1824","fullName":"Arena \(e) Garden","address":{"city":"Boston","state":"MA","country":"USA"},"indoor":true},"competitors":[\(home),\(away)],"notes":[],"status":{"clock":0.0,"displayClock":"0.0","period":4,"type":{"id":"3","name":"STATUS_FINAL","state":"\(state)","completed":\(state == "post"),"description":"Final","detail":"\(detail)","shortDetail":"\(detail)"}},"broadcasts":[{"market":"national","names":["ESPN","ABC"]}],"format":{"regulation":{"periods":4}},"tickets":[{"summary":"Tickets as low as $45","numberAvailable":1200,"links":[{"href":"https://www.vividseats.com/x"}]}],"startDate":"\(dateString)","broadcast":"ESPN",\(geo)"headlines":[{"type":"Recap","description":"A recap \\u2014 with \\"quotes\\" and unicode \\u00e9","shortLinkText":"Recap"}],"highlights":[]}],"links":[{"language":"en-US","rel":["summary","desktop","event"],"href":"https://www.espn.com/nba/game/_/gameId/40\(1000 + e)","text":"Gamecast","shortText":"Gamecast","isExternal":false,"isPremium":false}],"status":{"clock":0.0,"displayClock":"0.0","period":4,"type":{"id":"3","name":"STATUS_FINAL","state":"\(state)","completed":\(state == "post"),"description":"Final","detail":"\(rng.chance(10) ? "" : detail)","shortDetail":"\(rng.chance(10) ? "" : detail)"}}}
            """)
        }
        return Data(("{\"leagues\":[{\"id\":\"46\",\"uid\":\"s:40~l:46\",\"name\":\"National Basketball Association\",\"abbreviation\":\"NBA\",\"calendar\":[\"2025-10-21T07:00Z\",\"2025-10-22T07:00Z\"]}],\"season\":{\"type\":2,\"year\":2026},\"day\":{\"date\":\"2026-04-15\"},\"events\":[" + list.joined(separator: ",") + "]}").utf8)
    }

    static func espnTennis(matches: Int, baseDate: Date = Date()) -> Data {
        var rng = FixtureRNG(9)
        let iso = ISO8601DateFormatter()
        var comps: [String] = []
        for m in 0..<matches {
            let state = ["pre", "in", "post"][rng.int(3)]
            let date = iso.string(from: baseDate.addingTimeInterval(Double(rng.int(4 * 86400)) - 2 * 86400))
            let tbd = state == "pre" && rng.chance(20)
            func athlete(_ k: Int, _ homeAway: String) -> String {
                let name = tbd ? "TBD" : "Player \(m)-\(k) Ñoño"
                let lines = state == "pre" ? "" : ",\"linescores\":[{\"value\":6.0},{\"value\":\(rng.int(7))},{\"value\":7.0}]"
                return "{\"id\":\"\(m * 2 + k)\",\"homeAway\":\"\(homeAway)\",\"order\":\(k),\"athlete\":{\"displayName\":\"\(name)\",\"shortName\":\"P. \(m)\(k)\",\"flag\":{\"href\":\"https://a.espncdn.com/i/teamlogos/countries/500/esp.png\",\"alt\":\"Spain\"}}\(lines),\"score\":\"\(rng.int(3))\"}"
            }
            comps.append("{\"id\":\"\(9000 + m)\",\"date\":\"\(date)\",\"status\":{\"type\":{\"state\":\"\(state)\",\"shortDetail\":\"\(state == "in" ? "2nd Set" : "Final")\",\"detail\":\"Detail\"}},\"venue\":{\"fullName\":\"Court \(m % 5)\"},\"competitors\":[\(athlete(0, "home")),\(athlete(1, "away"))],\"broadcasts\":[{\"names\":[\"Tennis Channel\"]}]}")
        }
        return Data(("{\"events\":[{\"id\":\"777\",\"name\":\"Barcelona Open\",\"date\":\"\(iso.string(from: baseDate))\",\"groupings\":[{\"grouping\":{\"slug\":\"mens-singles\"},\"competitions\":[" + comps.joined(separator: ",") + "]},{\"competitions\":[]}]}]}").utf8)
    }

    static func espnMotorsport(baseDate: Date = Date()) -> Data {
        let iso = ISO8601DateFormatter()
        let sessions = ["FP1", "FP2", "FP3", "Qual", "Race"].enumerated().map { k, s in
            "{\"id\":\"60\(k)\",\"date\":\"\(iso.string(from: baseDate.addingTimeInterval(Double(k) * 7200)))\",\"type\":{\"id\":\"\(k)\",\"abbreviation\":\"\(s)\"},\"status\":{\"type\":{\"state\":\"\(k < 2 ? "post" : "pre")\",\"shortDetail\":\"\(k < 2 ? "Final" : "Scheduled")\"}},\"venue\":{\"fullName\":\"Circuit\"},\"geoBroadcasts\":[{\"media\":{\"shortName\":\"ESPN2\"}}]}"
        }
        return Data(("{\"events\":[{\"id\":\"600\",\"name\":\"Gulf Air Bahrain GP\",\"date\":\"\(iso.string(from: baseDate))\",\"competitions\":[" + sessions.joined(separator: ",") + "]},{\"id\":\"601\",\"name\":\"Single session\",\"shortName\":\"SS\",\"date\":\"2026-04-15T23:30Z\",\"competitions\":[{\"id\":\"1\",\"competitors\":[{\"order\":2,\"athlete\":{\"displayName\":\"Second\"},\"score\":\"+2\"},{\"order\":1,\"athlete\":{\"shortName\":\"First\"},\"score\":\"-3\"}]}]}]}").utf8)
    }

    static func espnGolfLeaderboard(players: Int, baseDate: Date = Date()) -> Data {
        var rng = FixtureRNG(10)
        let iso = ISO8601DateFormatter()
        var comps: [String] = []
        for p in 0..<players {
            let lines = (1...4).map { period -> String in
                let tee = rng.chance(80) ? ",\"teeTime\":\"\(iso.string(from: baseDate.addingTimeInterval(Double(period - 1) * 86400 + Double(rng.int(20000)))))\"" : ""
                let value = period <= 2 ? ",\"value\":\(60 + rng.int(15))" : (period == 3 && rng.chance(50) ? ",\"value\":null" : "")
                return "{\"period\":\(period)\(value)\(tee),\"displayValue\":\"-\(rng.int(5))\"}"
            }.joined(separator: ",")
            let score = rng.chance(50) ? "{\"displayValue\":\"-\(rng.int(12))\",\"value\":\(rng.int(12))}" : "\"-\(rng.int(12))\""
            comps.append("{\"id\":\"\(p)\",\"sortOrder\":\(players - p),\"athlete\":{\"displayName\":\"Golfer \(p) Åberg\"},\"score\":\(score),\"linescores\":[\(lines)]}")
        }
        return Data(("{\"events\":[{\"id\":\"401\",\"name\":\"The Masters\",\"shortName\":\"Masters\",\"date\":\"\(iso.string(from: baseDate))\",\"courses\":[{\"name\":\"Augusta National\"}],\"competitions\":[{\"status\":{\"period\":2,\"type\":{\"state\":\"in\"}},\"competitors\":[" + comps.joined(separator: ",") + "],\"broadcasts\":[{\"names\":[\"CBS\",\"ESPN+\"]}]}]}]}").utf8)
    }
}
