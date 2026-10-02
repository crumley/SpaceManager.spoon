# SpaceManager.spoon

A [Hammerspoon](http://www.hammerspoon.org/) Spoon that gives macOS Spaces
names, shows the current one in a lozenge on the desktop, and keeps Google
Chrome windows named after the space they are on.

## What it does

- **Space names.** A configured default per space index (`spaceConfig`), a
  custom name per space set through the menu (`show()`), and a desktop lozenge
  (`desktopLozenge`) that shows the current space's name and position.
- **Dock on the first space only** (`dockOnPrimaryOnly`).
- **Chrome window names** (`chromeWindowNames`). An unnamed Chrome window
  takes the position and name of the space it is on, led by a colored square
  close to the space's color (`chromeWindowMarkers`) -- `🟥 01 - Today` -- set
  through Chrome's own `Window > Name Window...` (its scripting `givenName`),
  so the name shows in the tab strip and survives Chrome restarts. A second
  window wanting a name already in use gets ` 2`, then ` 3`. A window that
  has a name keeps it, whoever gave it and wherever it is dragged, until its
  space is renamed: then every window on that space takes the new name (or
  loses its name if the space's was cleared). Windows on an unnamed space are
  left unnamed. Reconciled when a Chrome window appears, when the active space
  changes, on wake or unlock, and every `chromeNamesInterval` seconds.
- **A daily window** (`dailyWindow`). Once a day a fresh Chrome window named
  for the date (`dailyWindowDateFormat`) opens on the space at
  `dailyWindowSpaceIndex` -- only while that space is showing, since Chrome
  opens a new window on the current space and moving a window between spaces
  is not reliable on current macOS. Closing it does not summon another; its
  date name is never overwritten, even when its space is renamed.

## Install

Clone (or add as a submodule) into `~/.hammerspoon/Spoons/SpaceManager.spoon`,
then in `init.lua`:

```lua
hs.loadSpoon('SpaceManager')
spoon.SpaceManager.dockOnPrimaryOnly = true
spoon.SpaceManager.desktopLozenge = true
spoon.SpaceManager.spaceConfig = { [1] = "Today" }
spoon.SpaceManager.chromeWindowNames = true
spoon.SpaceManager.dailyWindow = true
spoon.SpaceManager:start()

hs.hotkey.bind({"ctrl", "cmd", "option"}, "G", function() spoon.SpaceManager:show() end)
```

## Development

The pure modules (`chrome.lua`: pairing Chrome's scripting windows with
Hammerspoon's and deciding names; `state.lua`: persisted space names) are unit
tested under plain Lua; `init.lua` talks to Hammerspoon and Chrome and is
exercised in Hammerspoon by hand.

```
mise install      # actionlint
mise run check    # syntax, tests, workflow lint -- what CI runs
lua test/run.lua  # just the tests
```

A note for driving `init.lua` from the `hs` command line: the Chrome calls are
Apple Events, which spin a nested run loop. Run them from a timer
(`hs -c "hs.timer.doAfter(0, function() ... end)"`) rather than inline in the
IPC call, or Hammerspoon's IPC port refuses the re-entrant request.
