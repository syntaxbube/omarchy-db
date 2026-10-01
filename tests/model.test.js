// Run with: TZ=Europe/Berlin node tests/model.test.js
// Fixtures mirror v6.db.transport.rest's Deutsche Bahn/HAFAS response shape.

const Model = require("../Model.js")

let failures = 0
function check(name, actual, expected) {
  const ok = JSON.stringify(actual) === JSON.stringify(expected)
  if (!ok) {
    failures++
    console.log("FAIL " + name + "\n  expected " + JSON.stringify(expected) + "\n  got      " + JSON.stringify(actual))
  }
}

const iso = (hour, minute) => `2026-10-01T${String(hour).padStart(2, "0")}:${String(minute).padStart(2, "0")}:00+02:00`
const seconds = value => Date.parse(value) / 1000
const NOW = seconds(iso(10, 0))
const line = (name, product) => ({ type: "line", id: name.toLowerCase().replace(/ /g, "-"), name, product })
const stop = (name, id) => ({ type: "stop", id: id || name, name, location: { type: "location" } })

const departuresFixture = [
    {
      tripId: "1|ICE 507|20261001", stop: stop("Berlin Hbf", "8011160"),
      plannedWhen: iso(9, 58), when: iso(10, 3), delay: 300,
      plannedPlatform: "13", platform: "14", direction: "München Hbf",
      line: line("ICE 507", "nationalExpress"),
      stopovers: [
        { stop: stop("Berlin Hbf"), plannedDeparture: iso(9, 58), departure: iso(10, 3), departureDelay: 300, plannedPlatform: "13", platform: "14" },
        { stop: stop("Leipzig Hbf"), plannedArrival: iso(11, 8), arrival: iso(11, 13), arrivalDelay: 300, plannedPlatform: "10", platform: "11" },
        { stop: stop("München Hbf"), plannedArrival: iso(14, 2), arrival: iso(14, 7), arrivalDelay: 300, plannedPlatform: "22" }
      ]
    },
    {
      tripId: "2|IC 2270|20261001", stop: stop("Berlin Hbf"), plannedWhen: iso(10, 12), when: iso(10, 12), delay: 0,
      plannedPlatform: "8", platform: "8", direction: "Rostock Hbf", line: line("IC 2270", "national"), stopovers: []
    },
    {
      tripId: "3|EC 45|20261001", stop: stop("Berlin Hbf"), plannedWhen: iso(10, 18),
      plannedPlatform: "1", direction: "Warszawa Wschodnia", line: line("EC 45", "national"), cancelled: true
    },
    {
      tripId: "4|RE 8|20261001", stop: stop("Berlin Hbf"), plannedWhen: iso(10, 24), when: iso(10, 26), delay: 120,
      plannedPlatform: "6", direction: "Wittenberge", line: line("RE 8", "regional")
    },
    {
      tripId: "5|S 7|20261001", stop: stop("Berlin Hbf"), plannedWhen: iso(10, 29),
      direction: "Ahrensfelde", line: line("S 7", "suburban")
    },
    {
      tripId: "6|Bus M41|20261001", stop: stop("Berlin Hbf"), plannedWhen: iso(10, 33),
      plannedPlatform: null, platform: null, direction: "Sonnenallee", line: line("M41", "bus")
    }
]

const parsed = Model.parseDepartures(JSON.stringify(departuresFixture))
check("DB departures parse", parsed.ok, true)
check("departure station", parsed.station, "Berlin Hbf")
check("ICE, IC and EC labels", parsed.departures.slice(0, 3).map(d => d.line), ["ICE 507", "IC 2270", "EC 45"])
check("regional and local products", parsed.departures.slice(3).map(d => [d.line, d.local]), [["RE 8", true], ["S 7", true], ["M41", true]])
check("long-distance products", parsed.departures.slice(0, 3).map(d => d.local), [false, false, false])
const [ice, ic, ec, re, s7] = parsed.departures
check("planned departure retained", [ice.time, ice.ts], ["09:58", seconds(iso(9, 58))])
check("realtime departure produces minute delay", ice.delay, 5)
check("changed and planned platforms", [ice.platform, ice.plannedPlatform, ice.platformChanged], ["14", "13", true])
check("unchanged platform", [ic.platform, ic.platformChanged], ["8", false])
check("cancelled journey", ec.cancelled, true)
check("direction and stopovers", [ice.to, ice.via], ["München Hbf", ["Leipzig Hbf", "München Hbf"]])
check("realtime arrivals and changed stop platform", ice.stops, [
  { name: "Leipzig Hbf", time: "11:13", platform: "11" },
  { name: "München Hbf", time: "14:07", platform: "22" }
])
check("optional realtime fields may be absent", [s7.delay, s7.platform, s7.platformChanged], [0, "", false])
check("departure statuses", parsed.departures.slice(0, 5).map(Model.statusText), ["+5'", "on time", "cancelled", "+2'", "on time"])
check("next departure uses delayed realtime", Model.nextDeparture(parsed.departures, "Leipzig", NOW).line, "ICE 507")
check("destination filter includes stopovers", Model.servesDestination(ice, "munchen"), true)
check("expected departure", Model.expectedTime(ice), "10:03")
check("invalid departure JSON", Model.parseDepartures("<html>503</html>").error, "Could not read the timetable")
check("HTTP/API-style departure error", Model.parseDepartures({ error: true, msg: "station not found" }).error, "station not found")

