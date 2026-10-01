# SpaceManager.spoon

A [Hammerspoon](http://www.hammerspoon.org/) Spoon that gives macOS Spaces
names, shows the current one in a lozenge on the desktop, and keeps Google
Chrome windows named after the space they are on.

## What it does

- **Space names.** A configured default per space index (`spaceConfig`), a
  custom name per space set through the menu (`show()`), and a desktop lozenge
  (`desktopLozenge`) that shows the current space's name and position.
- **Dock on the first space only** (`dockOnPrimaryOnly`).
- **Chrome window names** (`chromeWindowNames`). Every Chrome window carries
  the name of the space it is on, set through Chrome's own `Window > Name
  Window...` (its scripting `givenName`), so the name shows in the tab strip
  and survives Chrome restarts. Names are reconciled when a Chrome window
  appears, when the active space changes, on wake or unlock, and every
  `chromeNamesInterval` seconds; a window dragged to another space picks up
  that space's name on the next pass. Only names this spoon gave are ever
  overwritten: a window you named yourself is left alone, and a window on an
  unnamed space has its spoon-given name cleared.
- **A daily window** (`dailyWindow`). Once a day a fresh Chrome window named
  for the date (`dailyWindowDateFormat`) opens on the space at
  `dailyWindowSpaceIndex`, only while that space is showing or the machine has
  been idle for `dailyWindowIdleSeconds`. Closing it does not summon another;
  its date name is never overwritten by the space's name.

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
