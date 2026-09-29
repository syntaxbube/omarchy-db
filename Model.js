// Pure helpers for the SBB plugin. No QML, no network: everything here takes
// raw strings or plain objects and returns plain objects, so the whole file
// can be exercised from `node tests/model.test.js`.
//
// Data source: https://transport.opendata.ch (free, no API key). All
// timestamps it returns are Unix seconds; delays are whole minutes.

var API = "https://transport.opendata.ch/v1"

// Categories drawn as a neutral badge instead of the rail red one:
// S-Bahn, regional and night services, buses, trams, boats.
var LOCAL_CATEGORIES = ["S", "SN", "R", "RE", "B", "BUS", "NFB", "T", "TRAM", "NFT", "BAT", "FUN", "PB"]

function trim(value) {
  return String(value === undefined || value === null ? "" : value).replace(/^\s+|\s+$/g, "")
}

function pad2(n) {
  return (n < 10 ? "0" : "") + n
}

// Accent and case insensitive key, so "zurich hb" matches "Zürich HB".
// Written out by hand because String.prototype.normalize is not reliable in
// every QML JS engine build.
function foldKey(value) {
  var map = { "ä": "a", "à": "a", "â": "a", "á": "a", "ö": "o", "ô": "o", "ó": "o",
              "ü": "u", "ù": "u", "û": "u", "ú": "u", "é": "e", "è": "e", "ê": "e",
              "ë": "e", "ï": "i", "î": "i", "í": "i", "ç": "c", "ñ": "n" }
  var s = trim(value).toLowerCase()
  var out = ""
  for (var i = 0; i < s.length; i++) out += map[s[i]] !== undefined ? map[s[i]] : s[i]
  return out.replace(/\s+/g, " ")
}

// ---- URLs ------------------------------------------------------------------

function stationboardUrl(station, limit) {
  return API + "/stationboard?station=" + encodeURIComponent(trim(station))
    + "&limit=" + Math.max(1, Math.min(40, parseInt(limit, 10) || 10))
}

// `when` is optional Unix seconds; without it the API searches from now.
// `max` caps the limit: 10 for route searches, 16 (the API's own cap) for
// the board when it follows a route.
function connectionsUrl(from, to, limit, when, max) {
  var url = API + "/connections?from=" + encodeURIComponent(trim(from))
    + "&to=" + encodeURIComponent(trim(to))
    + "&limit=" + Math.max(1, Math.min(max || 10, parseInt(limit, 10) || 5))
  if (when) {
    var d = new Date(when * 1000)
    url += "&date=" + d.getFullYear() + "-" + pad2(d.getMonth() + 1) + "-" + pad2(d.getDate())
      + "&time=" + pad2(d.getHours()) + ":" + pad2(d.getMinutes())
  }
  return url
}

// ---- Response limits -------------------------------------------------------
// Every outside command runs behind a byte cap so a stalled or oversized
// response can never grow the long-lived shell's memory: curl gives up past
// the limit, and `head -c` stops reading one byte after it whatever the
// producer does. That extra byte is how withinLimit spots an over-limit
// response, which is then dropped before any JSON parsing. The biggest real
// responses are about 300 KB (16 connections Kloten → Zermatt).
var LIMITS = { timetable: 1048576, stations: 65536, binds: 524288 }

function cappedCommand(argv, limit) {
  return ["sh", "-c", 'limit="$1"; shift; "$@" | head -c "$limit"', "sbb-capped", String(limit + 1)].concat(argv)
}

function curlCommand(url, limit, seconds) {
  return cappedCommand(["curl", "-sS", "--max-time", String(seconds || 8), "--max-filesize", String(limit), url], limit)
}

function utf8Length(text) {
  var s = String(text === undefined || text === null ? "" : text)
  var n = 0
  for (var i = 0; i < s.length; i++) {
    var c = s.charCodeAt(i)
    if (c < 0x80) n += 1
    else if (c < 0x800) n += 2
    else if (c >= 0xd800 && c <= 0xdbff) { n += 4; i++ }
    else n += 3
  }
  return n
}

