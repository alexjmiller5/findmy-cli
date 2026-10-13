#!/usr/bin/env swift
//
// findmy - read Apple Find My (People / Devices / Items) from the macOS app's
// accessibility tree. No Apple account, no iCloud API, no cache decryption.
//
// build: swiftc -O findmy.swift -o findmy
// The built binary needs Accessibility (System Settings > Privacy & Security).
//
import Cocoa
import ApplicationServices
import MapKit
import CryptoKit

let TABS = ["People", "Devices", "Items"]
let BUNDLE = "com.apple.findmy"
let APP_PATH = "/System/Applications/FindMy.app"

// MARK: - CLI

func usage() -> Never {
    print("""
    findmy - read Find My data from the macOS app

    USAGE
      findmy [all|people|devices|items]   snapshot a tab (default: all)
      findmy detail <name>                full street address for one entry
      findmy collect --hub URL --token-cmd CMD --handles FILE [--stream NAME] [--every SECONDS]
                                          append one coarse city check per resolved
                                          People row to a soma stream (default
                                          friend_city_checks); --every loops forever
      findmy --selftest                   run parser self-checks

    OPTIONS
      --geocode        with `detail`, also resolve lat/lon (MapKit, local)
      --text           human-readable output instead of JSON
      --repair         if the UI is unreadable, or (collect) every exact
                       displayed age is over 20 min (Find My stopped
                       refreshing), restart Find My, at most hourly for
                       staleness. Off by default: relaunching makes the
                       window visibly appear on screen.
      --launch=no      never launch Find My; fail if it is not ready

    NOTES
      Find My must be running with a window, on a Mac with a real display
      and a logged-in GUI session. The first launch pops its window up once.
    """)
    exit(0)
}

var args = Array(CommandLine.arguments.dropFirst())
func takeFlag(_ f: String) -> Bool {
    if let i = args.firstIndex(of: f) { args.remove(at: i); return true }
    return false
}
if takeFlag("--help") || takeFlag("-h") { usage() }
let wantSelftest = takeFlag("--selftest")
let wantGeocode  = takeFlag("--geocode")
let wantText     = takeFlag("--text")
let allowRepair  = takeFlag("--repair")
let noLaunch     = takeFlag("--launch=no")
func takeOption(_ name: String) -> String? {
    if let i = args.firstIndex(where: { $0.hasPrefix(name + "=") }) {
        return String(args.remove(at: i).dropFirst(name.count + 1))
    }
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}
let hubURL     = takeOption("--hub")
let tokenCmd   = takeOption("--token-cmd")
let handlesPath = takeOption("--handles")
let streamName = takeOption("--stream") ?? "friend_city_checks"
let every      = takeOption("--every").map { Int($0) ?? -1 } ?? 0

var mode = "all"
var detailName = ""
if let first = args.first {
    if first == "collect" {
        mode = "collect"
    } else if first == "detail" {
        mode = "detail"
        detailName = args.dropFirst().joined(separator: " ")
        if detailName.isEmpty && !wantSelftest { usage() }
    } else if ["all", "people", "devices", "items"].contains(first.lowercased()) {
        mode = first.lowercased()
    } else if !wantSelftest {
        FileHandle.standardError.write("unknown argument: \(first)\n".data(using: .utf8)!)
        usage()
    }
}

func die(_ msg: String, _ code: Int32) -> Never {
    FileHandle.standardError.write("findmy: \(msg)\n".data(using: .utf8)!)
    exit(code)
}

// MARK: - Row parsing
//
// A row is one comma-joined label with a variable field count, e.g.
//   "Jane Doe, Cupertino, CA , Now, 0 mi"
//   "MacBook Air (2), This Mac, With You"
//   "Backpack, 2 wk. ago, 74 mi"
// Only the name is reliably positional, so `raw` is always emitted too.

