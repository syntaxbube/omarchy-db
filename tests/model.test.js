// Run with: TZ=Europe/Zurich node tests/model.test.js
// Fixtures follow the transport.opendata.ch v1 response shape.

const Model = require("../Model.js")

let failures = 0
function check(name, actual, expected) {
  const ok = JSON.stringify(actual) === JSON.stringify(expected)
  if (!ok) {
    failures++
    console.log("FAIL " + name + "\n  expected " + JSON.stringify(expected) + "\n  got      " + JSON.stringify(actual))
  }
}

// 29/09/2026 16:35 in Zurich (UTC+2)
const NOW = Date.UTC(2026, 8, 29, 14, 35) / 1000
const at = (hh, mm) => Date.UTC(2026, 8, 29, hh - 2, mm) / 1000

const board = {
  station: { name: "Zürich HB" },
  stationboard: [
    { name: "018207", category: "S", number: "2", to: "Flughafen ZH",
      stop: { departureTimestamp: at(16, 30), delay: 0, platform: "22", prognosis: {} }, passList: [] },
    { name: "002119", category: "IR", number: "70", to: "Luzern",
      stop: { departureTimestamp: at(16, 42), delay: 4, platform: "8", prognosis: { platform: null } },
      passList: [{ station: { name: "Zürich HB" } }, { station: { name: "Zug" } }, { station: { name: "Luzern" } }] },
    { name: "000723", category: "IC", number: "1", to: "Genève-Aéroport",
      stop: { departureTimestamp: at(16, 47), delay: null, platform: "32",
              prognosis: { platform: "33", departure: "2026-09-29T16:49:00+0200" } },
      passList: [{ station: { name: "Zürich HB" } }, { station: { name: "Bern" } }] },
    { name: "000561", category: "IC", number: "3", to: "Chur", cancelled: true,
      stop: { departureTimestamp: at(16, 50), delay: 0, platform: "7" }, passList: [] },
    { name: "000317", category: "EC", number: "1776", to: "Milano Centrale",
      stop: { departureTimestamp: at(16, 53), delay: 0, platform: "14" }, passList: [] }
  ]
}

const parsed = Model.parseDepartures(JSON.stringify(board))
check("board parses", parsed.ok, true)
check("station name", parsed.station, "Zürich HB")
check("count", parsed.departures.length, 5)
const [s2, ir, ic1, ic3, ec] = parsed.departures
check("S-Bahn label is tight", s2.line, "S2")
check("S-Bahn is local", s2.local, true)
check("IR label", ir.line, "IR 70")
check("IR is long distance", ir.local, false)
check("IR delay", ir.delay, 4)
check("IR time", ir.time, "16:42")
check("IR via keeps later stops", ir.via, ["Zug", "Luzern"])
check("delay from prognosis when delay is null", ic1.delay, 2)
check("platform change", [ic1.platform, ic1.platformChanged], ["33", true])
check("cancelled flag on journey", ic3.cancelled, true)
check("train number dropped", ec.line, "EC")

check("status texts", parsed.departures.map(Model.statusText), ["on time", "+4'", "+2'", "cancelled", "on time"])

check("next skips departed S2", Model.nextDeparture(parsed.departures, "", NOW).line, "IR 70")
check("destination matches via", Model.nextDeparture(parsed.departures, "zug", NOW).line, "IR 70")
check("destination matches accents", Model.nextDeparture(parsed.departures, "geneve", NOW).line, "IC 1")
check("unknown destination", Model.nextDeparture(parsed.departures, "Basel", NOW), null)

check("bar full delayed", Model.barText(ir, false, NOW), "IR 70 → Luzern 16:42 · +4'")
check("bar compact", Model.barText(ir, true, NOW), "16:42 · +4'")
check("bar on time countdown", Model.barText(ec, false, NOW), "EC → Milano Centrale 16:53 · in 18 min")
check("bar tail delay", Model.barTail(ir, NOW), "+4'")
check("bar tail countdown", Model.barTail(ec, NOW), "in 18 min")
check("bar cancelled", Model.barText(ic3, true, NOW), "16:50 · cancelled")