function withinLimit(text, limit) {
  return utf8Length(text) <= limit
}

function locationsUrl(query) {
  return API + "/locations?type=station&query=" + encodeURIComponent(trim(query))
}

// ---- Time ------------------------------------------------------------------

// "2026-09-29T16:46:00+0200" → Unix seconds. The API omits the colon in the
// offset, which some Date parsers reject, so it is added back first.
function isoToSeconds(value) {
  var s = trim(value)
  if (!s) return null
  s = s.replace(/([+-]\d\d)(\d\d)$/, "$1:$2")
  var ms = Date.parse(s)
  return isNaN(ms) ? null : Math.round(ms / 1000)
}

function clock(seconds) {
  if (seconds === null || seconds === undefined || isNaN(seconds)) return "--:--"
  var d = new Date(seconds * 1000)
  return pad2(d.getHours()) + ":" + pad2(d.getMinutes())
}

// "00d00:49:00" → 49
function durationMinutes(value) {
  var m = /^(\d+)d(\d\d):(\d\d)/.exec(trim(value))
  if (!m) return null
  return parseInt(m[1], 10) * 1440 + parseInt(m[2], 10) * 60 + parseInt(m[3], 10)
}

function formatDuration(minutes) {
  if (minutes === null || minutes === undefined || isNaN(minutes)) return ""
  if (minutes < 60) return minutes + " min"
  return Math.floor(minutes / 60) + " h " + pad2(minutes % 60)
}

// Offsets offered by the "now ▾" picker in the route search, in minutes.
var WHEN_OFFSETS = [0, 15, 30, 60, 120]

function whenLabel(offset) {
  var m = parseInt(offset, 10) || 0
  if (m <= 0) return "now"
  if (m < 60) return "in " + m + " min"
  return "in " + Math.floor(m / 60) + " h" + (m % 60 ? " " + pad2(m % 60) : "")
}

// ---- Lines -----------------------------------------------------------------

// The API puts the line in `number` ("70" for IR 70, "2" for S2) but for some
// services it is the train number instead ("1776"), which nobody reads off a
// departure board. Long numbers are dropped and only the category is shown.
function lineLabel(category, number) {
  var cat = trim(category)
  var num = trim(number)
  if (!cat) return num
  if (!num || num.length > 3) return cat
  var tight = cat === "S" || cat === "SN"
  return cat + (tight ? "" : " ") + num
}

function isLocalCategory(category) {
  return LOCAL_CATEGORIES.indexOf(trim(category).toUpperCase()) !== -1
}

// ---- Departures ------------------------------------------------------------

function delayOf(stop) {
  if (!stop) return 0
  var d = parseInt(stop.delay, 10)
  if (!isNaN(d)) return Math.max(0, d)
  var planned = parseInt(stop.departureTimestamp, 10)
  var expected = stop.prognosis ? isoToSeconds(stop.prognosis.departure) : null
  if (!isNaN(planned) && expected !== null) return Math.max(0, Math.round((expected - planned) / 60))
  return 0
}

// The v1 API has no stable cancellation flag; some responses carry one on the
// journey or the stop, so both are checked and anything else counts as running.
function isCancelled(entry) {
  if (!entry) return false
  if (entry.cancelled === true || entry.isCancelled === true) return true
  var stop = entry.stop || entry
  return stop.cancelled === true || stop.isCancelled === true
}