let whenRE = try! NSRegularExpression(
    pattern: #"^(Now|With You|\d+ (min\.|hr\.|sec\.|days?|wk\.|mo\.|yr\.) ago|Last (mo\.|wk\.|yr\.)|\d+ (days?|wk\.|mo\.) ago)$"#)
let distRE = try! NSRegularExpression(pattern: #"^[\d.,]+ (mi|ft|km|m|yd)$"#)
/// A trailing distance, thousands separators included ("2,470 mi"), so its
/// comma never splits into the place fields.
let distTailRE = try! NSRegularExpression(pattern: #",\s*(\d{1,3}(,\d{3})+(\.\d+)? (mi|ft|km|m|yd))\s*$"#)
func rxMatch(_ re: NSRegularExpression, _ s: String) -> Bool {
    re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
}

/// Find My renders typographic apostrophes ("Sam's iPhone"), which nobody types.
func norm(_ s: String) -> String {
    s.replacingOccurrences(of: "\u{2019}", with: "'")
     .replacingOccurrences(of: "\u{2018}", with: "'")
     .lowercased()
     .trimmingCharacters(in: .whitespaces)
}

/// Opaque key for an explicitly exposed source handle, not a canonical person
/// ID. Resolve only through a unique existing contact/account binding; names,
/// ambiguous matches and account changes require review outside this parser.
func sourceHandleKey(_ label: String) -> String? {
    let value = label.trimmingCharacters(in: .whitespacesAndNewlines)
    let identity: String
    if value.range(of: #"^\+[1-9][0-9 ()-]{6,25}$"#, options: .regularExpression) != nil {
        let phone = value.filter { !" ()-".contains($0) }
        guard (8...15).contains(phone.count - 1) else { return nil }
        identity = "tel:" + phone
    } else if value.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil {
        let parts = value.split(separator: "@")
        identity = "mailto:" + parts[0] + "@" + parts[1].lowercased()
    } else { return nil }
    return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// Only fields belonging to one native row may be assembled. Expanded AX
/// trees expose title, subtitle and distance separately from the compact label.
func matchingRows(_ labels: [String], query: String) -> [Int] {
    let key = norm(query)
    guard !key.isEmpty else { return [] }
    let names = labels.map { norm($0.components(separatedBy: ",")[0]) }
    let exact = names.indices.filter { names[$0] == key }
    return exact.isEmpty ? names.indices.filter { names[$0].hasPrefix(key) } : exact
}

func rowText(_ fields: [String: String]) -> String? {
    if let compact = fields["HomeElementCell"], !compact.isEmpty { return compact }
    guard let title = fields["HomeCellTitleLabel"], !title.isEmpty else { return nil }
    return [title, fields["HomeCellSubtitleLabel"], fields["HomeCellDistance"]]
        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
}

func parse(_ raw: String) -> [String: Any] {
    var row: [String: Any] = ["raw": raw]
    var text = raw
    if let m = distTailRE.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) {
        row["distance"] = (raw as NSString).substring(with: m.range(at: 1))
        text = (raw as NSString).substring(to: m.range.location)
    }
    var fields = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    guard !fields.isEmpty else { return row }
    let name = fields.removeFirst()
    row["name"] = name
    if let key = sourceHandleKey(name) { row["source_handle_key"] = key }
    if row["distance"] == nil, let last = fields.last, rxMatch(distRE, last) { row["distance"] = last; fields.removeLast() }
    if let last = fields.last, last == "Paused" {
        row["source_state"] = "paused"
        fields.removeLast()
    } else if let last = fields.last, rxMatch(whenRE, last) {
        row["when"] = last
        fields.removeLast()
    }
    let loc = fields.joined(separator: ", ")
    if loc == "Can see your location" {
        row["source_state"] = "not_shared"
    } else if ["Locating\u{2026}", "Locating..."].contains(loc) {
        row["source_state"] = "unknown"
    } else if ["Address Unavailable", "No location found", "Location Not Available"].contains(loc) {
        row["source_state"] = "unavailable"
    } else if !loc.isEmpty {
        row["location"] = loc
        if row["source_state"] == nil { row["source_state"] = "available" }
    } else if row["source_state"] == nil {
        row["source_state"] = "unknown"
    }
    return row
}

/// Collection identity/time describe this actual AX read, not a sensor fix.
/// Serialize the same check without renewing its evidence or inventing tst.
func sourceCheck(raw: String, fields: [String: String], checkedAt: Date, id: String) -> [String: Any] {
    var value = parse(raw)
    value["raw_fields"] = fields
    value["source_check_id"] = id
    value["checked_at"] = ISO8601DateFormatter().string(from: checkedAt)
    return value
}

/// A row's stable identity across reads: its title. `when`/`distance` text
/// changes between reads, the title does not.
func rowIdentity(_ raw: String) -> String { parse(raw)["name"] as? String ?? "" }

/// Continue an enumerated sequence with one scrolled page. The page must start
/// with a suffix of the sequence (overlap proves no row was skipped) and add
/// only unseen rows. `[]` = nothing new (end of list); nil = gap, reorder or
/// ambiguous identity, so the list cannot be proven complete.
func mergePage(_ sequence: [String], _ page: [String]) -> [String]? {
    guard Set(page).count == page.count else { return nil }
    guard !sequence.isEmpty else { return page }
    guard let k = (1...min(sequence.count, page.count)).reversed()
        .first(where: { Array(page.prefix($0)) == Array(sequence.suffix($0)) }) else { return nil }
    let rest = Array(page.dropFirst(k))
    return Set(rest).isDisjoint(with: sequence) ? rest : nil
}

/// A long-running Find My can stop refreshing friends: every displayed age
/// then grows by the collection interval. True when at least three records
/// show an exact age and even the freshest is older than `threshold` seconds.
func staleView(_ records: [[String: Any]], threshold: Int) -> Bool {
    let ages = records.compactMap { $0["age_seconds"] as? Int }
    return ages.count >= 3 && ages.min()! > threshold
}

let ageRE = try! NSRegularExpression(pattern: #"^(\d+) (sec\.|min\.|hr\.|days?|wk\.) ago$"#)
/// Displayed age in seconds where the unit is exact; months, years and
/// "Last ..." have no defensible second count.
func ageSeconds(_ text: String?) -> Int? {
    guard let text else { return nil }
    if text == "Now" { return 0 }
    guard let m = ageRE.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let n = Int((text as NSString).substring(with: m.range(at: 1))) else { return nil }
    let unit = (text as NSString).substring(with: m.range(at: 2))
    return n * ["sec.": 1, "min.": 60, "hr.": 3600, "day": 86400, "days": 86400, "wk.": 604_800][unit]!
}

struct Place: Equatable { let city: String?, region: String?, country: String? }
/// Split a displayed locality. ponytail: a trailing 2-letter code is a region
/// (US/CA style) and the part before it the city ("Place, City, ST" names a
/// neighbourhood first); otherwise "City, Country" or "City, Region, Country".
/// `location_text` keeps the verbatim display for consumers that need better.
func place(_ text: String?) -> Place {
    let parts = (text ?? "").components(separatedBy: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    guard let last = parts.last, parts.count > 1 else { return Place(city: parts.first, region: nil, country: nil) }
    if last.range(of: #"^[A-Z]{2}$"#, options: .regularExpression) != nil {
        return Place(city: parts[parts.count - 2], region: last, country: nil)
    }
    let region = parts.dropFirst().dropLast().joined(separator: ", ")
    return Place(city: parts[0], region: region.isEmpty ? nil : region, country: last)
}

/// One coarse check per friend row resolved through an explicit handle key.
/// Names never resolve; unresolved rows are counted, never written. Only rows
/// that share a location count: the self row ("Me", no handle) and people who
/// only see yours (`not_shared`) are neither checks nor unresolved.
func cityChecks(_ rows: [[String: Any]], handles: [String: String], complete: Bool)
    -> (records: [[String: Any]], rows: Int, unresolved: Int) {
    let friends = rows.filter {
        !($0["name"] as? String == "Me" && $0["source_handle_key"] == nil)
            && $0["source_state"] as? String != "not_shared"
    }
    let resolved = friends.compactMap { row -> ([String: Any], String)? in
        guard let key = row["source_handle_key"] as? String, let person = handles[key] else { return nil }
        return (row, person)
    }
    let unresolved = friends.count - resolved.count
    let records = resolved.map { row, person -> [String: Any] in
        let location = row["location"] as? String
        let p = place(location)
        let when = row["when"] as? String
        let checked = (row["checked_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return ["person_id": person, "city": p.city ?? NSNull(), "region": p.region ?? NSNull(),
                "country": p.country ?? NSNull(), "location_text": location ?? NSNull(),
                "age_text": when ?? NSNull(), "age_seconds": ageSeconds(when) ?? NSNull(),
                "paused": row["source_state"] as? String == "paused",
                "source_check_id": row["source_check_id"] ?? NSNull(),
                "checked_at": checked.map { Int($0.timeIntervalSince1970) } ?? NSNull(),
                "run_rows": friends.count, "run_unresolved": unresolved, "run_complete": complete,
                "source": "findmy_ax"]
    }
    return (records, friends.count, unresolved)
}

func recordJSON(_ record: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes])
}

if wantSelftest {
    let cases: [(String, String, String?, String?, String?)] = [
        ("Jane Doe, Cupertino, CA , Now, 0 mi", "Jane Doe", "Cupertino, CA", "Now", "0 mi"),
        ("Me, Cupertino, CA", "Me", "Cupertino, CA", nil, nil),
        ("John Smith, Address Unavailable , Now, 29 mi", "John Smith", "Address Unavailable", "Now", "29 mi"),
        ("MacBook Air (2), This Mac, With You", "MacBook Air (2)", "This Mac", "With You", nil),
        ("AirPods Pro - Find My, No location found", "AirPods Pro - Find My", "No location found", nil, nil),
        ("Keys, Home , Last mo., 30 mi", "Keys", "Home", "Last mo.", "30 mi"),
        ("Backpack, 2 wk. ago, 74 mi", "Backpack", nil, "2 wk. ago", "74 mi"),
        ("Ada Roe, San Francisco, CA , 7 min. ago, 31 mi", "Ada Roe", "San Francisco, CA", "7 min. ago", "31 mi"),
    ]
    for (raw, name, loc, when, dist) in cases {
        let r = parse(raw)
        assert(r["name"] as? String == name, "name: \(raw) -> \(r)")
        assert(r["location"] as? String == (["Address Unavailable", "No location found"].contains(loc ?? "") ? nil : loc), "location: \(raw) -> \(r)")
        assert(r["when"] as? String == when, "when: \(raw) -> \(r)")
        assert(r["distance"] as? String == dist, "distance: \(raw) -> \(r)")
    }
    let candidates = ["<person-1>, City 1, Now", "<person-12>, City 2, Now"]
    assert(matchingRows(candidates, query: "<person-") == [0, 1])
    assert(matchingRows(candidates, query: "<person-1>") == [0])
    assert(matchingRows(candidates, query: "") == [])
    assert(matchingRows(candidates, query: "City 1") == [])
    let compact = rowText(["HomeElementCell":"<person-1>, City 1, Region 1, Now, 5 mi"])
    assert(compact == "<person-1>, City 1, Region 1, Now, 5 mi")
    let expanded = rowText(["HomeCellTitleLabel":"+12025550101", "HomeCellSubtitleLabel":"City 1, Region 1, Now", "HomeCellDistance":"5 mi"])
    assert(expanded == "+12025550101, City 1, Region 1, Now, 5 mi")
    assert(parse(expanded!)["name"] as? String == "+12025550101")
    assert(parse(expanded!)["location"] as? String == "City 1, Region 1")
    assert(rowText(["HomeCellSubtitleLabel":"City 1, Region 1, Now"]) == nil)
    assert(rowText(["UnrelatedPane":"<person-1>, City 1, Now"]) == nil)
    // Native handles can be keyed without turning a display name into identity.
    assert(sourceHandleKey("+1 (202) 555-0101") == sourceHandleKey("+12025550101"))
    assert(sourceHandleKey("<person-1>") == nil)
    assert(sourceHandleKey("202-555-0101") == nil)
    assert(sourceHandleKey("+0123456789") == nil)
    assert(sourceHandleKey("+1234567890123456") == nil)
    assert(sourceHandleKey("person-1@EXAMPLE.invalid") == sourceHandleKey("person-1@example.invalid"))
    assert(sourceHandleKey("Person-1@example.invalid") != sourceHandleKey("person-1@example.invalid"))
    assert(sourceHandleKey("person-1@example.invalid")?.count == 64)
    assert(parse("+1 (202) 555-0101, City 1, Region 1, Now")["source_handle_key"] as? String == sourceHandleKey("+12025550101"))
    let paused = parse("Person 1, City 1, Region 1 , Paused, 10 mi")
    assert(paused["location"] as? String == "City 1, Region 1")
    assert(paused["source_state"] as? String == "paused")
    assert(paused["when"] == nil)
    // People who see your location but share none of theirs are not a location.
    let notShared = parse("Person 6, Can see your location")
    assert(notShared["source_state"] as? String == "not_shared" && notShared["location"] == nil)
    // A friend still being located has no place yet.
    for locating in ["Person 9, Locating\u{2026}", "Person 9, Locating..."] {
        assert(parse(locating)["source_state"] as? String == "unknown" && parse(locating)["location"] == nil)
    }
    let unavailable = parse("Person 2, No location found")
    assert(unavailable["source_state"] as? String == "unavailable")
    assert(unavailable["location"] == nil)
    // Thousands separators belong to the distance, not to the place.
    let far = parse("Person 7, City 7, ST , Paused, 2,470 mi")
    assert(far["distance"] as? String == "2,470 mi" && far["location"] as? String == "City 7, ST")
    assert(far["source_state"] as? String == "paused")
    let farLive = parse("Person 8, City 8, ST , Now, 1,089 mi")
    assert(farLive["when"] as? String == "Now" && farLive["location"] as? String == "City 8, ST")
    let live = parse("Person 3, City 2, Region 2 , Now, 5 mi")
    assert(live["source_state"] as? String == "available")
    let collected = Date(timeIntervalSince1970: 1_800_000_000)
    let check = sourceCheck(raw: "<person-1>, City 1, Now", fields: ["HomeElementCell":"<person-1>, City 1, Now"],
                            checkedAt: collected, id: "example-check-1")
    assert(check["source_check_id"] as? String == "example-check-1")
    assert(check["checked_at"] as? String == "2027-01-15T08:00:00Z")
    assert(check["when"] as? String == "Now")
    assert(check["tst"] == nil && check["latitude"] == nil && check["longitude"] == nil)
    assert(check["raw_fields"] as? [String:String] == ["HomeElementCell":"<person-1>, City 1, Now"])
    // Enumeration: a scrolled page must continue the sequence it overlaps.
    assert(mergePage([], ["a", "b"]) == ["a", "b"])
    assert(mergePage(["a", "b", "c"], ["b", "c", "d", "e"]) == ["d", "e"])
    assert(mergePage(["a", "b", "c"], ["b", "c"]) == [])            // end of list
    assert(mergePage(["a", "b", "c"], ["d", "e"]) == nil)            // gap: no overlap
    assert(mergePage(["a", "b", "c"], ["c", "b", "d"]) == nil)       // reordered while scrolling
    assert(mergePage(["a", "b"], ["b", "b"]) == nil)                 // ambiguous identity
    assert(mergePage(["a"], ["a", "c", "c"]) == nil && mergePage([], ["a", "a"]) == nil)
    assert(rowIdentity("+1 (202) 555-0101, City 1, ST , 2 min. ago, 5 mi") == "+1 (202) 555-0101")
    // Displayed age: exact units only, never a guessed fix time.
    assert(ageSeconds("Now") == 0)
    assert(ageSeconds("7 min. ago") == 420)
    assert(ageSeconds("2 hr. ago") == 7200)
    assert(ageSeconds("1 day ago") == 86400 && ageSeconds("3 days ago") == 259200)
    assert(ageSeconds("2 wk. ago") == 1_209_600)
    assert(ageSeconds("Last mo.") == nil && ageSeconds("4 mo. ago") == nil && ageSeconds(nil) == nil)
    assert(place("City 1, ST") == Place(city: "City 1", region: "ST", country: nil))
    assert(place("City 1, Country 1") == Place(city: "City 1", region: nil, country: "Country 1"))
    assert(place("City 1, Region 1, Country 1") == Place(city: "City 1", region: "Region 1", country: "Country 1"))
    assert(place("City 1") == Place(city: "City 1", region: nil, country: nil))
    assert(place("Place 1, City 1, ST") == Place(city: "City 1", region: "ST", country: nil))
    assert(place(nil) == Place(city: nil, region: nil, country: nil))
    // City checks: resolved rows only, counted unresolved, no coordinates.
    let k1 = sourceHandleKey("+12025550101")!, k2 = sourceHandleKey("+12025550102")!
    let at = Date(timeIntervalSince1970: 1_800_000_000)
    let rows: [[String: Any]] = [
        sourceCheck(raw: "Me, City 1, ST", fields: [:], checkedAt: at, id: "c0"),
        sourceCheck(raw: "+1 (202) 555-0101, City 1, ST , 7 min. ago, 5 mi", fields: [:], checkedAt: at, id: "c1"),
        sourceCheck(raw: "+1 (202) 555-0102, City 2, ST , Now, 9 mi", fields: [:], checkedAt: at, id: "c2"),
        sourceCheck(raw: "<person-3>, City 3, ST , Now, 9 mi", fields: [:], checkedAt: at, id: "c3"),
        sourceCheck(raw: "person-4@example.invalid, City 4, ST , Paused, 1 mi", fields: [:], checkedAt: at, id: "c4"),
        sourceCheck(raw: "+1 (202) 555-0105, No location found", fields: [:], checkedAt: at, id: "c5"),
        sourceCheck(raw: "+1 (202) 555-0106, Can see your location", fields: [:], checkedAt: at, id: "c6"),
    ]
    let map = [k1: "person-a", sourceHandleKey("person-4@example.invalid")!: "person-b",
               sourceHandleKey("+12025550105")!: "person-c"]
    assert(map[k2] == nil)
    let checks = cityChecks(rows, handles: map, complete: true)
    assert(checks.rows == 5 && checks.unresolved == 2 && checks.records.count == 3)
    let first = checks.records[0]
    assert(first["person_id"] as? String == "person-a" && first["city"] as? String == "City 1")
    assert(first["region"] as? String == "ST" && first["country"] is NSNull)
    assert(first["age_text"] as? String == "7 min. ago" && first["age_seconds"] as? Int == 420)
    assert(first["paused"] as? Bool == false && first["source_check_id"] as? String == "c1")
    assert(first["checked_at"] as? Int == 1_800_000_000 && first["source"] as? String == "findmy_ax")
    assert(first["run_rows"] as? Int == 5 && first["run_unresolved"] as? Int == 2 && first["run_complete"] as? Bool == true)
    for r in checks.records { assert(r["lat"] == nil && r["lon"] == nil && r["tst"] == nil && r["latitude"] == nil) }
    let pausedCheck = checks.records[1]
    assert(pausedCheck["paused"] as? Bool == true && pausedCheck["age_text"] is NSNull && pausedCheck["age_seconds"] is NSNull)
    assert(checks.records[2]["city"] is NSNull && checks.records[2]["location_text"] is NSNull)
    assert(cityChecks(rows, handles: map, complete: false).records.allSatisfy { $0["run_complete"] as? Bool == false })
    let encoded = String(data: recordJSON(first), encoding: .utf8)!
    assert(encoded.contains("\"checked_at\":1800000000") && !encoded.contains("\n"))
    // address picker
    assert(pickAddress(["Jane Doe", "1 Infinite Loop, Cupertino, CA  95014", "Live"])
           == "1 Infinite Loop, Cupertino, CA  95014")
    assert(pickAddress(["Jane Doe", "Cupertino, CA • Now"]) == nil)
    assert(norm("Sam\u{2019}s iPhone") == "sam's iphone")
    assert(norm("Sam\u{2019}s iPhone").hasPrefix(norm("Sam's iPh")))
    // stale view: three exact ages all past the threshold; paused or vague ages never count
    func aged(_ seconds: [Any]) -> [[String: Any]] { seconds.map { ["age_seconds": $0] } }
    assert(staleView(aged([1500, 1800, 2100]), threshold: 1200))
    assert(!staleView(aged([1500, 600, 2100]), threshold: 1200))
    assert(!staleView(aged([1500, 1800]), threshold: 1200))
    assert(!staleView(aged([1500, 1800, NSNull(), NSNull()]), threshold: 1200))
    assert(!staleView(aged([1200, 1800, 2100]), threshold: 1200))
    print("selftest ok (\(cases.count + 3) parse cases + source-handle keys + enumeration + city checks + address picker + stale view)")
    exit(0)
}

// MARK: - Accessibility plumbing

struct Failure: Error { let message: String; let code: Int32 }

/// One process drives the Find My UI at a time: another reader scrolling the
/// same list would corrupt both reads. Waits for the per-user lock.
func withUILock<T>(_ body: () throws -> T) rethrows -> T {
    var dir = [CChar](repeating: 0, count: Int(PATH_MAX))
    confstr(_CS_DARWIN_USER_TEMP_DIR, &dir, dir.count)
    let fd = open(String(cString: dir) + "findmy-cli.lock", O_CREAT | O_RDWR, 0o600)
    if fd >= 0 { flock(fd, LOCK_EX) }
    defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
    return try body()
}

func findMyApp() -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: BUNDLE).first
}
func launchFindMy() {
    // Must be `open -g`: NSWorkspace(activates:false) starts the process but
    // never builds a window, leaving a permanently empty AX tree.
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-g", "-a", APP_PATH]
    try? p.run()
    p.waitUntilExit()
    let deadline = Date().addingTimeInterval(20)
    while findMyApp() == nil && Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
}

var axPid: pid_t = 0
var ax = AXUIElementCreateApplication(axPid)
func refreshAX() {
    guard let pid = findMyApp()?.processIdentifier, pid != axPid else { return }
    axPid = pid
    ax = AXUIElementCreateApplication(pid)
}

func attr(_ el: AXUIElement, _ n: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, n as CFString, &v) == .success ? v : nil
}
func sattr(_ el: AXUIElement, _ n: String) -> String? { attr(el, n) as? String }
func label(_ el: AXUIElement) -> String {
    sattr(el, "AXDescription") ?? sattr(el, "AXTitle") ?? sattr(el, "AXValue") ?? ""
}
func findAll(_ el: AXUIElement, _ m: (AXUIElement) -> Bool, _ out: inout [AXUIElement], _ d: Int = 0) {
    if d > 24 { return }
    if m(el) { out.append(el) }
    for k in (attr(el, "AXChildren") as? [AXUIElement] ?? []) { findAll(k, m, &out, d + 1) }
}
func all(_ m: (AXUIElement) -> Bool) -> [AXUIElement] { var o: [AXUIElement] = []; findAll(ax, m, &o); return o }
func role(_ r: String) -> [AXUIElement] { all { sattr($0, "AXRole") == r } }

/// The row list lives in the sibling container next to the AXTabGroup. Scoping
/// reads to it keeps an open detail pane (whose labels live elsewhere in the
/// window) from being counted as extra rows.
func listContainer() -> AXUIElement? {
    guard let tg = all({ sattr($0, "AXRole") == "AXTabGroup" }).first,
          let parentRef = attr(tg, "AXParent") else { return nil }
    let parent = parentRef as! AXUIElement
    let siblings = attr(parent, "AXChildren") as? [AXUIElement] ?? []
    return siblings.first { sattr($0, "AXRole") != "AXTabGroup" }
}

struct SourceRow {
    let element: AXUIElement
    let fields: [String: String]
    let text: String
    let checkedAt: Date
    let checkID: String
    var record: [String: Any] {
        sourceCheck(raw: text, fields: fields, checkedAt: checkedAt, id: checkID)
    }
}

func sourceRows() -> [SourceRow] {
    guard let root = listContainer() else { return [] }
    var cells: [AXUIElement] = []
    findAll(root, { sattr($0, "AXIdentifier") == "HomeElementCell" && sattr($0, "AXRole") == "AXGroup" }, &cells)
    return cells.compactMap { cell in
        var texts: [AXUIElement] = []
        findAll(cell, { sattr($0, "AXRole") == "AXStaticText" }, &texts)
        var fields: [String: String] = [:]
        var compact: AXUIElement?
        for text in texts {
            guard let key = sattr(text, "AXIdentifier"),
                  ["HomeElementCell", "HomeCellTitleLabel", "HomeCellSubtitleLabel", "HomeCellDistance"].contains(key) else { continue }
            let value = label(text)
            guard fields[key] == nil else { return nil } // Ambiguous row structure fails closed.
            fields[key] = value
            if key == "HomeElementCell" { compact = text }
        }
        guard let text = rowText(fields) else { return nil }
        return SourceRow(element: compact ?? cell, fields: fields, text: text,
                         checkedAt: Date(), checkID: UUID().uuidString.lowercased())
    }
}

func rowStrings() -> [String] { sourceRows().map(\.text) }

func windowCount() -> Int {
    var v: CFTypeRef?
    AXUIElementCopyAttributeValue(ax, "AXWindows" as CFString, &v)
    return (v as? [AXUIElement])?.count ?? 0
}

// Find My persists window state, so a close (or a crash while closed) leaves it
// running with zero windows and an empty AX tree.
var didRepair = false
func ensureWindow() {
    guard windowCount() == 0 else { return }
    // activate() rebuilds the window without taking keyboard focus.
    let deadline = Date().addingTimeInterval(6)
    while windowCount() == 0 && Date() < deadline {
        findMyApp()?.activate()
        Thread.sleep(forTimeInterval: 1.0)
    }
    guard windowCount() == 0, allowRepair, !didRepair else { return }
    // Last resort, opt-in: the app will not rebuild a window for `open`, so
    // restart it. Find My is a stateless viewer, but the window visibly appears.
    didRepair = true
    restartFindMy()
}

func restartFindMy() {
    if let pid = findMyApp()?.processIdentifier { kill(pid, SIGKILL) }
    let gone = Date().addingTimeInterval(10)
    while findMyApp() != nil && Date() < gone { Thread.sleep(forTimeInterval: 0.5) }
    launchFindMy()
    let back = Date().addingTimeInterval(20)
    while windowCount() == 0 && Date() < back { refreshAX(); Thread.sleep(forTimeInterval: 0.5) }
}

func tabButtons() -> [AXUIElement] { all { sattr($0, "AXSubrole") == "AXTabButton" } }
func tabNamed(_ n: String) -> AXUIElement? { tabButtons().first { label($0) == n } }
func isSelected(_ n: String) -> Bool {
    guard let t = tabNamed(n) else { return false }
    return (attr(t, "AXValue") as? Int) == 1
}

/// Every launch covers the window with a notifications pitch sheet; decline
/// it. Any other sheet stays put and the read fails loudly.
func declineNotificationSheet() {
    for sheet in role("AXSheet") {
        var buttons: [AXUIElement] = []
        findAll(sheet, { sattr($0, "AXRole") == "AXButton" }, &buttons)
        guard Set(buttons.map(label)) == ["Enable Notifications", "Not Now"],
              let notNow = buttons.first(where: { label($0) == "Not Now" }) else { continue }
        AXUIElementPerformAction(notNow, "AXPress" as CFString)
    }
}

func waitReady(timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        refreshAX()
        ensureWindow()
        declineNotificationSheet()
        if !tabButtons().isEmpty && rowStrings().count > TABS.count { return true }
        Thread.sleep(forTimeInterval: 0.5)
    }
    return false
}

