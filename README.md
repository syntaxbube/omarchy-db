# SBB for Omarchy

The next Swiss train in your Omarchy bar, a live departure board, and route
search, all inside the Omarchy shell. Timetable data comes from
[transport.opendata.ch](https://transport.opendata.ch) (free, no API key).

```
󰔬  IR 70 → Luzern 16:42 · +4'
```

## What it does

- **Bar pill:** the next departure from your home station. It shows a countdown
  when the train is on time, and the delay or "cancelled" when it is not. Late
  and cancelled trains take the theme's alert colour.
- **Departure board** (left click): time, line, destination, platform and
  status for the next departures, and how far ahead the board reaches
  ("departures · next 30 min"). A changed platform is marked with `!`.
- **Departure details** (`Enter` on a train): expected and planned time,
  platform (with the old one when it changed) and the stops with their times.
- **Route search** (right click, or `/` on the board): one line, like the
  Walker launcher: type `Luzern` (from your home station) or
  `Bern > Thun`. Station autocomplete for the half you are typing, a
  `now ▾` picker for later departures, and the next connections with duration,
  changes, lines, platform and status.
- **Connection details** (`Enter` on a connection): every ride with its line,
  times and platforms, and the walks between them.
- **Favourite routes:** `ctrl s` saves the route you searched. They show up in
  the route search (`ctrl 1` to `ctrl 9`) and in settings, and on
  `super+alt+1` to `super+alt+9` anywhere once you add the Hyprland bindings
  below. None are set up out of the box.
- **Settings view** (`,` on the board): home station, refresh interval, delay
  alert, number of route results, show in bar, follow Omarchy theme, and your
  favourites (`x` removes one). Changes are written to `shell.json` right away.
- **Delay notifications:** a desktop notification when the train the bar is
  following is late by your threshold or cancelled. Sent once per train, even
  with several monitors.
- **Colours:** by default the Tokyo Night palette from the Figma template (dark
  pill with a rail red icon, blue line, green / amber / red status). Set
  `palette` to `Theme` to follow the active Omarchy theme instead.

## Install

```sh
omarchy plugin add https://github.com/vvkycodevv/omarchy-sbb.git --enable
```

Or by hand while developing:

```sh
git clone https://github.com/vvkycodevv/omarchy-sbb.git ~/.config/omarchy/plugins/vvkycodevv.sbb
omarchy-shell shell rescanPlugins
omarchy plugin enable vvkycodevv.sbb
```

It starts in the right section of the bar. Move it with:

```sh
omarchy bar move vvkycodevv.sbb --section center
```

## Settings

Edit them in Setup > Bar, or inline on the widget's entry in
`~/.config/omarchy/shell.json`:

| Key | Default | Meaning |
| --- | --- | --- |
| `homeStation` | `Zürich HB` | Station for the board and the bar |
| `barDestination` | empty | Bar follows only trains stopping here, e.g. `Luzern` |
| `barStyle` | `Full` | `Full` or `Compact` (time and status only) |
| `showInBar` | `true` | `false` leaves only the train icon in the bar |
| `palette` | `Figma` | `Figma`: the Tokyo Night pill and panel from the design. `Theme`: follow the active Omarchy theme |
| `departures` | `8` | Rows on the board (3 to 20) |
| `connections` | `5` | Results per route search, favourites included (1 to 10) |
| `refreshSeconds` | `60` | How often the board is fetched |
| `delayAlertMinutes` | `3` | Notify at this delay; `0` turns alerts off |
| `badgeStyle` | `Rail red` | `Rail red` or `Theme` |
| `favourites` | empty | `From > To`, separated by `;`, e.g. `Bern > Thun; Basel SBB > Olten` |

## Keys

Board: `j`/`k` or arrows to move, `Enter` for details, `/` to search a route,
`r` to refresh, `,` for settings, `Esc` to close.

Departure details: arrows move to the previous/next train, `Enter` searches a
route to its destination, `Esc` goes back.

Route search: arrows pick a suggestion or a connection, `Enter` searches or
opens the connection, `Tab` swaps from and to, `Ctrl+S` saves the route as a
favourite, `Ctrl+T` steps through the departure time (now, in 15 min, …),
`Ctrl+1` to `Ctrl+9` load a favourite. `Esc` goes back to the board when you
came from it, and closes the popup otherwise (right click, `super+alt+N`).

Settings: arrows to move, `Enter` to edit or toggle, `x` removes a favourite,
`Esc` goes back.

Mouse: left click toggles the board, middle click refreshes, right click opens
route search.

## Shell commands and Hyprland bindings

```sh
omarchy-shell shell toggle vvkycodevv.sbb '{}'        # board (toggle)
omarchy-shell vvkycodevv.sbb toggleSearch              # route search (toggle)
omarchy-shell vvkycodevv.sbb search                    # route search
omarchy-shell vvkycodevv.sbb route "Bern" "Thun"
omarchy-shell vvkycodevv.sbb favourite 1
omarchy-shell vvkycodevv.sbb settings
omarchy-shell vvkycodevv.sbb refresh
```

Optional shortcuts. Add them to `~/.config/hypr/bindings.lua` (check
`omarchy menu keybindings --print` first that the keys are free on your
setup): `super+alt+T` toggles the board,
`super+alt+R` the route search, and `super+alt+1` to `9` open a favourite (a
number without a favourite opens the search with your favourites listed).

```lua
o.bind("SUPER + ALT + T", "SBB departures", "omarchy-shell shell toggle vvkycodevv.sbb '{}'")
o.bind("SUPER + ALT + R", "SBB route search", "omarchy-shell vvkycodevv.sbb toggleSearch")
for i = 1, 9 do
  o.bind("SUPER + ALT + " .. i, "SBB favourite route " .. i, "omarchy-shell vvkycodevv.sbb favourite " .. i)
end
```

## Dependencies and privileges

- `curl` for the timetable requests (to `transport.opendata.ch` only)
- `notify-send` for delay alerts (libnotify, present on Omarchy)

No daemon, no sudo. The only file written is your own `shell.json`, through
`omarchy bar set`, when you change a setting or save a favourite. Like every
Omarchy plugin it runs unsandboxed inside `omarchy-shell` with your user
permissions.

## Develop

```sh
TZ=Europe/Zurich node tests/model.test.js
omarchy plugin validate .
qmllint -I "$OMARCHY_PATH/shell" BarWidget.qml Panel.qml
qs log -p "$OMARCHY_PATH/shell" --tail 100      # QML errors at runtime
```

## Remove

```sh
omarchy plugin remove vvkycodevv.sbb
```

Not affiliated with SBB CFF FFS.