function parseDepartures(raw) {
  var data
  try {
    data = typeof raw === "string" ? JSON.parse(raw) : raw
  } catch (e) {
    return { ok: false, station: "", departures: [], error: "Could not read the timetable" }
  }
  if (!data || !data.stationboard) {
    var msg = data && data.errors && data.errors[0] && data.errors[0].message
    return { ok: false, station: "", departures: [], error: msg ? String(msg) : "Unknown station" }
  }

  var out = []
  for (var i = 0; i < data.stationboard.length; i++) {
    var e = data.stationboard[i]
    if (!e || !e.stop) continue
    var ts = parseInt(e.stop.departureTimestamp, 10)
    if (isNaN(ts)) continue

    var planned = trim(e.stop.platform)
    var prognosed = e.stop.prognosis ? trim(e.stop.prognosis.platform) : ""
    var via = []
    var stops = []
    var pass = e.passList || []
    for (var p = 1; p < pass.length; p++) {
      if (!pass[p] || !pass[p].station || !pass[p].station.name) continue
      var name = String(pass[p].station.name)
      var stopTs = parseInt(pass[p].arrivalTimestamp, 10)
      if (isNaN(stopTs)) stopTs = parseInt(pass[p].departureTimestamp, 10)
      via.push(name)
      stops.push({ name: name, time: isNaN(stopTs) ? "" : clock(stopTs), platform: trim(pass[p].platform) })
    }

    out.push({
      id: trim(e.name) + "@" + ts,
      ts: ts,
      time: clock(ts),
      line: lineLabel(e.category, e.number),
      category: trim(e.category),
      local: isLocalCategory(e.category),
      to: trim(e.to),
      via: via,
      stops: stops,
      platform: prognosed || planned,
      plannedPlatform: planned,
      platformChanged: prognosed !== "" && planned !== "" && prognosed !== planned,
      delay: delayOf(e.stop),
      cancelled: isCancelled(e)
    })
  }

  var station = data.station && data.station.name ? String(data.station.name) : ""
  return { ok: true, station: station, departures: out, error: "" }
}

// "departures · next 30 min": how far ahead the fetched board reaches.
function boardSpan(deps, nowSeconds) {
  if (!deps || deps.length === 0) return ""
  var last = deps[deps.length - 1]
  var m = Math.round((last.ts + last.delay * 60 - nowSeconds) / 60)
  return m > 0 ? "next " + formatDuration(m) : ""
}

// Departure time including the delay, e.g. 16:46 for the 16:42 at +4'.
function expectedTime(dep) {
  if (!dep) return ""
  return clock(dep.ts + (dep.delay || 0) * 60)
}

function status(dep) {
  if (!dep) return "none"
  if (dep.cancelled) return "cancelled"
  if (dep.delay > 0) return "delayed"
  return "ontime"
}

function statusText(dep) {
  var s = status(dep)
  if (s === "cancelled") return "cancelled"
  if (s === "delayed") return "+" + dep.delay + "'"
  if (s === "ontime") return "on time"
  return ""
}

// Minutes until the train actually leaves, delay included.
function minutesUntil(dep, nowSeconds) {
  if (!dep) return null
  return Math.floor((dep.ts + dep.delay * 60 - nowSeconds) / 60)
}

function servesDestination(dep, destination) {
  var want = foldKey(destination)
  if (!want) return true
  if (foldKey(dep.to).indexOf(want) !== -1) return true
  for (var i = 0; i < dep.via.length; i++) {
    if (foldKey(dep.via[i]).indexOf(want) !== -1) return true
  }
  return false
}

// The departure the bar pill follows: the first one that has not left yet,
// optionally limited to trains serving `destination`. Cancelled trains are
// kept so the pill can warn about them.
function nextDeparture(deps, destination, nowSeconds) {
  for (var i = 0; i < (deps || []).length; i++) {
    var d = deps[i]
    if (minutesUntil(d, nowSeconds) < 0) continue
    if (servesDestination(d, destination)) return d
  }
  return null
}

// Right hand part of the bar pill: countdown, delay or "cancelled".
function barTail(dep, nowSeconds) {
  if (!dep) return ""
  var s = status(dep)
  if (s === "cancelled") return "cancelled"
  if (s === "delayed") return "+" + dep.delay + "'"
  var m = minutesUntil(dep, nowSeconds)
  return m <= 0 ? "now" : (m < 60 ? "in " + m + " min" : "")
}