/// Select a tab and wait for *its own* rows. A press that silently no-ops would
/// otherwise leave the previous tab's rows in place, to be recorded under this
/// tab's name - a confident, wrong answer.
@discardableResult
func selectTab(_ want: String, previousRows: [String] = []) -> [SourceRow]? {
    guard let tab = tabNamed(want) else { return nil }
    var deadline = Date().addingTimeInterval(10)
    while !isSelected(want) && Date() < deadline {
        AXUIElementPerformAction(tab, "AXPress" as CFString)
        Thread.sleep(forTimeInterval: 0.6)
    }
    guard isSelected(want) else { return nil }

    var stable = 0
    var last: [String] = []
    deadline = Date().addingTimeInterval(15)
    while Date() < deadline {
        let snapshot = sourceRows()
        let now = snapshot.map(\.text)
        if !now.isEmpty && now == last && now != previousRows {
            stable += 1
            if stable >= 3 { return snapshot }
        } else {
            stable = 0
        }
        last = now
        Thread.sleep(forTimeInterval: 0.3)
    }
    return nil
}

/// Accessibility grant, a running Find My and a readable window, or the exit
/// code that says which one is missing.
var promptedForTrust = false
func prepare() throws {
    // The prompt only lists this binary in the Accessibility pane for a human
    // to switch on; it grants nothing. Once per process, not once per loop.
    let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: mode == "collect" && !promptedForTrust] as CFDictionary
    promptedForTrust = true
    guard AXIsProcessTrustedWithOptions(prompt) else {
        throw Failure(message: "no Accessibility permission. Grant it to this binary in "
            + "System Settings > Privacy & Security > Accessibility.", code: 2)
    }
    if findMyApp() == nil {
        if noLaunch { throw Failure(message: "Find My is not running (--launch=no)", code: 3) }
        launchFindMy()
    }
    guard findMyApp() != nil else { throw Failure(message: "could not launch Find My", code: 3) }
    refreshAX()
    guard waitReady(timeout: 30) else {
        throw Failure(message: "Find My UI never became readable. Is a display attached, the session "
            + "unlocked and no sheet open over the window? Try --repair.", code: 4)
    }
}