const journeysFixture = {
  journeys: [{
    refreshToken: "refresh-ice-re", legs: [
      {
        origin: stop("Berlin Hbf"), destination: stop("Hannover Hbf"),
        plannedDeparture: iso(10, 15), departure: iso(10, 20), departureDelay: 300,
        plannedArrival: iso(12, 2), arrival: iso(12, 9), arrivalDelay: 420,
        plannedDeparturePlatform: "13", departurePlatform: "14",
        plannedArrivalPlatform: "7", arrivalPlatform: "8", direction: "Köln Hbf",
        line: line("ICE 1050", "nationalExpress"), cancelled: false,
        stopovers: [{ stop: stop("Stendal Hbf"), plannedArrival: iso(11, 2), arrival: iso(11, 7) }]
      },
      {
        walking: true, origin: stop("Hannover Hbf"), destination: stop("Hannover ZOB"),
        departure: iso(12, 9), arrival: iso(12, 16)
      },
      {
        origin: stop("Hannover ZOB"), destination: stop("Bremen Hbf"),
        plannedDeparture: iso(12, 22), plannedArrival: iso(13, 35),
        plannedDeparturePlatform: "A", direction: "Bremerhaven-Lehe", line: line("RE 8", "regional")
      }
    ]
  }, {
    legs: [{ origin: stop("Berlin Hbf"), destination: stop("Dresden Hbf"), plannedDeparture: iso(11, 0), plannedArrival: iso(12, 50),
      direction: "Praha hl.n.", line: line("EC 175", "national"), cancelled: true }]
  }]
}
const connections = Model.parseConnections(journeysFixture)
check("journeys parse", connections.ok, true)
check("connection planned times and duration", [connections.connections[0].depTime, connections.connections[0].arrTime, connections.connections[0].duration], ["10:15", "13:35", "3 h 20"])
check("transfer count ignores walking leg", connections.connections[0].changes, "1 change")
check("ride, walk and transfer legs", connections.connections[0].legs.map(l => l.kind), ["ride", "walk", "ride"])
check("walking duration", connections.connections[0].legs[1].minutes, 7)
check("leg planned/realtime platform and delay", [connections.connections[0].legs[0].depPlatform, connections.connections[0].legs[0].arrPlatform, connections.connections[0].legs[0].delay], ["14", "8", 5])
check("connection products", connections.connections[0].lines.map(l => [l.label, l.local]), [["ICE 1050", false], ["RE 8", true]])
check("connection endpoints", [connections.connections[0].fromName, connections.connections[0].toName], ["Berlin Hbf", "Bremen Hbf"])
check("cancelled connection leg", connections.connections[1].legs[0].cancelled, true)
check("invalid journey JSON", Model.parseConnections("not json").error, "Could not read the connections")
check("HTTP/API-style journey error", Model.parseConnections({ error: "HAFAS request failed" }).error, "HAFAS request failed")

check("autocomplete deduplicates station names", Model.parseStations([
  stop("Berlin Hbf", "8011160"), stop("Berlin Hbf", "duplicate"), stop("berlin hbf", "case-duplicate"),
  { type: "location", name: "Berlin Hbf, Europaplatz" }, stop("Berlin Ostbahnhof", "8010255")
]), ["Berlin Hbf", "Berlin Ostbahnhof"])
check("autocomplete invalid JSON", Model.parseStations("{"), [])

check("departure URL encoding/options/limit", Model.stationboardUrl("Köln Hbf", 99),
  "https://v6.db.transport.rest/departures?stop=K%C3%B6ln%20Hbf&results=40&duration=1440&linesOfStops=true&remarks=false&language=en&nationalExpress=true&national=true&regionalExpress=true&regional=true&suburban=true&bus=true&ferry=true&subway=true&tram=true&taxi=false")