function barText(dep, compact, nowSeconds) {
  if (!dep) return ""
  var tail = barTail(dep, nowSeconds)
  var head = compact ? dep.time : dep.line + " → " + dep.to + " " + dep.time
  return tail ? head + " · " + tail : head
}

// A departure is worth a notification once per trip, and only when the delay
// reaches the threshold or the train is cancelled. `threshold` 0 turns it off.
function alertFor(dep, threshold, alreadySent) {
  var limit = parseInt(threshold, 10) || 0
  if (!dep || limit <= 0) return null
  var sent = alreadySent || {}
  if (dep.cancelled) {
    var ck = dep.id + ":cancelled"
    if (sent[ck]) return null
    return { key: ck, title: dep.line + " to " + dep.to + " cancelled",
             body: "The " + dep.time + " departure will not run." }
  }
  if (dep.delay < limit) return null
  var key = dep.id + ":" + dep.delay
  if (sent[key]) return null
  return { key: key, title: dep.line + " to " + dep.to + " +" + dep.delay + "'",
           body: "Planned " + dep.time + ", now leaving at " + clock(dep.ts + dep.delay * 60)
                 + (dep.platform ? " from platform " + dep.platform : "") + "." }
}

// ---- Connections -----------------------------------------------------------

function sectionLines(connection) {
  var lines = []
  var sections = connection.sections || []
  for (var i = 0; i < sections.length; i++) {
    var j = sections[i] && sections[i].journey
    if (!j) continue
    lines.push({ label: lineLabel(j.category, j.number), local: isLocalCategory(j.category) })
  }
  if (lines.length === 0) {
    var products = connection.products || []
    for (var k = 0; k < products.length; k++) {
      var parts = /^([A-Za-z]+)\s*(\d*)$/.exec(trim(products[k]))
      lines.push(parts
        ? { label: lineLabel(parts[1], parts[2]), local: isLocalCategory(parts[1]) }
        : { label: trim(products[k]), local: false })
    }
  }
  return lines
}

function stopName(stop) {
  if (!stop) return ""
  if (stop.station && stop.station.name) return String(stop.station.name)
  if (stop.location && stop.location.name) return String(stop.location.name)
  return ""
}

function stopPlatform(stop) {
  if (!stop) return ""
  var prognosed = stop.prognosis ? trim(stop.prognosis.platform) : ""
  return prognosed || trim(stop.platform)
}

// Every leg of a connection for the details view: rides with their line,
// times and platforms, and the walks between them.
function sectionLegs(connection) {
  var legs = []
  var sections = connection.sections || []
  for (var i = 0; i < sections.length; i++) {
    var s = sections[i]
    if (!s) continue
    var dep = s.departure || {}
    var arr = s.arrival || {}
    var depTs = parseInt(dep.departureTimestamp, 10)
    var arrTs = parseInt(arr.arrivalTimestamp, 10)
    if (s.journey) {
      legs.push({
        kind: "ride",
        line: lineLabel(s.journey.category, s.journey.number),
        local: isLocalCategory(s.journey.category),
        toward: trim(s.journey.to),
        from: stopName(dep),
        to: stopName(arr),
        depTime: isNaN(depTs) ? "" : clock(depTs),
        arrTime: isNaN(arrTs) ? "" : clock(arrTs),
        depPlatform: stopPlatform(dep),
        arrPlatform: stopPlatform(arr),
        delay: delayOf(dep)
      })
    } else if (s.walk) {
      var secs = parseInt(s.walk.duration, 10)
      var mins = !isNaN(secs) ? Math.round(secs / 60)
        : (!isNaN(depTs) && !isNaN(arrTs) ? Math.round((arrTs - depTs) / 60) : null)
      legs.push({ kind: "walk", minutes: mins, from: stopName(dep), to: stopName(arr) })
    }
  }
  return legs
}