func selectedTab() -> String? { tabButtons().first { (attr($0, "AXValue") as? Int) == 1 }.map(label) }

func restoreTab(_ original: String?) {
    if let o = original, !isSelected(o), let t = tabNamed(o) {
        AXUIElementPerformAction(t, "AXPress" as CFString)
    }
}

/// Share of visible located rows showing "Paused".
func pausedShare(_ rows: [SourceRow]) -> Double {
    let located = rows.map { parse($0.text) }.filter { $0["location"] != nil }
    guard !located.isEmpty else { return 0 }
    return Double(located.filter { $0["source_state"] as? String == "paused" }.count) / Double(located.count)
}

/// A Find My launched in the background shows "Paused" on nearly every friend
/// until it has been active once. Make it frontmost until live ages return,
/// then hand focus back. ponytail: half the visible rows paused = app-wide
/// pause, a lone paused friend never triggers it.
func wakeIfPaused() {
    guard pausedShare(sourceRows()) >= 0.5, let app = findMyApp() else { return }
    let previous = NSWorkspace.shared.frontmostApplication
    AXUIElementSetAttributeValue(ax, "AXFrontmost" as CFString, kCFBooleanTrue)
    // Un-paused rows show no age for a second or two; wait for real ages, then
    // stay active a little longer so updates keep flowing once focus returns.
    func live(_ rows: [SourceRow]) -> Bool {
        pausedShare(rows) < 0.5 && rows.contains { parse($0.text)["when"] != nil }
    }
    let deadline = Date().addingTimeInterval(20)
    repeat { Thread.sleep(forTimeInterval: 0.5) } while Date() < deadline && !live(sourceRows())
    Thread.sleep(forTimeInterval: 3)
    if let previous, previous.processIdentifier != app.processIdentifier {
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(previous.processIdentifier),
                                     "AXFrontmost" as CFString, kCFBooleanTrue)
    }
}