const a1 = Model.alertFor(ir, 3, {})
check("alert fires at threshold", a1 && a1.title, "IR 70 to Luzern +4'")
check("alert body", a1 && a1.body, "Planned 16:42, now leaving at 16:46 from platform 8.")
check("alert not repeated", Model.alertFor(ir, 3, { [a1.key]: true }), null)
check("alert below threshold", Model.alertFor(ic1, 3, {}), null)
check("alert off", Model.alertFor(ir, 0, {}), null)
check("cancel alert", Model.alertFor(ic3, 3, {}).title, "IC 3 to Chur cancelled")

check("bad json", Model.parseDepartures("<html>").ok, false)
check("api error message", Model.parseDepartures({ errors: [{ message: "Station not found" }] }).error, "Station not found")

const conns = Model.parseConnections({
  connections: [
    { from: { departureTimestamp: at(16, 42), delay: 4, platform: "8", prognosis: {} },
      to: { arrivalTimestamp: at(17, 31) }, duration: "00d00:49:00", transfers: 0,
      sections: [{ journey: { category: "IR", number: "70" } }] },
    { from: { departureTimestamp: at(17, 12), platform: "21", prognosis: { platform: "21" } },
      to: { arrivalTimestamp: at(18, 8) }, duration: "00d00:56:00", transfers: 1,
      sections: [{ journey: { category: "S", number: "8" } }, { walk: { duration: 180 }, journey: null },
                 { journey: { category: "IR", number: "75" } }] },
    { from: { departureTimestamp: at(17, 30), platform: "3" },
      to: { arrivalTimestamp: at(19, 5) }, duration: "00d01:35:00", transfers: 2, products: ["IC 5", "S3"] }
  ]
})
check("connections parse", conns.connections.length, 3)
check("direct", conns.connections[0].changes, "direct")
check("times", [conns.connections[0].depTime, conns.connections[0].arrTime], ["16:42", "17:31"])
check("duration", conns.connections[0].duration, "49 min")
check("long duration", conns.connections[2].duration, "1 h 35")
check("walk sections skipped", conns.connections[1].lines.map(l => l.label), ["S8", "IR 75"])
check("changes plural", conns.connections[2].changes, "2 changes")
check("products fallback", conns.connections[2].lines.map(l => l.label), ["IC 5", "S3"])

check("stations dedupe", Model.parseStations({ stations: [{ name: "Bern" }, { name: "Bern" }, { name: "Bern Balsberg" }] }), ["Bern", "Bern Balsberg"])
check("favourites", Model.parseFavourites("Zürich HB > Luzern; Bern -> Zürich HB\nbad line;  A→B "),
  [{ from: "Zürich HB", to: "Luzern" }, { from: "Bern", to: "Zürich HB" }, { from: "A", to: "B" }])
check("iso offset without colon", Model.isoToSeconds("2026-09-29T16:49:00+0200"), at(16, 49))
check("urls encode", Model.connectionsUrl("Zürich HB", "Luzern", 4),
  "https://transport.opendata.ch/v1/connections?from=Z%C3%BCrich%20HB&to=Luzern&limit=4")

// ---- Details views -----------------------------------------------------------

const board2 = JSON.parse(JSON.stringify(board))
board2.stationboard[1].passList = [
  { station: { name: null }, departureTimestamp: at(16, 42) },
  { station: { name: "Zug" }, arrivalTimestamp: at(17, 5), platform: "3" },
  { station: { name: "Luzern" }, arrivalTimestamp: at(17, 31) }]
const ir2 = Model.parseDepartures(board2).departures[1]
check("stops with times", ir2.stops, [{ name: "Zug", time: "17:05", platform: "3" }, { name: "Luzern", time: "17:31", platform: "" }])
check("via still built", ir2.via, ["Zug", "Luzern"])
check("planned platform kept", [ic1.plannedPlatform, ic1.platform], ["32", "33"])
check("expected time", Model.expectedTime(ir), "16:46")
check("board span", Model.boardSpan(parsed.departures, NOW), "next 18 min")
check("board span empty", Model.boardSpan([], NOW), "")