function parseConnections(raw) {
  var data
  try {
    data = typeof raw === "string" ? JSON.parse(raw) : raw
  } catch (e) {
    return { ok: false, connections: [], error: "Could not read the connections" }
  }
  if (!data || !data.connections) {
    var msg = data && data.errors && data.errors[0] && data.errors[0].message
    return { ok: false, connections: [], error: msg ? String(msg) : "No connections found" }
  }

  var out = []
  for (var i = 0; i < data.connections.length; i++) {
    var c = data.connections[i]
    if (!c || !c.from || !c.to) continue
    var dep = parseInt(c.from.departureTimestamp, 10)
    var arr = parseInt(c.to.arrivalTimestamp, 10)
    var mins = durationMinutes(c.duration)
    var transfers = parseInt(c.transfers, 10) || 0
    var prognosed = c.from.prognosis ? trim(c.from.prognosis.platform) : ""
    out.push({
      id: dep + ":" + i,
      depTs: dep,
      depTime: clock(dep),
      arrTime: clock(arr),
      duration: formatDuration(mins !== null ? mins : Math.round((arr - dep) / 60)),
      changes: transfers === 0 ? "direct" : transfers + (transfers === 1 ? " change" : " changes"),
      lines: sectionLines(c),
      legs: sectionLegs(c),
      fromName: stopName(c.from),
      toName: stopName(c.to),
      platform: prognosed || trim(c.from.platform),
      delay: delayOf(c.from),
      cancelled: isCancelled(c.from)
    })
  }
  return { ok: true, connections: out, error: out.length ? "" : "No connections found" }
}

// The bar and board can follow a route instead of the home station. Each
// connection becomes a departure-shaped entry, so the pill, the board and the
// delay alerts treat both the same. The id leaves out the list position,
// which shifts as trains leave, so alerts and the followed row stay put.
// `destination` names the stop when the API leaves the arrival unnamed.
function connectionDepartures(connections, destination) {
  var out = []
  for (var i = 0; i < (connections || []).length; i++) {
    var c = connections[i]
    if (!c || isNaN(c.depTs)) continue
    var ride = null
    for (var k = 0; k < c.legs.length && !ride; k++) if (c.legs[k].kind === "ride") ride = c.legs[k]
    var first = c.lines[0] || { label: "", local: false }
    var line = ride ? ride.line : first.label
    out.push({
      id: "route:" + c.depTs + ":" + line,
      ts: c.depTs,
      time: c.depTime,
      line: line,
      local: ride ? ride.local : first.local,
      to: c.toName || trim(destination),
      via: [],
      stops: [],
      platform: c.platform,
      plannedPlatform: c.platform,
      platformChanged: false,
      delay: c.delay,
      cancelled: c.cancelled,
      arrTime: c.arrTime,
      changes: c.changes,
      connection: c
    })
  }
  return out
}

// ---- Stations & favourites -------------------------------------------------

function parseStations(raw) {
  try {
    var data = typeof raw === "string" ? JSON.parse(raw) : raw
    var list = (data && (data.stations || data.stops)) || []
    var seen = {}
    var out = []
    for (var i = 0; i < list.length && out.length < 6; i++) {
      var name = list[i] && list[i].name ? String(list[i].name) : ""
      if (!name || seen[name]) continue
      seen[name] = true
      out.push(name)
    }
    return out
  } catch (e) {
    return []
  }
}

// "Zürich HB > Luzern; Bern > Thun" → [{from, to}, ...]
function parseFavourites(value) {
  var out = []
  var chunks = trim(value).split(/[;\n]+/)
  for (var i = 0; i < chunks.length; i++) {
    var pair = chunks[i].split(/\s*(?:>|→|->)\s*/)
    if (pair.length !== 2) continue
    var from = trim(pair[0])
    var to = trim(pair[1])
    if (from && to) out.push({ from: from, to: to })
  }
  return out
}

function serializeFavourites(list) {
  var out = []
  for (var i = 0; i < (list || []).length; i++) out.push(list[i].from + " > " + list[i].to)
  return out.join("; ")
}