// MARK: - Enumeration
//
// The list is virtualized: only rendered rows exist in the AX tree. Scroll the
// list container to the top, then page down, merging each settled page onto
// the sequence until two scrolls in a row add nothing. Every page must overlap
// the previous one in order, so a skipped or reordered row fails closed.

func identities(_ rows: [SourceRow]) -> [String] { rows.map { rowIdentity($0.text) } }

/// Read until three consecutive reads, 0.3 s apart, agree on the visible rows.
func settledRows() -> [SourceRow] {
    var last = sourceRows()
    var same = 0
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline && same < 2 {
        Thread.sleep(forTimeInterval: 0.3)
        let now = sourceRows()
        same = identities(now) == identities(last) ? same + 1 : 0
        last = now
    }
    return last
}

func scroll(_ action: String) {
    if let list = listContainer() { AXUIElementPerformAction(list, action as CFString) }
}

func frame(_ el: AXUIElement) -> CGRect? {
    guard let p = attr(el, "AXPosition"), let s = attr(el, "AXSize") else { return nil }
    var origin = CGPoint.zero, size = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &origin)
    AXValueGetValue(s as! AXValue, .cgSize, &size)
    return CGRect(origin: origin, size: size)
}

/// Positive proof of an end: only at the top does the first rendered row
/// start inside the list's frame, only at the bottom does the last one end
/// inside it; every other page has a row cut by that edge. "Scrolling changed
/// nothing" alone is not proof - another reader scrolling the other way
/// looks the same.
func atListEdge(top: Bool) -> Bool {
    guard let list = listContainer(), let box = frame(list) else { return false }
    let cells = (attr(list, "AXChildren") as? [AXUIElement] ?? []).compactMap(frame)
    guard let first = cells.map(\.minY).min(), let last = cells.map(\.maxY).max() else { return false }
    return top ? first >= box.minY - 0.5 : last <= box.maxY + 0.5
}