check("autocomplete URL encoding/options", Model.locationsUrl("München Hbf"),
  "https://v6.db.transport.rest/locations?query=M%C3%BCnchen%20Hbf&results=6&stops=true&addresses=false&poi=false&language=en")
const transportOptions = "&nationalExpress=true&national=true&regionalExpress=true&regional=true&suburban=true&bus=true&ferry=true&subway=true&tram=true&taxi=false"
check("journey URL encoding/result limit/language/transports", Model.connectionsUrl("Köln Hbf", "Frankfurt(Main)Hbf", 14),
  "https://v6.db.transport.rest/journeys?from=K%C3%B6ln%20Hbf&to=Frankfurt(Main)Hbf&results=10&stopovers=true&remarks=false&language=en" + transportOptions)
check("journey ISO date/time", Model.connectionsUrl("Berlin Hbf", "Leipzig Hbf", 5, seconds(iso(10, 30))),
  "https://v6.db.transport.rest/journeys?from=Berlin%20Hbf&to=Leipzig%20Hbf&results=5&departure=2026-10-01T08%3A30%3A00.000Z&stopovers=true&remarks=false&language=en" + transportOptions)
check("followed-board result limit", /results=16&/.test(Model.connectionsUrl("A", "B", 20, 0, 16)), true)

const route = Model.connectionDepartures(connections.connections, "Bremen Hbf")
check("route departure maps first ride", [route[0].line, route[0].to, route[0].delay], ["ICE 1050", "Bremen Hbf", 5])
check("route works with bar", Model.barText(route[0], false, NOW), "ICE 1050 → Bremen Hbf 10:15 · +5'")

check("favourites", Model.parseFavourites("Berlin Hbf > Leipzig Hbf; Köln Hbf → Bonn Hbf"), [
  { from: "Berlin Hbf", to: "Leipzig Hbf" }, { from: "Köln Hbf", to: "Bonn Hbf" }
])
check("route query", Model.parseRouteQuery("Berlin Hbf → Hamburg Hbf", "Köln Hbf"), { from: "Berlin Hbf", to: "Hamburg Hbf", explicit: true })
check("German clock timezone", Model.clock(seconds(iso(10, 30))), "10:30")

const cfg = { board: "SUPER + ALT + T", search: "SUPER + ALT + R", favourites: "SUPER + CTRL + ALT" }
const specs = Model.shortcutSpecs("vvkycodevv.db", cfg)
check("eleven DB shortcuts", specs.length, 11)
check("DB board command", specs[0].command, "omarchy-shell shell toggle vvkycodevv.db '{}'")
check("DB favourite command", specs[2].command, "omarchy-shell vvkycodevv.db favourite 1")
check("DB shortcut branding", specs.slice(0, 3).map(s => s.description), ["DB: departures", "DB: route search", "DB: favourite route 1"])
const binds = [
  { modmask: 72, key: "T", description: "SBB departures" },
  { modmask: 72, key: "B", description: "SBB: departures" },
  { modmask: 76, key: "5", description: "My own shortcut" }
]
const plan = Model.planShortcuts(binds, specs)
check("legacy SBB shortcut can be replaced during migration", plan.bind.some(b => b.keys === "SUPER + ALT + T"), true)
check("legacy SBB shortcut is intentionally removable", plan.stale, ["SUPER + ALT + B"])
check("unrelated shortcut remains protected", plan.skipped.map(b => b.owner), ["My own shortcut"])
check("shortcut Lua uses DB module and brand", Model.shortcutsLua({ stale: [], bind: [plan.bind[0]] }),
  'hl.unbind("SUPER + ALT + T")\nhl.bind("SUPER + ALT + T", hl.dsp.exec_cmd("omarchy-shell shell toggle vvkycodevv.db \'{}\'"), { description = "DB: departures" })')

check("UTF-8 response sizing", [Model.utf8Length("Köln"), Model.withinLimit("ü", 1)], [5, false])
check("capped command marker", Model.cappedCommand(["printf", "%s", "ok"], 10).slice(3, 5), ["db-capped", "11"])
check("curl remains bounded", Model.curlCommand("https://example.invalid", 2048, 5).slice(5),
  ["curl", "-sS", "--max-time", "5", "--max-filesize", "2048", "https://example.invalid"])

if (failures) {
  console.log(failures + " failed")
  process.exit(1)
}
console.log("All model tests passed")