// Adds from → to unless it is already a favourite. Returns the new list and
// whether anything changed.
function addFavourite(list, from, to) {
  var f = trim(from)
  var t = trim(to)
  var current = (list || []).slice()
  if (!f || !t) return { list: current, added: false }
  for (var i = 0; i < current.length; i++) {
    if (foldKey(current[i].from) === foldKey(f) && foldKey(current[i].to) === foldKey(t))
      return { list: current, added: false }
  }
  current.push({ from: f, to: t })
  return { list: current, added: true }
}

function removeFavourite(list, index) {
  var current = (list || []).slice()
  if (index >= 0 && index < current.length) current.splice(index, 1)
  return current
}

// ---- Route query -----------------------------------------------------------
// The route search is one line: "zürich hb → luzern". ">" and "->" work as
// the arrow too. Without an arrow the text is the destination and the trip
// starts at the home station.

var ROUTE_SEP = /\s*(?:→|->|>)\s*/

function parseRouteQuery(text, home) {
  var s = String(text === undefined || text === null ? "" : text)
  var m = ROUTE_SEP.exec(s)
  if (!m) return { from: trim(home), to: trim(s), explicit: false }
  return { from: trim(s.slice(0, m.index)), to: trim(s.slice(m.index + m[0].length)), explicit: true }
}

function formatRoute(from, to) {
  return trim(from) + " → " + trim(to)
}

// Which half of the query the caret is in: "from" or "to".
function activeSegment(text, caret) {
  var s = String(text || "")
  var m = ROUTE_SEP.exec(s)
  if (!m) return "to"
  return caret <= m.index ? "from" : "to"
}

function segmentText(text, segment, home) {
  var q = parseRouteQuery(text, home)
  return segment === "from" ? q.from : q.to
}

// Puts a picked station into the half being typed.
function replaceSegment(text, segment, name) {
  var s = String(text || "")
  var m = ROUTE_SEP.exec(s)
  if (!m) return trim(name)
  var from = trim(s.slice(0, m.index))
  var to = trim(s.slice(m.index + m[0].length))
  return segment === "from" ? formatRoute(name, to) : formatRoute(from, name)
}

function swapRouteQuery(text, home) {
  var q = parseRouteQuery(text, home)
  if (!q.to) return String(text || "")
  return formatRoute(q.to, q.from)
}

// ---- Global shortcuts ------------------------------------------------------
// The plugin registers its own Hyprland shortcuts at runtime (hyprctl eval),
// skipping any key that something else already uses. Bindings it makes are
// described "SBB: …" so they can be told apart and cleaned up later.

var SHORTCUT_PREFIX = "SBB: "

var MODMASK = { SUPER: 64, WIN: 64, LOGO: 64, MOD4: 64, ALT: 8, MOD1: 8, CTRL: 4, CONTROL: 4, SHIFT: 1 }
var MOD_ORDER = [["SUPER", 64], ["CTRL", 4], ["ALT", 8], ["SHIFT", 1]]

// Omarchy binds some keys by X keycode ("code:10" is 1), so a clash check on
// key names alone misses them. US layout keycodes for digits and letters.
var KEYCODES = { "1": 10, "2": 11, "3": 12, "4": 13, "5": 14, "6": 15, "7": 16, "8": 17, "9": 18, "0": 19,
  q: 24, w: 25, e: 26, r: 27, t: 28, y: 29, u: 30, i: 31, o: 32, p: 33,
  a: 38, s: 39, d: 40, f: 41, g: 42, h: 43, j: 44, k: 45, l: 46,
  z: 52, x: 53, c: 54, v: 55, b: 56, n: 57, m: 58 }

