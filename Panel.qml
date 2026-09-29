import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "Shared.js" as Shared
import "Palette.js" as Palette

// Everything behind the bar pill: timetable fetching, delay alerts, and the
// five views of the popup, following the Figma template:
//   board       departures board (Window / Departures)
//   detail      one departure: times, platform, stops
//   route       one line route search (Walker / SBB route search)
//   connection  one connection: every ride and walk
//   settings    SBB settings (Window / Settings)
// Loaded by BarWidget.qml, which injects bar, settings, anchorItem and
// hostWidget.
Panel {
  id: root
  moduleName: "vvkycodevv.sbb"
  ipcTarget: "vvkycodevv.sbb"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ---- Settings (inline on the shell.json entry, see manifest schema) -----

  readonly property string homeStation: String(setting("homeStation", "Zürich HB")).trim() || "Zürich HB"
  readonly property string barDestination: String(setting("barDestination", "")).trim()
  readonly property bool compactBar: setting("barStyle", "Full") === "Compact"
  readonly property bool showInBar: String(setting("showInBar", true)) !== "false"
  readonly property int departureCount: Math.max(3, Math.min(20, parseInt(setting("departures", 8), 10) || 8))
  // Connections per route search, favourites included. The popup does not
  // scroll, so 10 is the most that fits.
  readonly property int connectionCount: Math.max(1, Math.min(10, parseInt(setting("connections", 5), 10) || 5))
  readonly property int refreshSeconds: Math.max(30, parseInt(setting("refreshSeconds", 60), 10) || 60)
  readonly property int delayAlertMinutes: Math.max(0, parseInt(setting("delayAlertMinutes", 3), 10) || 0)
  readonly property bool railBadges: setting("badgeStyle", "Rail red") !== "Theme"
  // Same default as the manifest: the shell does not fill in manifest
  // defaults for keys missing from the widget's shell.json entry.
  readonly property string defaultFavourites: ""
  readonly property var favourites: Model.parseFavourites(setting("favourites", defaultFavourites))

  // Settings changed from the settings view are written back to this
  // widget's shell.json entry; the shell reloads it and the bindings above
  // pick the new values up.
  function saveSetting(key, value) {
    var json = typeof value !== "string"
    var cmd = ["omarchy-bar", "set", root.moduleName, key, json ? JSON.stringify(value) : value]
    if (json) cmd.push("--json")
    Quickshell.execDetached(cmd)
  }

  // ---- Colours ----------------------------------------------------------------
  // "Figma" uses the template's Tokyo Night palette (Palette.js) everywhere,
  // independent of the desktop theme. "Theme" follows the active Omarchy theme.

  readonly property bool figma: setting("palette", "Figma") !== "Theme"

  readonly property color themeFg: bar ? bar.foreground : Color.foreground
  readonly property color themeAlert: bar ? bar.urgent : Color.urgent

  readonly property color base: figma ? Palette.base : "transparent"
  readonly property color deep: figma ? Palette.deep : Util.alpha(themeFg, 0.04)
  readonly property color surface: figma ? Palette.surface : Util.alpha(themeFg, 0.08)
  readonly property color raised: figma ? Palette.raised : Util.alpha(themeFg, 0.14)
  readonly property color hairline: figma ? Palette.border : Util.alpha(themeFg, 0.12)
  readonly property color fg: figma ? Palette.text : themeFg
  readonly property color dim: figma ? Palette.muted : Qt.darker(themeFg, 1.5)
  readonly property color subtle: figma ? Palette.subtle : Qt.darker(themeFg, 1.2)
  readonly property color accent: figma ? Palette.blue : Color.accent
  readonly property color platformColor: figma ? Palette.cyan : Color.accent
  readonly property color onTimeColor: figma ? Palette.green : Color.accent
  readonly property color delayColor: figma ? Palette.amber : themeAlert
  readonly property color cancelColor: figma ? Palette.red : themeAlert
  readonly property color alert: cancelColor
  readonly property color rowHighlight: figma ? Palette.surface : Style.hoverFillFor(themeFg, Color.accent)
  // Kept for the bits that only need a soft fill.
  readonly property color faint: surface
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Figma sizes that have no shell font token: 15 (connection times,
  // settings title) and 18 (route query).
  readonly property int fontLarge: Math.round(Style.font.body * 1.25)
  readonly property int fontQuery: Math.round(Style.font.body * 1.5)

  function statusColor(item) {
    var s = Model.status(item)
    if (s === "cancelled") return root.cancelColor
    if (s === "delayed") return root.delayColor
    return root.onTimeColor
  }

  // ---- Board state ------------------------------------------------------------

  property string stationName: ""
  property var departures: []
  property string boardError: ""
  property bool loaded: false
  property real updatedAt: 0
  property real nowSec: Date.now() / 1000
  property bool refetchQueued: false

  readonly property var barDeparture: Model.nextDeparture(departures, barDestination, nowSec)
  readonly property bool barAlert: barDeparture !== null && Model.status(barDeparture) !== "ontime"
  readonly property string label: {
    if (barDeparture) return Model.barText(barDeparture, compactBar, nowSec)
    if (boardError !== "" && departures.length === 0) return "offline"
    if (!loaded) return "…"
    return barDestination ? "no trains to " + barDestination : "no departures"
  }
  readonly property string tooltip: {
    if (boardError !== "") return "SBB: " + boardError
    return (stationName || homeStation) + (barDeparture && barDeparture.platform ? " · platform " + barDeparture.platform : "")
  }

  onHomeStationChanged: queueRefresh()
  onDepartureCountChanged: queueRefresh()
  onConnectionCountChanged: if ((view === "route" || view === "connection") && routeTo !== "") searchRoute()

  // ---- Panel view state -------------------------------------------------------

  property string view: "board"          // board | detail | route | connection | settings
  property int boardCursor: -1
  property int routeCursor: -1
  property int settingsCursor: 0
  property bool resultsFocused: false
  property var detailDeparture: null

  property string routeFrom: ""
  property string routeTo: ""
  property var connections: []
  property string routeError: ""
  property bool routeLoading: false
  property int whenIndex: 0
  property bool whenMenuOpen: false
  property string routeNotice: ""
  // Esc in the route search goes back to the board when it was opened from
  // there, and closes the popup when it was opened on its own (right click,
  // super+ctrl+alt+N, IPC).
  property bool routeFromBoard: false

  property string suggestSegment: ""     // "from" | "to" | ""
  property var suggestions: []
  property int suggestionIndex: -1

  readonly property var detailConnection: view === "connection" ? (connections[routeCursor] || null) : null
  readonly property int whenOffset: Model.WHEN_OFFSETS[whenIndex] || 0

  // Fixed rows of the settings view, favourites follow.
  readonly property int settingsFixedRows: 6
  readonly property int settingsRows: settingsFixedRows + favourites.length

  readonly property bool typing: queryField.activeFocus
    || homeField.input.activeFocus || refreshField.input.activeFocus || delayField.input.activeFocus
    || resultsField.input.activeFocus

  // Footer key hints for the current view, as [key, action] pairs.
  readonly property var hints: {
    if (view === "board") return [["↵", "details"], ["/", "search route"], ["r", "refresh"], [",", "settings"], ["esc", "close"]]
    if (view === "detail") return [["↵", "route there"], ["↑↓", "other trains"], ["esc", "back"]]
    if (view === "route") return [["↑↓", "navigate"], ["↵", "open details"], ["tab", "swap from/to"], ["ctrl s", "save favourite"], ["esc", routeFromBoard ? "back" : "close"]]
    if (view === "connection") return [["↑↓", "other connections"], ["ctrl s", "save favourite"], ["esc", "back"]]
    return [["↑↓", "navigate"], ["↵", "edit"], ["x", "remove favourite"], ["esc", "back"]]
  }

  // ---- Lifecycle --------------------------------------------------------------

  // Bar click, shell toggle/summon and super+alt+T: always the board, as in
  // the design. The route search and settings have their own entry points.
  function open() {
    if (view !== "board") {
      view = "board"
      resultsFocused = false
      whenMenuOpen = false
      clearSuggestions()
    }
    root.controller.show()
    root.refresh()
    focusKeys()
  }

  function close() {
    whenMenuOpen = false
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function focusKeys() {
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // ---- Fetching ---------------------------------------------------------------

  function refresh() {
    if (boardProc.running) {
      refetchQueued = true
      return
    }
    boardProc.command = ["curl", "-sS", "--max-time", "8", Model.stationboardUrl(homeStation, departureCount)]
    boardProc.running = true
  }

  function queueRefresh() {
    Qt.callLater(refresh)
  }

  function applyBoard(raw) {
    var text = String(raw || "").trim()
    if (text === "") {
      boardError = "timetable unreachable"
      return
    }
    var result = Model.parseDepartures(text)
    if (!result.ok) {
      boardError = result.error
      return
    }
    boardError = ""
    stationName = result.station
    departures = result.departures
    loaded = true
    updatedAt = Date.now() / 1000
    nowSec = updatedAt
    if (boardCursor >= departures.length) boardCursor = departures.length - 1
    // Keep the open details on the same train with fresh delay and platform.
    if (detailDeparture) {
      for (var i = 0; i < departures.length; i++) {
        if (departures[i].id === detailDeparture.id) {
          detailDeparture = departures[i]
          boardCursor = i
          break
        }
      }
    }
    checkAlert()
  }

  function checkAlert() {
    var alert = Model.alertFor(barDeparture, delayAlertMinutes, Shared.sent)
    if (!alert || !Shared.claim(alert.key)) return
    Quickshell.execDetached(["notify-send", "-a", "SBB", "-i", "train", alert.title, alert.body])
  }

  Process {
    id: boardProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyBoard(text)
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.departures.length === 0) root.boardError = "timetable unreachable"
      if (root.refetchQueued) {
        root.refetchQueued = false
        root.queueRefresh()
      }
    }
  }

  Timer {
    id: refreshTimer
    interval: root.refreshSeconds * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Keeps "in 7 min" honest between fetches and drops departed trains.
  Timer {
    interval: 15000
    running: true
    repeat: true
    onTriggered: root.nowSec = Date.now() / 1000
  }

  // ---- Board and departure details ---------------------------------------

  function showBoard() {
    view = "board"
    resultsFocused = false
    whenMenuOpen = false
    clearSuggestions()
    focusKeys()
  }

  function openDeparture(index) {
    if (departures.length === 0) return
    boardCursor = Math.max(0, Math.min(departures.length - 1, index))
    detailDeparture = departures[boardCursor]
    view = "detail"
    focusKeys()
  }

  // ---- Route search -----------------------------------------------------------

  function openRouteSearch(from, to) {
    if (view !== "route" && view !== "connection")
      routeFromBoard = root.opened && (view === "board" || view === "detail")
    view = "route"
    whenMenuOpen = false
    clearSuggestions()
    var f = String(from || "").trim()
    var t = String(to || "").trim()
    if (t !== "") queryField.text = Model.formatRoute(f || homeStation, t)
    else if (f !== "") queryField.text = Model.formatRoute(f, "")
    if (!root.opened) root.controller.show()
    if (t !== "") searchRoute()
    else focusQuery()
  }

  function focusQuery() {
    resultsFocused = false
    Qt.callLater(function() {
      queryField.forceActiveFocus()
      queryField.selectAll()
    })
  }

  function focusResults() {
    if (connections.length === 0) return
    clearSuggestions()
    whenMenuOpen = false
    resultsFocused = true
    if (routeCursor < 0) routeCursor = 0
    focusKeys()
  }

  function searchRoute() {
    clearSuggestions()
    whenMenuOpen = false
    var q = Model.parseRouteQuery(queryField.text, homeStation)
    if (q.to === "") {
      focusQuery()
      return
    }
    routeFrom = q.from || homeStation
    routeTo = q.to
    queryField.text = Model.formatRoute(routeFrom, routeTo)
    routeError = ""
    routeLoading = true
    routeCursor = 0
    var when = whenOffset > 0 ? Math.round(Date.now() / 1000) + whenOffset * 60 : 0
    routeProc.running = false
    routeProc.command = ["curl", "-sS", "--max-time", "10", Model.connectionsUrl(routeFrom, routeTo, connectionCount, when)]
    routeProc.running = true
  }

  function swapRoute() {
    queryField.text = Model.swapRouteQuery(queryField.text, homeStation)
    if (Model.parseRouteQuery(queryField.text, homeStation).to !== "") searchRoute()
  }

  function useFavourite(index) {
    var fav = favourites[index]
    if (!fav) return
    queryField.text = Model.formatRoute(fav.from, fav.to)
    searchRoute()
  }

  // super+ctrl+alt+N. A number without a favourite opens the search with the
  // favourites list and says so, instead of showing the last search.
  function openFavourite(number) {
    if (number >= 1 && number <= favourites.length) {
      openRouteSearch("", "")
      useFavourite(number - 1)
      return
    }
    openRouteSearch("", "")
    queryField.text = ""
    connections = []
    routeError = ""
    routeFrom = ""
    routeTo = ""
    var n = favourites.length
    showNotice("no favourite " + number + (n > 0 ? " · you have " + n : " · save one with ctrl s"))
  }

  function setWhen(index) {
    whenIndex = Math.max(0, Math.min(Model.WHEN_OFFSETS.length - 1, index))
    whenMenuOpen = false
    if (routeTo !== "") searchRoute()
  }

  function cycleWhen() {
    setWhen((whenIndex + 1) % Model.WHEN_OFFSETS.length)
  }

  // Saves the route in the query (or the one on screen) as a favourite.
  function saveFavourite() {
    var q = Model.parseRouteQuery(queryField.text, homeStation)
    var from = q.from || routeFrom
    var to = q.to || routeTo
    // Prefer the timetable's spelling ("Luzern") over what was typed
    // ("luzern") when the query is the route on screen.
    var shown = detailConnection || connections[0]
    if (shown && Model.foldKey(from) === Model.foldKey(routeFrom) && Model.foldKey(to) === Model.foldKey(routeTo)) {
      from = shown.fromName || from
      to = shown.toName || to
    }
    if (!from || !to) {
      showNotice("type a route first")
      return
    }
    var result = Model.addFavourite(favourites, from, to)
    if (!result.added) {
      showNotice("already a favourite")
      return
    }
    saveSetting("favourites", Model.serializeFavourites(result.list))
    var n = result.list.length
    showNotice("saved as favourite " + n + (n <= 9 ? " · super+ctrl+alt+" + n : ""))
  }

  function showNotice(text) {
    routeNotice = text
    noticeTimer.restart()
  }

  Timer {
    id: noticeTimer
    interval: 3000
    onTriggered: root.routeNotice = ""
  }

  Process {
    id: routeProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.routeLoading = false
        var raw = String(text || "").trim()
        if (raw === "") {
          root.connections = []
          root.routeError = "timetable unreachable"
          return
        }
        var result = Model.parseConnections(raw)
        root.connections = result.connections
        root.routeError = result.error
        if (result.connections.length > 0 && root.view === "route") root.focusResults()
      }
    }
  }

  function openConnection(index) {
    if (connections.length === 0) return
    routeCursor = Math.max(0, Math.min(connections.length - 1, index))
    view = "connection"
    whenMenuOpen = false
    focusKeys()
  }

  function exitRoute() {
    whenMenuOpen = false
    clearSuggestions()
    if (routeFromBoard) {
      showBoard()
      return
    }
    close()
    view = "board"
    resultsFocused = false
  }

  function backToResults() {
    view = "route"
    if (connections.length > 0) focusResults()
    else focusQuery()
  }

  // Station autocomplete for the half of the query the caret is in.
  function requestSuggestions() {
    var segment = Model.activeSegment(queryField.text, queryField.cursorPosition)
    var part = Model.segmentText(queryField.text, segment, homeStation)
    if (part.length < 2) {
      clearSuggestions()
      return
    }
    suggestSegment = segment
    suggestTimer.restart()
  }

  function clearSuggestions() {
    suggestTimer.stop()
    suggestions = []
    suggestionIndex = -1
    suggestSegment = ""
  }

  function pickSuggestion() {
    if (suggestionIndex < 0 || suggestionIndex >= suggestions.length) return false
    var segment = suggestSegment
    queryField.text = Model.replaceSegment(queryField.text, segment, suggestions[suggestionIndex])
    clearSuggestions()
    if (segment === "from" && Model.parseRouteQuery(queryField.text, homeStation).to === "") {
      queryField.cursorPosition = queryField.text.length
      queryField.forceActiveFocus()
    } else {
      searchRoute()
    }
    return true
  }

  Timer {
    id: suggestTimer
    interval: 250
    onTriggered: {
      var part = Model.segmentText(queryField.text, root.suggestSegment, root.homeStation)
      stationProc.running = false
      stationProc.command = ["curl", "-sS", "--max-time", "5", Model.locationsUrl(part)]
      stationProc.running = true
    }
  }

  Process {
    id: stationProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (root.suggestSegment === "") return
        var part = Model.segmentText(queryField.text, root.suggestSegment, root.homeStation)
        var names = Model.parseStations(text)
        // Nothing to suggest when the query already holds an exact match.
        if (names.length === 1 && names[0] === part) names = []
        root.suggestions = names
        root.suggestionIndex = names.length > 0 ? 0 : -1
      }
    }
  }

  // ---- Settings view ------------------------------------------------------

  function openSettings() {
    view = "settings"
    whenMenuOpen = false
    settingsCursor = Math.max(0, Math.min(settingsRows - 1, settingsCursor))
    if (!root.opened) root.controller.show()
    focusKeys()
  }

  function activateSetting(index) {
    settingsCursor = index
    if (index === 0) homeField.edit()
    else if (index === 1) refreshField.edit()
    else if (index === 2) delayField.edit()
    else if (index === 3) resultsField.edit()
    else if (index === 4) saveSetting("showInBar", !showInBar)
    else if (index === 5) saveSetting("palette", figma ? "Theme" : "Figma")
    else {
      var fav = favourites[index - settingsFixedRows]
      if (fav) openRouteSearch(fav.from, fav.to)
    }
  }

  function removeFavouriteAt(index) {
    if (index < 0 || index >= favourites.length) return
    saveSetting("favourites", Model.serializeFavourites(Model.removeFavourite(favourites, index)))
    if (settingsCursor >= settingsRows - 1) settingsCursor = Math.max(0, settingsRows - 2)
  }

  function commitHome(text) {
    var t = String(text || "").trim()
    if (t !== "" && t !== homeStation) saveSetting("homeStation", t)
    focusKeys()
  }

  function commitNumber(key, text, low, high) {
    var n = parseInt(text, 10)
    if (!isNaN(n)) saveSetting(key, Math.max(low, Math.min(high, n)))
    focusKeys()
  }

  // ---- Keyboard ---------------------------------------------------------------

  function moveCursor(dy) {
    if (view === "board") {
      if (departures.length === 0) return
      boardCursor = Math.max(0, Math.min(departures.length - 1, boardCursor + dy))
    } else if (view === "detail") {
      openDeparture(boardCursor + dy)
    } else if (view === "route" && resultsFocused) {
      if (dy < 0 && routeCursor <= 0) {
        focusQuery()
        return
      }
      routeCursor = Math.max(0, Math.min(connections.length - 1, routeCursor + dy))
    } else if (view === "connection") {
      routeCursor = Math.max(0, Math.min(connections.length - 1, routeCursor + dy))
    } else if (view === "settings") {
      settingsCursor = Math.max(0, Math.min(settingsRows - 1, settingsCursor + dy))
    }
  }

  function activate() {
    if (view === "board") openDeparture(boardCursor < 0 ? 0 : boardCursor)
    else if (view === "detail" && detailDeparture) openRouteSearch(stationName || homeStation, detailDeparture.to)
    else if (view === "route" && resultsFocused) openConnection(routeCursor)
    else if (view === "settings") activateSetting(settingsCursor)
  }

  function goBack() {
    if (view === "detail" || view === "settings") showBoard()
    else if (view === "connection") backToResults()
    else if (view === "route" && whenMenuOpen) whenMenuOpen = false
    else if (view === "route") exitRoute()
    else close()
  }

  // Ctrl+letter arrives as a control character: ctrl s is "\u0013",
  // ctrl t is "\u0014".
  function handleText(t) {
    if (view === "board") {
      if (t === "/" || t === "s") openRouteSearch("", "")
      else if (t === "r") refresh()
      else if (t === ",") openSettings()
    } else if (view === "detail") {
      if (t === "/") openRouteSearch("", "")
      else if (t === "r") refresh()
    } else if (view === "route" && resultsFocused) {
      if (t === "/") focusQuery()
      else if (t === "r") searchRoute()
      else if (t === "\u0013") saveFavourite()
      else if (t === "\u0014") cycleWhen()
      else if (t >= "1" && t <= "9") useFavourite(parseInt(t, 10) - 1)
    } else if (view === "connection") {
      if (t === "\u0013") saveFavourite()
      else if (t === "r") searchRoute()
    } else if (view === "settings") {
      if (t === ",") showBoard()
    }
  }

  // Tab swaps from and to in the route search; elsewhere it moves to the
  // neighbouring bar panel like every other Omarchy popup.
  function handleTab(direction) {
    if (view === "route" || view === "connection") swapRoute()
    else switchPanel(direction)
  }

  // Keys typed into the route query. Returns true when the key was used.
  function queryKey(event) {
    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
    if (event.key === Qt.Key_Escape) {
      if (whenMenuOpen) whenMenuOpen = false
      else if (suggestions.length > 0) clearSuggestions()
      else exitRoute()
      return true
    }
    if (ctrl && event.key === Qt.Key_S) {
      saveFavourite()
      return true
    }
    if (ctrl && event.key === Qt.Key_T) {
      cycleWhen()
      return true
    }
    if (ctrl && event.key >= Qt.Key_1 && event.key <= Qt.Key_9) {
      useFavourite(event.key - Qt.Key_1)
      return true
    }
    if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
      clearSuggestions()
      swapRoute()
      return true
    }
    if (event.key === Qt.Key_Down) {
      if (suggestions.length > 0) suggestionIndex = Math.min(suggestions.length - 1, suggestionIndex + 1)
      else focusResults()
      return true
    }
    if (event.key === Qt.Key_Up) {
      if (suggestions.length > 0) suggestionIndex = Math.max(0, suggestionIndex - 1)
      return true
    }
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      if (!pickSuggestion()) searchRoute()
      return true
    }
    return false
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
    function board(): void { root.showBoard(); root.open() }
    function search(): void { root.openRouteSearch("", "") }
    function route(from: string, to: string): void { root.openRouteSearch(from, to) }
    function favourite(index: int): void { root.openFavourite(index) }
    function toggleSearch(): void {
      if (root.opened && (root.view === "route" || root.view === "connection")) root.close()
      else root.openRouteSearch("", "")
    }
    function settings(): void { root.openSettings() }
  }

  // ---- UI -------------------------------------------------------------------

  // Inline components do not see this file's ids, so everything they draw
  // with is passed in through properties.

  // Small line badge: rail red for long distance, neutral for local services.
  component LineBadge: Rectangle {
    id: lineBadge
    property string label: ""
    property bool local: false
    property bool rail: true
    property color fg: Color.foreground
    property color localFill: Util.alpha(fg, 0.12)
    property string fontFamily: Style.font.family
    readonly property bool red: rail && !local

    implicitWidth: badgeText.implicitWidth + Style.space(12)
    implicitHeight: badgeText.implicitHeight + Style.space(4)
    radius: Math.min(4, Style.cornerRadius + 2)
    color: red ? Palette.rail : localFill

    Text {
      id: badgeText
      anchors.centerIn: parent
      text: lineBadge.label
      textFormat: Text.PlainText
      color: lineBadge.red ? "#ffffff" : lineBadge.fg
      font.family: lineBadge.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
    }
  }

  // Keyboard hint in the footer: a key cap and what it does.
  component KeyHint: Row {
    id: keyHint
    property string keys: ""
    property string action: ""
    property color fg: Color.foreground
    property color capFill: "transparent"
    property color capBorder: Util.alpha(fg, 0.25)
    property color capText: fg
    property color labelColor: Qt.darker(fg, 1.5)
    property string fontFamily: Style.font.family
    spacing: Style.space(6)

    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      width: keyText.implicitWidth + Style.space(10)
      height: keyText.implicitHeight + Style.space(2)
      radius: Math.min(3, Style.cornerRadius + 1)
      color: keyHint.capFill
      border.width: 1
      border.color: keyHint.capBorder

      Text {
        id: keyText
        anchors.centerIn: parent
        text: keyHint.keys
        textFormat: Text.PlainText
        color: keyHint.capText
        font.family: keyHint.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: keyHint.action
      textFormat: Text.PlainText
      color: keyHint.labelColor
      font.family: keyHint.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  component ColumnLabel: Text {
    property color fg: Color.foreground
    property string fontFamily: Style.font.family
    textFormat: Text.PlainText
    color: fg
    font.family: fontFamily
    font.pixelSize: Style.font.caption
    font.weight: Font.Medium
    font.letterSpacing: 1
  }

  // Pill in the view headers: dot plus a short status, e.g. "live · 16:35".
  component StatusChip: Rectangle {
    id: chip
    property string text: ""
    property color dot: Color.accent
    property color textColor: Color.foreground
    property string fontFamily: Style.font.family
    implicitWidth: chipRow.implicitWidth + Style.space(16)
    implicitHeight: chipRow.implicitHeight + Style.space(6)
    radius: height / 2

    Row {
      id: chipRow
      anchors.centerIn: parent
      spacing: Style.space(6)

      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(6)
        height: width
        radius: width / 2
        color: chip.dot
      }

      Text {
        text: chip.text
        textFormat: Text.PlainText
        color: chip.textColor
        font.family: chip.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.weight: Font.Medium
      }
    }
  }

  // Small input from the settings window: value plus an optional unit.
  // Enter commits, Esc puts the saved value back.
  component SettingField: Rectangle {
    id: field
    property string value: ""
    property string suffix: ""
    property bool numeric: false
    property color fg: Color.foreground
    property color fill: "transparent"
    property color borderColor: Util.alpha(fg, 0.25)
    property color accent: Color.accent
    property string fontFamily: Style.font.family
    property alias input: fieldInput
    readonly property var digitsOnly: IntValidator { bottom: 0; top: 9999 }
    signal committed(string text)
    signal cancelled()

    function edit() {
      fieldInput.text = value
      fieldInput.forceActiveFocus()
      fieldInput.selectAll()
    }

    onValueChanged: if (!fieldInput.activeFocus) fieldInput.text = value
    Component.onCompleted: fieldInput.text = value

    implicitWidth: fieldRow.implicitWidth + Style.space(20)
    implicitHeight: fieldRow.implicitHeight + Style.space(10)
    radius: Style.space(5)
    color: fill
    border.width: 1
    border.color: fieldInput.activeFocus ? accent : borderColor

    Row {
      id: fieldRow
      anchors.centerIn: parent
      spacing: Style.space(4)

      TextInput {
        id: fieldInput
        width: Math.max(Style.space(14), contentWidth)
        color: field.fg
        selectionColor: Util.alpha(field.accent, 0.35)
        selectedTextColor: field.fg
        selectByMouse: true
        horizontalAlignment: field.numeric ? TextInput.AlignRight : TextInput.AlignLeft
        validator: field.numeric ? field.digitsOnly : null
        font.family: field.fontFamily
        font.pixelSize: Style.font.body
        onActiveFocusChanged: if (!activeFocus) text = field.value
        Keys.onReturnPressed: field.committed(text)
        Keys.onEnterPressed: field.committed(text)
        Keys.onEscapePressed: {
          text = field.value
          field.cancelled()
        }
      }

      Text {
        visible: field.suffix !== ""
        text: field.suffix
        textFormat: Text.PlainText
        color: field.fg
        font.family: field.fontFamily
        font.pixelSize: Style.font.body
      }
    }

    MouseArea {
      anchors.fill: parent
      visible: !fieldInput.activeFocus
      cursorShape: Qt.IBeamCursor
      onClicked: field.edit()
    }
  }

  // Switch from the settings window (Toggle / On): 34 × 18 accent track,
  // base coloured knob on the right when on; muted when off.
  component SbbToggle: Rectangle {
    id: toggle
    property bool checked: false
    property color onColor: Color.accent
    property color offColor: Util.alpha(Color.foreground, 0.15)
    property color knobOn: "#1a1b26"
    property color knobOff: Color.foreground
    implicitWidth: Style.space(34)
    implicitHeight: Style.space(18)
    radius: height / 2
    color: checked ? onColor : offColor

    Rectangle {
      width: parent.height - Style.space(4)
      height: width
      radius: width / 2
      anchors.verticalCenter: parent.verticalCenter
      x: toggle.checked ? parent.width - width - Style.space(2) : Style.space(2)
      color: toggle.checked ? toggle.knobOn : toggle.knobOff
      Behavior on x { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
    }
  }

  // One row of the settings window: label and description on the left,
  // the control (declared as the row's content) on the right.
  component SettingRow: Rectangle {
    id: settingRow
    property string label: ""
    property string description: ""
    property bool current: false
    property color fg: Color.foreground
    property color dim: Qt.darker(fg, 1.5)
    property color highlight: Util.alpha(fg, 0.08)
    property string fontFamily: Style.font.family
    default property alias control: controlSlot.data
    signal activated()

    width: parent ? parent.width : 0
    height: Math.max(labelColumn.implicitHeight, controlSlot.height) + Style.space(20)
    radius: Style.space(6)
    color: current || rowMouse.containsMouse ? highlight : "transparent"

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: settingRow.activated()
    }

    Column {
      id: labelColumn
      anchors.left: parent.left
      anchors.leftMargin: Style.space(10)
      anchors.right: controlSlot.left
      anchors.rightMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      Text {
        text: settingRow.label
        textFormat: Text.PlainText
        color: settingRow.fg
        font.family: settingRow.fontFamily
        font.pixelSize: Style.font.subtitle
        font.weight: Font.Medium
      }

      Text {
        width: parent.width
        text: settingRow.description
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: settingRow.dim
        font.family: settingRow.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }

    Item {
      id: controlSlot
      anchors.right: parent.right
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      width: childrenRect.width
      height: childrenRect.height
    }
  }

  readonly property int colTime: Style.space(52)
  readonly property int colLine: Style.space(64)
  readonly property int colPlatform: Style.space(40)
  readonly property int colStatus: Style.space(80)

  readonly property bool wideView: view === "route" || view === "connection"
  readonly property Item activeColumn: {
    if (view === "detail") return detailColumn
    if (view === "route") return routeColumn
    if (view === "connection") return connectionColumn
    if (view === "settings") return settingsColumn
    return boardColumn
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    // Figma: the route search is the wide Walker-style window (660), the
    // board and settings the narrow ones (480 / 520).
    contentWidth: panel.fittedContentWidth(Style.space(root.wideView ? 640 : 500))
    // The footer runs to the card edge (under the padding), so the padding
    // below it is not counted twice.
    contentHeight: panel.fittedContentHeight(root.activeColumn.implicitHeight + footer.implicitHeight + Style.space(10) - (root.figma ? panel.padding : 0))
    // Figma: 2px accent/blue window border.
    borderSpec: root.figma
      ? Border.flat(Palette.blue, Math.max(1, Style.space(2)))
      : Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))

    // The card itself always paints the theme's popup colour, so the Figma
    // background is laid over it, reaching out under the card padding.
    Rectangle {
      visible: root.figma
      anchors.fill: parent
      anchors.margins: -panel.padding
      radius: Math.max(0, Style.cornerRadius - 2)
      color: root.base
    }

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.typing
      onCloseRequested: root.goBack()
      onTabRequested: function(direction) { root.handleTab(direction) }
      onMoveRequested: function(dx, dy) { if (dy !== 0) root.moveCursor(dy) }
      onActivateRequested: root.activate()
      onDeleteRequested: {
        if (root.view === "settings") root.removeFavouriteAt(root.settingsCursor - root.settingsFixedRows)
      }
      onTextKey: function(t) { root.handleText(t) }

      // ---- Departures board -------------------------------------------------
      Column {
        id: boardColumn
        visible: root.view === "board"
        width: parent.width
        spacing: Style.space(4)

        Item {
          width: parent.width
          height: titleBlock.implicitHeight + Style.space(8)

          Column {
            id: titleBlock
            anchors.left: parent.left
            anchors.leftMargin: Style.space(12)
            anchors.right: liveChip.left
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: root.stationName || root.homeStation
              textFormat: Text.PlainText
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              font.bold: true
            }

            Text {
              width: parent.width
              text: {
                var span = Model.boardSpan(root.departures, root.nowSec)
                var s = "departures" + (span ? " · " + span : "")
                return root.barDestination ? s + " · bar: to " + root.barDestination : s
              }
              textFormat: Text.PlainText
              elide: Text.ElideRight
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          StatusChip {
            id: liveChip
            anchors.right: parent.right
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            color: root.faint
            dot: root.boardError !== "" ? root.cancelColor : root.onTimeColor
            textColor: root.subtle
            fontFamily: root.fontFamily
            text: root.boardError !== ""
              ? root.boardError
              : (root.updatedAt > 0 ? "live · " + Model.clock(root.updatedAt) : "loading")
          }
        }

        // Column labels
        Item {
          width: parent.width
          height: headerRow.implicitHeight + Style.space(8)

          Row {
            id: headerRow
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: Style.space(12)
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter

            ColumnLabel { fg: root.dim; fontFamily: root.fontFamily; width: root.colTime; text: "TIME" }
            ColumnLabel { fg: root.dim; fontFamily: root.fontFamily; width: root.colLine; text: "LINE" }
            ColumnLabel { fg: root.dim; fontFamily: root.fontFamily; width: parent.width - root.colTime - root.colLine - root.colPlatform - root.colStatus; text: "DESTINATION" }
            ColumnLabel { fg: root.dim; fontFamily: root.fontFamily; width: root.colPlatform; text: "PL"; horizontalAlignment: Text.AlignRight }
            ColumnLabel { fg: root.dim; fontFamily: root.fontFamily; width: root.colStatus; text: "STATUS"; horizontalAlignment: Text.AlignRight }
          }

          Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width
            height: Style.spacing.hairline
            color: root.hairline
          }
        }

        Text {
          visible: root.departures.length === 0
          width: parent.width
          leftPadding: Style.space(12)
          topPadding: Style.space(6)
          bottomPadding: Style.space(6)
          text: root.boardError !== "" ? "Could not load departures: " + root.boardError : "Fetching departures…"
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.italic: true
        }

        Repeater {
          model: root.departures

          Rectangle {
            id: depRow
            required property var modelData
            required property int index
            readonly property bool cancelled: modelData.cancelled
            readonly property bool departed: Model.minutesUntil(modelData, root.nowSec) < 0
            readonly property bool followed: root.barDeparture !== null && root.barDeparture.id === modelData.id

            width: boardColumn.width
            height: depLine.implicitHeight + Style.space(12)
            radius: Style.cornerRadius
            color: index === root.boardCursor || depMouse.containsMouse
              ? root.rowHighlight
              : (followed ? (root.figma ? Util.alpha(Palette.surface, 0.35) : Util.alpha(root.themeFg, 0.05)) : "transparent")
            opacity: departed ? 0.45 : 1

            Row {
              id: depLine
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.leftMargin: Style.space(12)
              anchors.rightMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter

              Text {
                width: root.colTime
                anchors.verticalCenter: parent.verticalCenter
                text: depRow.modelData.time
                textFormat: Text.PlainText
                color: depRow.cancelled ? root.dim : root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
                font.strikeout: depRow.cancelled
              }

              Item {
                width: root.colLine
                height: badge.implicitHeight
                anchors.verticalCenter: parent.verticalCenter

                LineBadge {
                  id: badge
                  label: depRow.modelData.line
                  local: depRow.modelData.local
                  rail: root.railBadges
                  fg: root.fg
                  localFill: root.raised
                  fontFamily: root.fontFamily
                }
              }

              Text {
                width: parent.width - root.colTime - root.colLine - root.colPlatform - root.colStatus
                anchors.verticalCenter: parent.verticalCenter
                text: depRow.modelData.to
                textFormat: Text.PlainText
                elide: Text.ElideRight
                color: depRow.cancelled ? root.dim : root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
              }

              Text {
                width: root.colPlatform
                anchors.verticalCenter: parent.verticalCenter
                horizontalAlignment: Text.AlignRight
                text: depRow.modelData.platform + (depRow.modelData.platformChanged ? "!" : "")
                textFormat: Text.PlainText
                color: depRow.modelData.platformChanged ? root.delayColor : root.platformColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
                font.weight: depRow.modelData.platformChanged ? Font.Bold : Font.Medium
              }

              Text {
                width: root.colStatus
                anchors.verticalCenter: parent.verticalCenter
                horizontalAlignment: Text.AlignRight
                text: Model.statusText(depRow.modelData)
                textFormat: Text.PlainText
                color: root.statusColor(depRow.modelData)
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.weight: Font.Medium
              }
            }

            MouseArea {
              id: depMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.openDeparture(depRow.index)
            }
          }
        }
      }

      // ---- Departure details --------------------------------------------------
      Column {
        id: detailColumn
        visible: root.view === "detail"
        width: parent.width
        spacing: Style.space(4)

        readonly property var dep: root.detailDeparture
        readonly property bool cancelled: dep ? dep.cancelled : false

        Item {
          width: parent.width
          height: detailTitle.implicitHeight + Style.space(8)

          Column {
            id: detailTitle
            anchors.left: parent.left
            anchors.leftMargin: Style.space(12)
            anchors.right: detailChip.left
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)

            Row {
              spacing: Style.space(8)

              LineBadge {
                anchors.verticalCenter: parent.verticalCenter
                label: detailColumn.dep ? detailColumn.dep.line : ""
                local: detailColumn.dep ? detailColumn.dep.local : false
                rail: root.railBadges
                fg: root.fg
                localFill: root.raised
                fontFamily: root.fontFamily
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: detailColumn.dep ? "→ " + detailColumn.dep.to : ""
                textFormat: Text.PlainText
                color: detailColumn.cancelled ? root.dim : root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.heading
                font.bold: true
              }
            }

            Text {
              width: parent.width
              text: "from " + (root.stationName || root.homeStation)
              textFormat: Text.PlainText
              elide: Text.ElideRight
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          StatusChip {
            id: detailChip
            anchors.right: parent.right
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            color: root.faint
            dot: root.statusColor(detailColumn.dep)
            textColor: root.statusColor(detailColumn.dep)
            fontFamily: root.fontFamily
            text: {
              var d = detailColumn.dep
              if (!d) return ""
              if (d.cancelled) return "cancelled"
              var m = Model.minutesUntil(d, root.nowSec)
              var when = m < 0 ? "departed" : (m === 0 ? "now" : "in " + m + " min")
              return d.delay > 0 ? "+" + d.delay + "' · " + when : when
            }
          }
        }

        // Departs / platform / planned, as three labelled facts.
        Item {
          width: parent.width
          height: factsRow.implicitHeight + Style.space(12)

          Row {
            id: factsRow
            anchors.left: parent.left
            anchors.leftMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(28)

            Repeater {
              model: {
                var d = detailColumn.dep
                if (!d) return []
                return [
                  { label: "DEPARTS", value: Model.expectedTime(d), color: d.cancelled ? root.dim : (d.delay > 0 ? root.delayColor : root.fg), strike: d.cancelled },
                  { label: "PLANNED", value: d.time, color: root.dim, strike: false },
                  { label: "PLATFORM", value: (d.platform || "–") + (d.platformChanged ? " (was " + d.plannedPlatform + ")" : ""),
                    color: d.platformChanged ? root.delayColor : root.platformColor, strike: false }
                ]
              }

              Column {
                required property var modelData
                spacing: Style.space(2)

                ColumnLabel { fg: root.dim; fontFamily: root.fontFamily; text: modelData.label }

                Text {
                  text: modelData.value
                  textFormat: Text.PlainText
                  color: modelData.color
                  font.family: root.fontFamily
                  font.pixelSize: root.fontLarge
                  font.bold: true
                  font.strikeout: modelData.strike
                }
              }
            }
          }

          Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width
            height: Style.spacing.hairline
            color: root.hairline
          }
        }

        ColumnLabel {
          x: Style.space(12)
          topPadding: Style.space(4)
          fg: root.dim
          fontFamily: root.fontFamily
          text: "STOPS"
        }

        Text {
          visible: detailColumn.dep !== null && detailColumn.dep.stops.length === 0
          x: Style.space(12)
          text: "No stop list for this train."
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.italic: true
        }

        Repeater {
          model: detailColumn.dep ? detailColumn.dep.stops.slice(0, 10) : []

          Row {
            required property var modelData
            required property int index
            readonly property bool last: detailColumn.dep && index === detailColumn.dep.stops.length - 1
            x: Style.space(12)
            width: detailColumn.width - Style.space(24)
            height: stopName.implicitHeight + Style.space(8)

            Text {
              width: root.colTime
              anchors.verticalCenter: parent.verticalCenter
              text: modelData.time
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Text {
              id: stopName
              width: parent.width - root.colTime - root.colPlatform
              anchors.verticalCenter: parent.verticalCenter
              text: modelData.name
              textFormat: Text.PlainText
              elide: Text.ElideRight
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: parent.last
            }

            Text {
              width: root.colPlatform
              anchors.verticalCenter: parent.verticalCenter
              horizontalAlignment: Text.AlignRight
              text: modelData.platform
              textFormat: Text.PlainText
              color: root.platformColor
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
          }
        }

        Text {
          visible: detailColumn.dep !== null && detailColumn.dep.stops.length > 10
          x: Style.space(12)
          bottomPadding: Style.space(4)
          text: detailColumn.dep ? "+ " + (detailColumn.dep.stops.length - 10) + " more stops to " + detailColumn.dep.to : ""
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }

      // ---- Route search -----------------------------------------------------
      Column {
        id: routeColumn
        visible: root.view === "route"
        width: parent.width
        spacing: 0

        // Search input: "sbb" chip, the query, the "now ▾" picker.
        Item {
          id: searchBar
          z: 2
          width: parent.width
          height: Math.max(queryField.implicitHeight, prefixChip.height) + Style.space(28)

          Rectangle {
            id: prefixChip
            anchors.left: parent.left
            anchors.leftMargin: Style.space(14)
            anchors.verticalCenter: parent.verticalCenter
            width: prefixText.implicitWidth + Style.space(14)
            height: prefixText.implicitHeight + Style.space(4)
            radius: Math.min(4, Style.cornerRadius + 2)
            color: root.railBadges ? Palette.rail : root.raised

            Text {
              id: prefixText
              anchors.centerIn: parent
              text: "sbb"
              textFormat: Text.PlainText
              color: root.railBadges ? "#ffffff" : root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
            }
          }

          TextInput {
            id: queryField
            anchors.left: prefixChip.right
            anchors.leftMargin: Style.space(10)
            anchors.right: whenButton.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            clip: true
            color: root.fg
            selectionColor: Util.alpha(root.accent, 0.35)
            selectedTextColor: root.fg
            selectByMouse: true
            font.family: root.fontFamily
            font.pixelSize: root.fontQuery
            cursorDelegate: Rectangle {
              width: Math.max(1, Style.space(2))
              color: root.accent
              visible: queryField.cursorVisible
            }
            onActiveFocusChanged: if (activeFocus) root.resultsFocused = false
            onTextEdited: root.requestSuggestions()
            Keys.onPressed: function(event) { if (root.queryKey(event)) event.accepted = true }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              visible: queryField.text === ""
              text: "destination, or from → to"
              textFormat: Text.PlainText
              color: root.dim
              font: queryField.font
            }
          }

          Text {
            id: whenButton
            anchors.right: parent.right
            anchors.rightMargin: Style.space(14)
            anchors.verticalCenter: parent.verticalCenter
            text: Model.whenLabel(root.whenOffset) + " ▾"
            textFormat: Text.PlainText
            color: root.whenMenuOpen || whenMouse.containsMouse ? root.fg : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.weight: Font.Medium

            MouseArea {
              id: whenMouse
              anchors.fill: parent
              anchors.margins: -Style.space(6)
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.whenMenuOpen = !root.whenMenuOpen
            }
          }

          // Departure time picker, drops down over the results.
          Rectangle {
            visible: root.whenMenuOpen
            anchors.right: parent.right
            anchors.rightMargin: Style.space(8)
            anchors.top: parent.bottom
            anchors.topMargin: -Style.space(8)
            width: whenList.implicitWidth + Style.space(8)
            height: whenList.implicitHeight + Style.space(8)
            radius: Style.space(6)
            color: root.figma ? Palette.surface : Color.popups.background
            border.width: 1
            border.color: root.hairline

            Column {
              id: whenList
              anchors.centerIn: parent

              Repeater {
                model: Model.WHEN_OFFSETS

                Rectangle {
                  required property int modelData
                  required property int index
                  width: Style.space(110)
                  height: whenText.implicitHeight + Style.space(8)
                  radius: Style.space(4)
                  color: whenItemMouse.containsMouse ? root.raised : "transparent"

                  Text {
                    id: whenText
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    text: Model.whenLabel(modelData)
                    textFormat: Text.PlainText
                    color: index === root.whenIndex ? root.accent : root.fg
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }

                  MouseArea {
                    id: whenItemMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.setWhen(index)
                  }
                }
              }
            }
          }

          Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width
            height: Style.spacing.hairline
            color: root.hairline
          }
        }

        // Station suggestions for the half of the query being typed.
        Column {
          visible: root.suggestions.length > 0
          x: Style.space(8)
          width: parent.width - Style.space(16)
          topPadding: Style.space(6)
          spacing: Style.space(2)

          Repeater {
            model: root.suggestions

            Rectangle {
              required property string modelData
              required property int index
              width: parent.width
              height: suggestionText.implicitHeight + Style.space(10)
              radius: Style.cornerRadius
              color: index === root.suggestionIndex ? root.rowHighlight : "transparent"

              Text {
                id: suggestionText
                anchors.left: parent.left
                anchors.leftMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                text: (root.suggestSegment === "from" ? "from  " : "to  ") + modelData
                textFormat: Text.PlainText
                color: index === root.suggestionIndex ? root.accent : root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.suggestionIndex = index
                  root.pickSuggestion()
                }
              }
            }
          }
        }

        // Section label
        Item {
          width: parent.width
          height: sectionLabel.implicitHeight + Style.space(18)
          visible: root.suggestions.length === 0

          ColumnLabel {
            id: sectionLabel
            anchors.left: parent.left
            anchors.leftMargin: Style.space(18)
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Style.space(6)
            fg: root.dim
            fontFamily: root.fontFamily
            text: root.connections.length > 0 || root.routeLoading || root.routeError !== "" ? "CONNECTIONS" : "FAVOURITE ROUTES"
          }

        }

        // Favourite routes, ctrl 1 … ctrl 9, until a search has run.
        Flow {
          visible: root.suggestions.length === 0 && root.connections.length === 0 && !root.routeLoading && root.routeError === ""
          x: Style.space(18)
          width: parent.width - Style.space(36)
          bottomPadding: Style.space(10)
          spacing: Style.space(6)

          Text {
            visible: root.favourites.length === 0
            text: "None yet. Search a route and press ctrl s to keep it here."
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          Repeater {
            model: root.favourites

            Rectangle {
              required property var modelData
              required property int index
              width: favText.implicitWidth + Style.space(16)
              height: favText.implicitHeight + Style.space(10)
              radius: Style.space(6)
              color: favMouse.containsMouse ? root.raised : root.surface

              Text {
                id: favText
                anchors.centerIn: parent
                text: (index < 9 ? (index + 1) + "  " : "") + modelData.from + " → " + modelData.to
                textFormat: Text.PlainText
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              MouseArea {
                id: favMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.useFavourite(index)
              }
            }
          }
        }

        Text {
          x: Style.space(18)
          visible: root.suggestions.length === 0 && (root.routeLoading || root.routeError !== "")
          width: parent.width - Style.space(36)
          bottomPadding: Style.space(10)
          text: root.routeLoading ? "Searching connections…" : root.routeError
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          color: root.routeLoading ? root.dim : root.alert
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.italic: root.routeLoading
        }

        // Results
        Column {
          visible: root.suggestions.length === 0 && !root.routeLoading && root.connections.length > 0
          x: Style.space(8)
          width: parent.width - Style.space(16)
          bottomPadding: Style.space(8)
          spacing: Style.space(4)

          Repeater {
            model: root.routeLoading ? [] : root.connections

            Rectangle {
              id: connRow
              required property var modelData
              required property int index
              readonly property bool selected: root.resultsFocused && index === root.routeCursor

              width: parent.width
              height: connLine.implicitHeight + Style.space(20)
              radius: Style.space(8)
              color: selected || connMouse.containsMouse ? root.rowHighlight : "transparent"
              border.width: selected ? 1 : 0
              border.color: root.accent

              Item {
                id: connLine
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                implicitHeight: Math.max(times.implicitHeight, connBadges.implicitHeight)

                Column {
                  id: times
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(2)

                  Text {
                    text: connRow.modelData.depTime + " → " + connRow.modelData.arrTime
                    textFormat: Text.PlainText
                    color: connRow.modelData.cancelled ? root.dim : root.fg
                    font.family: root.fontFamily
                    font.pixelSize: root.fontLarge
                    font.bold: true
                    font.strikeout: connRow.modelData.cancelled
                  }

                  Text {
                    text: connRow.modelData.duration + " · " + connRow.modelData.changes
                    textFormat: Text.PlainText
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                }

                Row {
                  id: connBadges
                  anchors.left: times.right
                  anchors.leftMargin: Style.space(14)
                  anchors.right: connPlatform.left
                  anchors.rightMargin: Style.space(14)
                  anchors.verticalCenter: parent.verticalCenter
                  clip: true
                  spacing: Style.space(4)

                  Repeater {
                    model: connRow.modelData.lines

                    LineBadge {
                      required property var modelData
                      label: modelData.label
                      local: modelData.local
                      rail: root.railBadges
                      fg: root.fg
                      localFill: root.raised
                      fontFamily: root.fontFamily
                    }
                  }
                }

                Text {
                  id: connStatus
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(64)
                  horizontalAlignment: Text.AlignRight
                  text: Model.statusText(connRow.modelData)
                  textFormat: Text.PlainText
                  color: root.statusColor(connRow.modelData)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.weight: Font.Medium
                }

                Text {
                  id: connPlatform
                  anchors.right: connStatus.left
                  anchors.rightMargin: Style.space(14)
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(56)
                  horizontalAlignment: Text.AlignRight
                  text: connRow.modelData.platform ? "Pl. " + connRow.modelData.platform : ""
                  textFormat: Text.PlainText
                  color: root.platformColor
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.weight: Font.Medium
                }
              }

              MouseArea {
                id: connMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openConnection(connRow.index)
              }
            }
          }
        }
      }

      // ---- Connection details -------------------------------------------------
      Column {
        id: connectionColumn
        visible: root.view === "connection"
        width: parent.width
        spacing: Style.space(4)

        readonly property var conn: root.detailConnection

        Item {
          width: parent.width
          height: connTitle.implicitHeight + Style.space(12)

          Column {
            id: connTitle
            anchors.left: parent.left
            anchors.leftMargin: Style.space(12)
            anchors.right: connChip.left
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: connectionColumn.conn ? connectionColumn.conn.depTime + " → " + connectionColumn.conn.arrTime : ""
              textFormat: Text.PlainText
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              font.bold: true
            }

            Text {
              width: parent.width
              text: {
                var c = connectionColumn.conn
                if (!c) return ""
                return (c.fromName || root.routeFrom) + " → " + (c.toName || root.routeTo) + " · " + c.duration + " · " + c.changes
              }
              textFormat: Text.PlainText
              elide: Text.ElideRight
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          StatusChip {
            id: connChip
            anchors.right: parent.right
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            color: root.faint
            dot: root.statusColor(connectionColumn.conn)
            textColor: root.statusColor(connectionColumn.conn)
            fontFamily: root.fontFamily
            text: connectionColumn.conn ? Model.statusText(connectionColumn.conn) : ""
          }

          Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width
            height: Style.spacing.hairline
            color: root.hairline
          }
        }

        Repeater {
          model: connectionColumn.conn ? connectionColumn.conn.legs : []

          Item {
            id: leg
            required property var modelData
            required property int index
            readonly property bool ride: modelData.kind === "ride"
            width: connectionColumn.width
            implicitHeight: ride ? rideBlock.implicitHeight + Style.space(10) : walkText.implicitHeight + Style.space(10)

            // Walk between two rides
            Text {
              id: walkText
              visible: !leg.ride
              anchors.left: parent.left
              anchors.leftMargin: Style.space(12) + root.colTime
              anchors.verticalCenter: parent.verticalCenter
              text: "walk" + (leg.modelData.minutes !== null && leg.modelData.minutes !== undefined ? " · " + leg.modelData.minutes + " min" : "")
                + (leg.modelData.to ? " to " + leg.modelData.to : "")
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.italic: true
            }

            // Ride: departure, line, arrival
            Rectangle {
              id: rideBlock
              visible: leg.ride
              x: Style.space(4)
              width: parent.width - Style.space(8)
              implicitHeight: rideColumn.implicitHeight + Style.space(14)
              anchors.verticalCenter: parent.verticalCenter
              radius: Style.space(8)
              color: root.surface

              Column {
                id: rideColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: Style.space(8)
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(6)

                Repeater {
                  model: leg.ride ? [
                    { time: leg.modelData.depTime, station: leg.modelData.from, platform: leg.modelData.depPlatform, delay: leg.modelData.delay },
                    null,
                    { time: leg.modelData.arrTime, station: leg.modelData.to, platform: leg.modelData.arrPlatform, delay: 0 }
                  ] : []

                  Item {
                    required property var modelData
                    width: rideColumn.width
                    implicitHeight: modelData ? stopRow.implicitHeight : lineRow.implicitHeight

                    Row {
                      id: stopRow
                      visible: parent.modelData !== null
                      width: parent.width

                      Text {
                        width: root.colTime
                        text: parent.parent.modelData ? parent.parent.modelData.time : ""
                        textFormat: Text.PlainText
                        color: root.fg
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.subtitle
                        font.bold: true
                      }

                      Text {
                        width: parent.width - root.colTime - Style.space(96)
                        text: parent.parent.modelData ? parent.parent.modelData.station : ""
                        textFormat: Text.PlainText
                        elide: Text.ElideRight
                        color: root.fg
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.subtitle
                      }

                      Text {
                        width: Style.space(40)
                        horizontalAlignment: Text.AlignRight
                        text: parent.parent.modelData && parent.parent.modelData.delay > 0 ? "+" + parent.parent.modelData.delay + "'" : ""
                        textFormat: Text.PlainText
                        color: root.delayColor
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                        font.weight: Font.Medium
                      }

                      Text {
                        width: Style.space(56)
                        horizontalAlignment: Text.AlignRight
                        text: parent.parent.modelData && parent.parent.modelData.platform ? "Pl. " + parent.parent.modelData.platform : ""
                        textFormat: Text.PlainText
                        color: root.platformColor
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                        font.weight: Font.Medium
                      }
                    }

                    Row {
                      id: lineRow
                      visible: parent.modelData === null
                      x: root.colTime
                      spacing: Style.space(8)

                      LineBadge {
                        anchors.verticalCenter: parent.verticalCenter
                        label: leg.modelData.line || ""
                        local: leg.modelData.local === true
                        rail: root.railBadges
                        fg: root.fg
                        localFill: root.raised
                        fontFamily: root.fontFamily
                      }

                      Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: leg.modelData.toward ? "towards " + leg.modelData.toward : ""
                        textFormat: Text.PlainText
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                      }
                    }
                  }
                }
              }
            }
          }
        }

        Item { width: 1; height: Style.space(6) }
      }

      // ---- Settings -------------------------------------------------------------
      Column {
        id: settingsColumn
        visible: root.view === "settings"
        width: parent.width
        spacing: Style.space(2)

        // Header: train icon + "SBB settings"
        Row {
          x: Style.space(12)
          height: settingsTitle.implicitHeight + Style.space(20)
          spacing: Style.space(10)

          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(16)
            height: width
            radius: Style.space(4)
            color: Palette.rail

            Text {
              anchors.centerIn: parent
              text: "󰔬"
              textFormat: Text.PlainText
              color: "#ffffff"
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          Text {
            id: settingsTitle
            anchors.verticalCenter: parent.verticalCenter
            text: "SBB settings"
            textFormat: Text.PlainText
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: root.fontLarge
            font.bold: true
          }
        }

        SettingRow {
          label: "Home station"; description: "used by the bar module"
          current: root.settingsCursor === 0
          fg: root.fg; dim: root.dim; highlight: root.rowHighlight; fontFamily: root.fontFamily
          onActivated: root.activateSetting(0)

          SettingField {
            id: homeField
            value: root.homeStation
            fg: root.fg; fill: root.surface; borderColor: root.hairline; accent: root.accent; fontFamily: root.fontFamily
            onCommitted: function(text) { root.commitHome(text) }
            onCancelled: root.focusKeys()
          }
        }

        SettingRow {
          label: "Refresh interval"; description: "how often departures are fetched"
          current: root.settingsCursor === 1
          fg: root.fg; dim: root.dim; highlight: root.rowHighlight; fontFamily: root.fontFamily
          onActivated: root.activateSetting(1)

          SettingField {
            id: refreshField
            numeric: true
            value: String(root.refreshSeconds)
            suffix: "s"
            fg: root.fg; fill: root.surface; borderColor: root.hairline; accent: root.accent; fontFamily: root.fontFamily
            onCommitted: function(text) { root.commitNumber("refreshSeconds", text, 30, 600) }
            onCancelled: root.focusKeys()
          }
        }

        SettingRow {
          label: "Delay alert"; description: "notify when late by at least (0 = off)"
          current: root.settingsCursor === 2
          fg: root.fg; dim: root.dim; highlight: root.rowHighlight; fontFamily: root.fontFamily
          onActivated: root.activateSetting(2)

          SettingField {
            id: delayField
            numeric: true
            value: String(root.delayAlertMinutes)
            suffix: "'"
            fg: root.fg; fill: root.surface; borderColor: root.hairline; accent: root.accent; fontFamily: root.fontFamily
            onCommitted: function(text) { root.commitNumber("delayAlertMinutes", text, 0, 30) }
            onCancelled: root.focusKeys()
          }
        }

        SettingRow {
          label: "Results"; description: "connections per route search, favourites too"
          current: root.settingsCursor === 3
          fg: root.fg; dim: root.dim; highlight: root.rowHighlight; fontFamily: root.fontFamily
          onActivated: root.activateSetting(3)

          SettingField {
            id: resultsField
            numeric: true
            value: String(root.connectionCount)
            fg: root.fg; fill: root.surface; borderColor: root.hairline; accent: root.accent; fontFamily: root.fontFamily
            onCommitted: function(text) { root.commitNumber("connections", text, 1, 10) }
            onCancelled: root.focusKeys()
          }
        }

        SettingRow {
          label: "Show in bar"; description: "next departure from home station"
          current: root.settingsCursor === 4
          fg: root.fg; dim: root.dim; highlight: root.rowHighlight; fontFamily: root.fontFamily
          onActivated: root.activateSetting(4)

          SbbToggle {
            checked: root.showInBar
            onColor: root.accent
            offColor: root.raised
            knobOn: root.figma ? Palette.base : Color.popups.background
            knobOff: root.dim
          }
        }

        SettingRow {
          label: "Follow Omarchy theme"; description: "reuse colours from the active theme"
          current: root.settingsCursor === 5
          fg: root.fg; dim: root.dim; highlight: root.rowHighlight; fontFamily: root.fontFamily
          onActivated: root.activateSetting(5)

          SbbToggle {
            checked: !root.figma
            onColor: root.accent
            offColor: root.raised
            knobOn: root.figma ? Palette.base : Color.popups.background
            knobOff: root.dim
          }
        }

        Item { width: 1; height: Style.space(6) }

        ColumnLabel {
          x: Style.space(10)
          bottomPadding: Style.space(4)
          fg: root.dim
          fontFamily: root.fontFamily
          text: "FAVOURITE ROUTES"
        }

        Text {
          visible: root.favourites.length === 0
          x: Style.space(10)
          bottomPadding: Style.space(8)
          text: "Save one with ctrl s in the route search."
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        Repeater {
          model: root.favourites

          Rectangle {
            id: favRow
            required property var modelData
            required property int index
            readonly property int row: root.settingsFixedRows + index
            readonly property bool current: root.settingsCursor === row

            x: Style.space(10)
            width: settingsColumn.width - Style.space(20)
            height: favRouteText.implicitHeight + Style.space(14)
            radius: Style.space(6)
            color: favRowMouse.containsMouse ? root.raised : root.surface
            border.width: current ? 1 : 0
            border.color: root.accent

            MouseArea {
              id: favRowMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.activateSetting(favRow.row)
            }

            Text {
              id: favRouteText
              anchors.left: parent.left
              anchors.leftMargin: Style.space(10)
              anchors.right: favKeys.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              text: favRow.modelData.from + " → " + favRow.modelData.to
              textFormat: Text.PlainText
              elide: Text.ElideRight
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Row {
              id: favKeys
              anchors.right: parent.right
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(10)

              Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: favRow.index < 9
                text: "super+ctrl+alt+" + (favRow.index + 1)
                textFormat: Text.PlainText
                color: root.platformColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.weight: Font.Medium
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: favRow.current || favRowMouse.containsMouse || removeMouse.containsMouse
                text: "×"
                textFormat: Text.PlainText
                color: removeMouse.containsMouse ? root.cancelColor : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle

                MouseArea {
                  id: removeMouse
                  anchors.fill: parent
                  anchors.margins: -Style.space(4)
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.removeFavouriteAt(favRow.index)
                }
              }
            }
          }
        }

        Item { width: 1; height: Style.space(8) }
      }

      // ---- Footer hints -------------------------------------------------------
      Rectangle {
        id: footer
        // Figma: a full-width bg/deep strip along the bottom of the window.
        readonly property int bleed: root.figma ? panel.padding : 0
        anchors.bottom: parent.bottom
        anchors.bottomMargin: -bleed
        x: -bleed
        width: parent.width + bleed * 2
        implicitHeight: hintRow.implicitHeight + Style.space(root.figma ? 18 : 12)
        height: implicitHeight
        radius: root.figma ? 0 : Style.cornerRadius
        bottomLeftRadius: root.figma ? Math.max(0, Style.cornerRadius - 2) : Style.cornerRadius
        bottomRightRadius: bottomLeftRadius
        color: root.deep

        // "saved as favourite 3 · super+ctrl+alt+3" and friends, in place of
        // the hints for a few seconds.
        Text {
          anchors.left: parent.left
          anchors.leftMargin: Style.space(14) + footer.bleed
          anchors.verticalCenter: parent.verticalCenter
          visible: root.routeNotice !== ""
          text: (root.routeNotice.indexOf("saved") === 0 ? "✓ " : "") + root.routeNotice
          textFormat: Text.PlainText
          color: root.routeNotice.indexOf("saved") === 0 ? root.onTimeColor : root.subtle
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Row {
          id: hintRow
          anchors.left: parent.left
          anchors.leftMargin: Style.space(12) + footer.bleed
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(16)

          Repeater {
            model: root.routeNotice !== "" ? [] : root.hints

            KeyHint {
              required property var modelData
              fg: root.fg
              capFill: root.surface
              capBorder: root.hairline
              capText: root.subtle
              labelColor: root.dim
              fontFamily: root.fontFamily
              keys: modelData[0]
              action: modelData[1]
            }
          }
        }
      }
    }
  }
}
