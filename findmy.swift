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
      findmy --selftest                   run parser self-checks

    OPTIONS
      --geocode        with `detail`, also resolve lat/lon (MapKit, local)
      --text           human-readable output instead of JSON
      --repair         if the UI is unreadable, restart Find My.
                       Off by default: relaunching makes the window
                       visibly appear on screen.
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

var mode = "all"
var detailName = ""
if let first = args.first {
    if first == "detail" {
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
    var fields = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    var row: [String: Any] = ["raw": raw]
    guard !fields.isEmpty else { return row }
    let name = fields.removeFirst()
    row["name"] = name
    if let key = sourceHandleKey(name) { row["source_handle_key"] = key }
    if let last = fields.last, rxMatch(distRE, last) { row["distance"] = last; fields.removeLast() }
    if let last = fields.last, last == "Paused" {
        row["source_state"] = "paused"
        fields.removeLast()
    } else if let last = fields.last, rxMatch(whenRE, last) {
        row["when"] = last
        fields.removeLast()
    }
    let loc = fields.joined(separator: ", ")
    if ["Address Unavailable", "No location found", "Location Not Available"].contains(loc) {
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
    let unavailable = parse("Person 2, No location found")
    assert(unavailable["source_state"] as? String == "unavailable")
    assert(unavailable["location"] == nil)
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
    // address picker
    assert(pickAddress(["Jane Doe", "1 Infinite Loop, Cupertino, CA  95014", "Live"])
           == "1 Infinite Loop, Cupertino, CA  95014")
    assert(pickAddress(["Jane Doe", "Cupertino, CA • Now"]) == nil)
    assert(norm("Sam\u{2019}s iPhone") == "sam's iphone")
    assert(norm("Sam\u{2019}s iPhone").hasPrefix(norm("Sam's iPh")))
    print("selftest ok (\(cases.count + 3) parse cases + source-handle keys + address picker)")
    exit(0)
}

// MARK: - Accessibility plumbing

guard AXIsProcessTrusted() else {
    die("no Accessibility permission. Grant it to this binary in "
        + "System Settings > Privacy & Security > Accessibility.", 2)
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

if findMyApp() == nil {
    if noLaunch { die("Find My is not running (--launch=no)", 3) }
    launchFindMy()
}
guard let app0 = findMyApp() else { die("could not launch Find My", 3) }

var axPid = app0.processIdentifier
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

func waitReady(timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        refreshAX()
        ensureWindow()
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

guard waitReady(timeout: 30) else {
    die("Find My UI never became readable. Is a display attached and the session "
        + "unlocked? Try --repair.", 4)
}
let originalTab = tabButtons().first { (attr($0, "AXValue") as? Int) == 1 }.map(label)

func restoreTab() {
    if let o = originalTab, !isSelected(o), let t = tabNamed(o) {
        AXUIElementPerformAction(t, "AXPress" as CFString)
    }
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
    guard #available(macOS 26.0, *), let req = MKGeocodingRequest(addressString: address) else { return nil }
    var result: (Double, Double)?
    req.getMapItems { items, _ in
        if let c = items?.first?.location.coordinate { result = (c.latitude, c.longitude) }
        CFRunLoopStop(CFRunLoopGetMain())
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 20) { CFRunLoopStop(CFRunLoopGetMain()) }
    CFRunLoopRun()
    return result
}

func detail(_ name: String) -> [String: Any] {
    var out: [String: Any] = ["query": name]

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
            restoreTab()
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
        restoreTab()
        return out
    }
    Thread.sleep(forTimeInterval: 2.5)

    let infoButtons = role("AXButton").filter { label($0) == "More Info" }
    guard infoButtons.count == 1, let info = infoButtons.first else {
        out["error"] = "no More Info button (entry may have no location)"
        restoreTab()
        return out
    }
    guard AXUIElementPerformAction(info, "AXPress" as CFString) == .success else {
        out["error"] = "could not open the requested detail"
        restoreTab()
        return out
    }
    Thread.sleep(forTimeInterval: 3.0)

    let popovers = role("AXPopover")
    guard popovers.count == 1, let popover = popovers.first else {
        out["error"] = "no unique scoped detail pane"
        restoreTab()
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
    restoreTab()
    return out
}

// MARK: - Run

let iso = ISO8601DateFormatter()
var result: [String: Any] = ["fetched_at": iso.string(from: Date())]

if mode == "detail" {
    result["detail"] = detail(detailName)
} else {
    let wanted = mode == "all" ? TABS : TABS.filter { $0.lowercased() == mode }
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
        if let got {
            prev = got.map(\.text)
            result[tab.lowercased()] = got.map(\.record)
        } else {
            bad.append(tab)
            result[tab.lowercased()] = []
        }
    }
    // ponytail: visible rows only; prove list exhaustion before claiming complete coverage.
    result["coverage"] = ["scope": "visible_only", "complete": false]
    result["incomplete"] = wanted
    FileHandle.standardError.write("findmy: visible rows only; list coverage is unverified\n".data(using: .utf8)!)
    if !bad.isEmpty {
        // Never let an unread tab pass as "nothing to report".
        FileHandle.standardError.write("findmy: could not read tab(s): \(bad.joined(separator: ", "))\n"
            .data(using: .utf8)!)
    }
    restoreTab()
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