/// Scroll up until two scrolls change nothing and the top edge is in view.
func scrollToTop(maxPages: Int) -> [SourceRow]? {
    var page = settledRows()
    var idle = 0
    var tries = 0
    while idle < 2 && tries < maxPages {
        tries += 1
        scroll("AXScrollUpByPage")
        let next = settledRows()
        idle = identities(next) == identities(page) ? idle + 1 : 0
        page = next
    }
    return idle >= 2 && atListEdge(top: true) ? page : nil
}

/// All rows of the selected tab, and whether the whole list was proven read:
/// from a proven top, every page continuing the sequence, to a proven bottom.
func enumerateList(maxPages: Int = 100) -> (rows: [SourceRow], complete: Bool) {
    guard let top = scrollToTop(maxPages: maxPages),
          var sequence = mergePage([], identities(top)) else { return (sourceRows(), false) }
    var rows = top
    var idle = 0
    for _ in 0..<maxPages {
        scroll("AXScrollDownByPage")
        let next = settledRows()
        guard let added = mergePage(sequence, identities(next)) else { return (rows, false) }
        if added.isEmpty {
            idle += 1
            if idle >= 2 { return (rows, atListEdge(top: false)) }
            continue
        }
        idle = 0
        sequence += added
        rows += next.filter { added.contains(rowIdentity($0.text)) }
    }
    return (rows, false)
}