const legConns = Model.parseConnections({ connections: [{
  from: { departureTimestamp: at(17, 36), station: { name: "Bern, Bahnhof" } },
  to: { arrivalTimestamp: at(18, 49), station: { name: "Thun" } }, duration: "00d01:13:00", transfers: 1,
  sections: [
    { journey: { category: "B", number: "733", to: "Bern Wankdorf, Bahnhof" },
      departure: { departureTimestamp: at(17, 36), station: { name: "Bern, Bahnhof" }, platform: "G" },
      arrival: { arrivalTimestamp: at(17, 42), station: { name: "Bern Wankdorf, Bahnhof" } } },
    { walk: { duration: 300 }, journey: null,
      departure: { departureTimestamp: at(17, 42), station: { name: "Bern Wankdorf, Bahnhof" } },
      arrival: { arrivalTimestamp: at(17, 47), station: { name: "Bern Wankdorf" } } },
    { journey: { category: "IR", number: "75", to: "Luzern" },
      departure: { departureTimestamp: at(18, 35), delay: 2, station: { name: "Zürich HB" }, platform: "5", prognosis: { platform: "6" } },
      arrival: { arrivalTimestamp: at(18, 49), station: { name: "Thun" }, platform: "2" } }] }] }).connections[0]
check("leg kinds", legConns.legs.map(l => l.kind), ["ride", "walk", "ride"])
check("bus leg", [legConns.legs[0].line, legConns.legs[0].local, legConns.legs[0].depPlatform], ["B 733", true, "G"])
check("walk minutes", legConns.legs[1].minutes, 5)
check("ride leg", [legConns.legs[2].depTime, legConns.legs[2].arrTime, legConns.legs[2].depPlatform, legConns.legs[2].delay, legConns.legs[2].toward],
  ["18:35", "18:49", "6", 2, "Luzern"])
check("connection station names", [legConns.fromName, legConns.toName], ["Bern, Bahnhof", "Thun"])

check("url with time", Model.connectionsUrl("Bern", "Thun", 5, at(17, 30)),
  "https://transport.opendata.ch/v1/connections?from=Bern&to=Thun&limit=5&date=2026-09-29&time=17:30")
check("result limit capped at 10", /limit=10$/.test(Model.connectionsUrl("A", "B", 16)), true)
check("when labels", Model.WHEN_OFFSETS.map(Model.whenLabel), ["now", "in 15 min", "in 30 min", "in 1 h", "in 2 h"])

// ---- Route query ---------------------------------------------------------------

check("query with arrow", Model.parseRouteQuery("zürich hb → luzern", "Bern"), { from: "zürich hb", to: "luzern", explicit: true })
check("query with >", Model.parseRouteQuery("Bern > Zürich HB", ""), { from: "Bern", to: "Zürich HB", explicit: true })
check("query with ->", Model.parseRouteQuery("A->B", ""), { from: "A", to: "B", explicit: true })
check("query without arrow uses home", Model.parseRouteQuery("Luzern", "Zürich HB"), { from: "Zürich HB", to: "Luzern", explicit: false })
check("query half typed", Model.parseRouteQuery("Bern > ", "Zürich HB"), { from: "Bern", to: "", explicit: true })
check("segment before arrow", Model.activeSegment("Bern > Thun", 2), "from")
check("segment after arrow", Model.activeSegment("Bern > Thun", 9), "to")
check("segment without arrow", Model.activeSegment("Thun", 2), "to")
check("replace to", Model.replaceSegment("Bern > Th", "to", "Thun"), "Bern → Thun")
check("replace from", Model.replaceSegment("Be > Thun", "from", "Bern"), "Bern → Thun")
check("replace plain", Model.replaceSegment("luz", "to", "Luzern"), "Luzern")
check("swap", Model.swapRouteQuery("Zürich HB → Luzern", "X"), "Luzern → Zürich HB")
check("swap uses home", Model.swapRouteQuery("Luzern", "Zürich HB"), "Luzern → Zürich HB")

// ---- Favourites ------------------------------------------------------------------

const favs = Model.parseFavourites("Zürich HB > Luzern; Bern > Zürich HB")
check("add favourite", Model.addFavourite(favs, "Zürich HB", "Thun").added, true)
check("no duplicate favourite", Model.addFavourite(favs, "zurich hb", "LUZERN").added, false)
check("serialize favourites", Model.serializeFavourites(Model.addFavourite(favs, "Zürich HB", "Thun").list),
  "Zürich HB > Luzern; Bern > Zürich HB; Zürich HB > Thun")
check("remove favourite", Model.serializeFavourites(Model.removeFavourite(favs, 0)), "Bern > Zürich HB")

if (failures) {
  console.log(failures + " failed")
  process.exit(1)
}
console.log("all model tests passed")
