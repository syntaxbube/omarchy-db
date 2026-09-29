# SBB for Omarchy

Your next Swiss train, right in the Omarchy bar. Know whether the IR 70 is on
time *before* you sprint to platform 8, not after.

<p align="center">
  <img src="screenshots/board.png" alt="The bar pill and the departures board" width="620">
</p>

## What you get

- **A bar pill** with your next train: line, destination, time, and a countdown.
  Late? It says `+4'`. Cancelled? It says so, sadly.
- **A departures board** (click the pill). Hit `Enter` on a train to see its
  stops and whether the platform changed on you.
- **Route search** (right click). Type `Luzern`, or `Bern > Thun`, press
  `Enter`, done. Pick "in 30 min" if you're running late on purpose.
- **Favourite routes.** `ctrl s` saves one, `ctrl 1`–`9` brings it back.
- **Delay alerts.** A notification when your train is late or cancelled, so
  you can finish your coffee.
- **Settings inside the popup** (`,` on the board). No config files needed.

<p align="center">
  <img src="screenshots/route-search.png" alt="Route search" width="560">
</p>

## Install

```sh
omarchy plugin add https://github.com/vvkycodevv/omarchy-sbb.git --enable
```

It shows up on the right of the bar. Prefer the middle?

```sh
omarchy bar move vvkycodevv.sbb --section center
```

## Driving it

| Where | Keys |
| --- | --- |
| Pill | left click: board · right click: route search · middle click: refresh |
| Board | `↑↓` pick a train · `Enter` details · `/` search · `r` refresh · `,` settings · `Esc` close |
| Route search | `Enter` search / open a connection · `Tab` swap from and to · `ctrl s` save favourite · `ctrl t` later departures · `ctrl 1`–`9` favourites · `Esc` back or close |
| Settings | `↑↓` move · `Enter` edit or toggle · `x` delete a favourite · `Esc` back |

## Settings

Change them in the popup (`,` on the board), in Setup > Bar, or in the widget's
entry in `~/.config/omarchy/shell.json`.

| Key | Default | What it does |
| --- | --- | --- |
| `homeStation` | `Zürich HB` | Where the board and pill look for trains |
| `barDestination` | empty | Only follow trains that stop here, e.g. `Luzern` |
| `barStyle` | `Full` | `Compact` keeps just the time and status |
| `showInBar` | `true` | `false` leaves only the little train icon |
| `palette` | `Figma` | `Theme` follows your Omarchy theme instead of Tokyo Night |
| `departures` | `8` | Trains on the board (3–20) |
| `connections` | `5` | Results per route search, favourites too (1–10) |
| `refreshSeconds` | `60` | How often to check the timetable |
| `delayAlertMinutes` | `3` | Notify at this delay; `0` means "don't tell me" |
| `badgeStyle` | `Rail red` | `Theme` for calmer line badges |
| `favourites` | empty | `From > To`, separated by `;`, e.g. `Bern > Thun; Basel SBB > Olten` |

## Keyboard shortcuts (optional)

The plugin doesn't add any global shortcuts by itself. For some, paste this into
`~/.config/hypr/bindings.lua`. First check the keys are free with
`omarchy menu keybindings --print`. (Favourites live on `super+ctrl+alt`
because Omarchy already uses `super+alt+1`–`5` for window groups.)

```lua
o.bind("SUPER + ALT + T", "SBB departures", "omarchy-shell shell toggle vvkycodevv.sbb '{}'")
o.bind("SUPER + ALT + R", "SBB route search", "omarchy-shell vvkycodevv.sbb toggleSearch")
for i = 1, 9 do
  o.bind("SUPER + CTRL + ALT + " .. i, "SBB favourite route " .. i, "omarchy-shell vvkycodevv.sbb favourite " .. i)
end
```

The same things work from any script:

```sh
omarchy-shell vvkycodevv.sbb route "Bern" "Thun"
omarchy-shell vvkycodevv.sbb favourite 1
omarchy-shell vvkycodevv.sbb settings
omarchy-shell vvkycodevv.sbb refresh
```

## Good to know

- Timetable data comes from [transport.opendata.ch](https://transport.opendata.ch):
  free, no account, no API key.
- It needs `curl` and `notify-send`, both already on Omarchy.
- The only file it writes is your own `shell.json`, when you change a setting
  or save a favourite. No daemon, no sudo.
- Like every Omarchy plugin, it runs unsandboxed with your user permissions.

## Remove

```sh
omarchy plugin remove vvkycodevv.sbb
```

No hard feelings. The trains will keep running without you.

## Hacking on it

```sh
git clone https://github.com/vvkycodevv/omarchy-sbb.git ~/.config/omarchy/plugins/vvkycodevv.sbb
TZ=Europe/Zurich node tests/model.test.js
omarchy plugin validate ~/.config/omarchy/plugins/vvkycodevv.sbb
```

After editing the QML, run `omarchy restart shell` if a change doesn't show up.

---

Not affiliated with SBB CFF FFS. Just a fan of trains that leave on time.