// MARK: - Detail drill

/// Of a detail pane's labels, the street address is the one carrying a digit and
/// a comma that is not a distance and not the "City • when" summary line.
func pickAddress(_ texts: [String]) -> String? {
    texts.first {
        $0.contains(",")
        && $0.rangeOfCharacter(from: .decimalDigits) != nil
        && !$0.contains("•")
        && !rxMatch(distRE, $0.trimmingCharacters(in: .whitespaces))
        && !$0.hasSuffix(" mi") && !$0.hasSuffix(" ft") && !$0.hasSuffix(" km")
    }
}

func geocode(_ address: String) -> (Double, Double)? {
    var result: (Double, Double)?
    // The macOS 26 SDK replaces CLGeocoder; older SDKs (the Nix build) lack the replacement.
    #if compiler(>=6.2)
    guard #available(macOS 26.0, *), let req = MKGeocodingRequest(addressString: address) else { return nil }
    req.getMapItems { items, _ in
        if let c = items?.first?.location.coordinate { result = (c.latitude, c.longitude) }
        CFRunLoopStop(CFRunLoopGetMain())
    }
    #else
    CLGeocoder().geocodeAddressString(address) { marks, _ in
        if let c = marks?.first?.location?.coordinate { result = (c.latitude, c.longitude) }
        CFRunLoopStop(CFRunLoopGetMain())
    }
    #endif
    DispatchQueue.global().asyncAfter(deadline: .now() + 20) { CFRunLoopStop(CFRunLoopGetMain()) }
    CFRunLoopRun()
    return result
}

func detail(_ name: String) -> [String: Any] {
    var out: [String: Any] = ["query": name]
    let original = selectedTab()

    // Find the row in whichever tab holds it.
    var found: SourceRow?
    var prev: [String] = []
    for tab in TABS {
        if !isSelected(tab) {
            guard let selected = selectTab(tab, previousRows: prev) else { continue }
            prev = selected.map(\.text)
        }
        let candidates = sourceRows()
        let matches = matchingRows(candidates.map(\.text), query: name)
        if matches.count > 1 {
            out["error"] = "ambiguous entry prefix; use an exact unique source label"
            restoreTab(original)
            return out
        }
        if let index = matches.first {
            found = candidates[index]
            out["tab"] = tab
            break
        }
    }
    guard let row = found else {
        out["error"] = "no entry starting with \"\(name)\""
        return out
    }
    out["row"] = row.record

    guard AXUIElementPerformAction(row.element, "AXPress" as CFString) == .success else {
        out["error"] = "could not select the requested source row"
        restoreTab(original)
        return out
    }
    Thread.sleep(forTimeInterval: 2.5)

    let infoButtons = role("AXButton").filter { label($0) == "More Info" }
    guard infoButtons.count == 1, let info = infoButtons.first else {
        out["error"] = "no More Info button (entry may have no location)"
        restoreTab(original)
        return out
    }
    guard AXUIElementPerformAction(info, "AXPress" as CFString) == .success else {
        out["error"] = "could not open the requested detail"
        restoreTab(original)
        return out
    }
    Thread.sleep(forTimeInterval: 3.0)

    let popovers = role("AXPopover")
    guard popovers.count == 1, let popover = popovers.first else {
        out["error"] = "no unique scoped detail pane"
        restoreTab(original)
        return out
    }
    var detailLabels: [AXUIElement] = []
    findAll(popover, { sattr($0, "AXRole") == "AXStaticText" }, &detailLabels)
    let texts = detailLabels.map(label).filter { !$0.isEmpty }
    if let addr = pickAddress(texts) {
        let clean = addr.replacingOccurrences(of: "  ", with: " ")
        out["address"] = clean
        if wantGeocode, let (lat, lon) = geocode(clean) {
            out["latitude"] = lat
            out["longitude"] = lon
        }
    } else {
        out["error"] = "no street address shown (Find My may report Unknown Location)"
    }
    out["detail_texts"] = texts

    // Leave the UI as we found it - a left-open popover breaks the next read.
    AXUIElementPerformAction(popover, "AXCancel" as CFString)
    Thread.sleep(forTimeInterval: 0.8)
    restoreTab(original)
    return out
}

// MARK: - Run

let iso = ISO8601DateFormatter()
func warn(_ message: String) { FileHandle.standardError.write("findmy: \(message)\n".data(using: .utf8)!) }