// "super + alt + t" → { ok, mask: 72, key: "T", keys: "SUPER + ALT + T" }
function parseKeys(value) {
  var parts = trim(value).split("+")
  var key = trim(parts.pop())
  var mask = 0
  var mods = []
  for (var i = 0; i < parts.length; i++) {
    var mod = trim(parts[i]).toUpperCase()
    if (!MODMASK[mod]) return { ok: false }
    if ((mask & MODMASK[mod]) === 0) mods.push(mod === "CONTROL" ? "CTRL" : mod)
    mask |= MODMASK[mod]
  }
  if (!key || /\s/.test(key) || /["\\]/.test(key)) return { ok: false }
  if (key.length === 1) key = key.toUpperCase()
  mods.push(key)
  return { ok: true, mask: mask, key: key, keys: mods.join(" + ") }
}

// "SUPER + CTRL + ALT + 1" → "super+ctrl+alt+1", for labels.
function prettyKeys(value) {
  var p = parseKeys(value)
  if (!p.ok) return ""
  return p.keys.split(" + ").map(function(k) { return k.toLowerCase() }).join("+")
}

function keysFromBind(bind) {
  var mods = []
  for (var i = 0; i < MOD_ORDER.length; i++) if (bind.modmask & MOD_ORDER[i][1]) mods.push(MOD_ORDER[i][0])
  mods.push(String(bind.key))
  return mods.join(" + ")
}

function bindHitsKey(bind, parsed) {
  if (!bind || bind.modmask !== parsed.mask) return false
  var key = String(bind.key || "")
  if (key.toLowerCase() === parsed.key.toLowerCase()) return true
  var code = KEYCODES[parsed.key.toLowerCase()]
  return code !== undefined && key === "code:" + code
}

// Reads plain `hyprctl binds`. Not `hyprctl -j binds`: for Lua bindings on a
// keycode (Omarchy's super+alt+1..5) the JSON has an empty key, while the
// plain text says "SUPER + ALT + code:10".
function parsePlainBinds(text) {
  var out = []
  var cur = null
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (line !== "" && line[0] !== "\t" && line[0] !== " ") {
      cur = { modmask: 0, key: "", description: "", dispatcher: "" }
      out.push(cur)
      continue
    }
    if (!cur) continue
    var m = /^\s+(\w+):\s?(.*)$/.exec(line)
    if (!m) continue
    if (m[1] === "modmask") cur.modmask = parseInt(m[2], 10) || 0
    else if (m[1] === "key") cur.key = trim(m[2].split(" + ").pop())
    else if (m[1] === "description") cur.description = trim(m[2])
    else if (m[1] === "dispatcher") cur.dispatcher = trim(m[2])
  }
  return out
}

// SBB bindings, whether the plugin made them or the user wrote them by hand
// from an older README, count as ours: the plugin may replace them.
function isOwnBind(bind) {
  return String(bind.description || "").indexOf("SBB") === 0
}

// The shortcuts the plugin wants. `cfg`: board, search, favourites (the
// modifiers for favourites 1 to 9).
function shortcutSpecs(pluginId, cfg) {
  // An empty key turns that shortcut off.
  var specs = []
  if (trim(cfg.board) !== "")
    specs.push({ keys: cfg.board, description: SHORTCUT_PREFIX + "departures", command: "omarchy-shell shell toggle " + pluginId + " '{}'" })
  if (trim(cfg.search) !== "")
    specs.push({ keys: cfg.search, description: SHORTCUT_PREFIX + "route search", command: "omarchy-shell " + pluginId + " toggleSearch" })
  if (trim(cfg.favourites) !== "") {
    for (var n = 1; n <= 9; n++)
      specs.push({ keys: trim(cfg.favourites) + " + " + n, description: SHORTCUT_PREFIX + "favourite route " + n,
                   command: "omarchy-shell " + pluginId + " favourite " + n, favourite: n })
  }
  return specs
}

// Decides what to bind given parsePlainBinds(`hyprctl binds`). Returns the specs to bind
// (with canonical keys), the ones skipped because the key is taken (with the
// owner's description), invalid ones, and stale plugin bindings to remove.
function planShortcuts(binds, specs) {
  var list = binds || []
  var bind = []
  var skipped = []
  var invalid = []
  for (var i = 0; i < specs.length; i++) {
    var spec = specs[i]
    var parsed = parseKeys(spec.keys)
    if (!parsed.ok) {
      invalid.push(spec)
      continue
    }
    var owner = null
    for (var j = 0; j < list.length; j++) {
      if (bindHitsKey(list[j], parsed) && !isOwnBind(list[j])) {
        owner = String(list[j].description || list[j].dispatcher || "another shortcut")
        break
      }
    }
    var entry = { keys: parsed.keys, mask: parsed.mask, key: parsed.key, description: spec.description,
                  command: spec.command, favourite: spec.favourite || 0 }
    if (owner) {
      entry.owner = owner
      skipped.push(entry)
    } else {
      bind.push(entry)
    }
  }
  var stale = []
  for (var s = 0; s < list.length; s++) {
    var b = list[s]
    if (String(b.description || "").indexOf(SHORTCUT_PREFIX) !== 0) continue
    var kept = false
    for (var k = 0; k < bind.length; k++) {
      if (bindHitsKey(b, bind[k])) { kept = true; break }
    }
    var keys = keysFromBind(b)
    if (!kept && stale.indexOf(keys) === -1) stale.push(keys)
  }
  return { bind: bind, skipped: skipped, invalid: invalid, stale: stale }
}

function luaString(value) {
  return '"' + String(value).replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"'
}

// One Lua chunk for hyprctl eval. Every key is unbound before it is bound, so
// running it twice (two monitors, a reload) never doubles a shortcut.
function shortcutsLua(plan) {
  var out = []
  for (var i = 0; i < plan.stale.length; i++) out.push("hl.unbind(" + luaString(plan.stale[i]) + ")")
  for (var j = 0; j < plan.bind.length; j++) {
    var b = plan.bind[j]
    out.push("hl.unbind(" + luaString(b.keys) + ")")
    out.push("hl.bind(" + luaString(b.keys) + ", hl.dsp.exec_cmd(" + luaString(b.command) + "), { description = "
      + luaString(b.description) + " })")
  }
  return out.join("\n")
}

// Removes shortcuts the plugin registered, for when it goes away.
function unbindLua(bound) {
  var out = []
  for (var i = 0; i < (bound || []).length; i++) out.push("hl.unbind(" + luaString(bound[i].keys) + ")")
  return out.join("\n")
}

if (typeof module !== "undefined") {
  module.exports = {
    foldKey: foldKey, stationboardUrl: stationboardUrl, LIMITS: LIMITS, cappedCommand: cappedCommand,
    curlCommand: curlCommand, utf8Length: utf8Length, withinLimit: withinLimit, connectionsUrl: connectionsUrl,
    locationsUrl: locationsUrl, isoToSeconds: isoToSeconds, clock: clock,
    durationMinutes: durationMinutes, formatDuration: formatDuration, lineLabel: lineLabel,
    isLocalCategory: isLocalCategory, parseDepartures: parseDepartures, status: status,
    statusText: statusText, minutesUntil: minutesUntil, servesDestination: servesDestination,
    nextDeparture: nextDeparture, barTail: barTail, barText: barText, alertFor: alertFor,
    parseConnections: parseConnections, parseStations: parseStations,
    parseFavourites: parseFavourites, serializeFavourites: serializeFavourites,
    addFavourite: addFavourite, removeFavourite: removeFavourite,
    parseRouteQuery: parseRouteQuery, formatRoute: formatRoute, activeSegment: activeSegment,
    segmentText: segmentText, replaceSegment: replaceSegment, swapRouteQuery: swapRouteQuery,
    boardSpan: boardSpan, connectionDepartures: connectionDepartures, expectedTime: expectedTime, sectionLegs: sectionLegs,
    whenLabel: whenLabel, WHEN_OFFSETS: WHEN_OFFSETS,
    parseKeys: parseKeys, prettyKeys: prettyKeys, shortcutSpecs: shortcutSpecs,
    planShortcuts: planShortcuts, shortcutsLua: shortcutsLua, parsePlainBinds: parsePlainBinds,
    unbindLua: unbindLua
  }
}
