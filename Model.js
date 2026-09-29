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
function connectionsUrl(from, to, limit, when) {
  var url = API + "/connections?from=" + encodeURIComponent(trim(from))
    + "&to=" + encodeURIComponent(trim(to))
    + "&limit=" + Math.max(1, Math.min(10, parseInt(limit, 10) || 5))
  if (when) {
    var d = new Date(when * 1000)
    url += "&date=" + d.getFullYear() + "-" + pad2(d.getMonth() + 1) + "-" + pad2(d.getDate())
      + "&time=" + pad2(d.getHours()) + ":" + pad2(d.getMinutes())
  }
  return url
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

if (typeof module !== "undefined") {
  module.exports = {
    foldKey: foldKey, stationboardUrl: stationboardUrl, connectionsUrl: connectionsUrl,
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
    boardSpan: boardSpan, expectedTime: expectedTime, sectionLegs: sectionLegs,
    whenLabel: whenLabel, WHEN_OFFSETS: WHEN_OFFSETS
  }
}