/// Snapshot the wanted tabs, each enumerated to the end of its list.
func snapshot(_ wanted: [String]) -> [String: Any] {
    var result: [String: Any] = ["fetched_at": iso.string(from: Date())]
    let original = selectedTab()
    var bad: [String] = []
    var prev: [String] = []
    for tab in wanted {
        var got = selectTab(tab, previousRows: prev)
        if got == nil {
            // Back-to-back invocations can catch the UI mid-transition. Bounce
            // to another tab to force a clean re-render, then try once more.
            if let other = TABS.first(where: { $0 != tab }), let t = tabNamed(other) {
                AXUIElementPerformAction(t, "AXPress" as CFString)
                Thread.sleep(forTimeInterval: 1.5)
            }
            got = selectTab(tab, previousRows: [])
        }
        guard got != nil else {
            bad.append(tab)
            result[tab.lowercased()] = []
            continue
        }
        if tab == "People" { wakeIfPaused() }
        // A list that reorders mid-scroll fails the overlap proof; read it once more.
        var listing = enumerateList()
        if !listing.complete { listing = enumerateList() }
        if !listing.complete { bad.append(tab) }
        result[tab.lowercased()] = listing.rows.map(\.record)
        prev = sourceRows().map(\.text)
    }
    result["coverage"] = ["scope": "full_list", "complete": bad.isEmpty]
    result["incomplete"] = bad
    // Never let an unread tab pass as "nothing to report".
    if !bad.isEmpty { warn("could not prove every row was read in tab(s): \(bad.joined(separator: ", "))") }
    restoreTab(original)
    return result
}

// MARK: - Collect

/// stdout of `/bin/sh -c command`, trimmed; nil when it fails. The token
/// command's output is never logged.
func shell(_ command: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    let out = Pipe()
    process.standardOutput = out
    do { try process.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// POST one record verbatim; nil on success, else the reason.
func append(_ body: Data, to url: URL, token: String) -> String? {
    var request = URLRequest(url: url, timeoutInterval: 30)
    request.httpMethod = "POST"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = body
    let done = DispatchSemaphore(value: 0)
    var failure: String?
    URLSession.shared.dataTask(with: request) { data, response, error in
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if let error { failure = error.localizedDescription }
        else if !(200..<300).contains(status) {
            failure = "HTTP \(status) \(String(decoding: (data ?? Data()).prefix(200), as: UTF8.self))"
        }
        done.signal()
    }.resume()
    done.wait()
    return failure
}

/// One collection: enumerate People, resolve rows through the handle map and
/// append one record per resolved row. Prints one summary line (counts and the
/// displayed-age histogram, never identities) and returns the exit code.
var lastStaleRestart: Date?
func collectOnce(_ url: URL, tokenCommand: String, handlesPath: String) -> Int32 {
    var summary: [String: Any] = ["at": iso.string(from: Date()), "stream": streamName]
    defer { print(String(decoding: recordJSON(summary), as: UTF8.self)); fflush(stdout) }
    guard let data = FileManager.default.contents(atPath: handlesPath),
          let handles = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] else {
        summary["error"] = "handle map unreadable: \(handlesPath)"
        return 64
    }
    let snap: [String: Any]
    do { snap = try withUILock { try prepare(); return snapshot(["People"]) } } catch {
        let failure = error as! Failure
        summary["error"] = failure.message
        return failure.code
    }
    let complete = (snap["incomplete"] as? [String])?.isEmpty ?? false
    let rows = snap["people"] as? [[String: Any]] ?? []
    let checks = cityChecks(rows, handles: handles, complete: complete)
    summary["rows"] = checks.rows
    summary["unresolved"] = checks.unresolved
    summary["complete"] = complete
    summary["ages"] = Dictionary(grouping: rows) { ($0["when"] ?? $0["source_state"]) as? String ?? "none" }
        .mapValues(\.count)
    guard let token = shell(tokenCommand), !token.isEmpty else {
        summary["error"] = "token command failed"
        return 65
    }
    var appended = 0
    for record in checks.records {
        if let failure = append(recordJSON(record), to: url, token: token) {
            summary["error"] = "append failed: \(failure)"
            break
        }
        appended += 1
    }
    summary["appended"] = appended
    // Opt-in self-heal: the next run reads a refreshed list. Hourly at most, so
    // friends who genuinely stopped updating do not cause a restart loop.
    if allowRepair && staleView(checks.records, threshold: 1200)
        && lastStaleRestart.map({ Date().timeIntervalSince($0) >= 3600 }) ?? true {
        lastStaleRestart = Date()
        withUILock { restartFindMy() }
        summary["restarted"] = "stale"
    }
    if appended < checks.records.count { return 6 }
    return complete ? 0 : 5
}

var result: [String: Any] = [:]
switch mode {
case "collect":
    guard let hub = hubURL.flatMap(URL.init(string:)), let tokenCmd, let handlesPath, every >= 0,
          streamName.range(of: #"^[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) != nil else {
        die("collect needs --hub URL, --token-cmd CMD and --handles FILE "
            + "(optional --stream NAME, --every SECONDS >= 0)", 64)
    }
    let url = hub.appendingPathComponent("v1/streams/\(streamName)/append")
    while true {
        let code = collectOnce(url, tokenCommand: tokenCmd, handlesPath: handlesPath)
        if every == 0 { exit(code) }
        Thread.sleep(forTimeInterval: TimeInterval(every))
    }
default:
    do {
        result = try withUILock {
            try prepare()
            return mode == "detail"
                ? ["fetched_at": iso.string(from: Date()), "detail": detail(detailName)]
                : snapshot(mode == "all" ? TABS : TABS.filter { $0.lowercased() == mode })
        }
    } catch { let f = error as! Failure; die(f.message, f.code) }
}

// MARK: - Output

if wantText {
    if let d = result["detail"] as? [String: Any] {
        print(d["query"] as? String ?? "")
        if let r = d["row"] as? [String: Any] { print("  \(r["raw"] as? String ?? "")") }
        if let a = d["address"] as? String { print("  address: \(a)") }
        if let la = d["latitude"] as? Double, let lo = d["longitude"] as? Double {
            print("  coords:  \(la), \(lo)")
        }
        if let e = d["error"] as? String { print("  error:   \(e)") }
    } else {
        for tab in TABS {
            guard let rs = result[tab.lowercased()] as? [[String: Any]], !rs.isEmpty else { continue }
            print("\(tab):")
            for r in rs { print("  \(r["raw"] as? String ?? "")") }
        }
    }
} else {
    let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}

if let inc = result["incomplete"] as? [String], !inc.isEmpty { exit(5) }
