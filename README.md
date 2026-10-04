# SpaceManager.spoon

A [Hammerspoon](http://www.hammerspoon.org/) Spoon that gives macOS Spaces
names, shows the current one in a lozenge on the desktop, and keeps Google
Chrome windows named after the space they are on.

## What it does

- **Space names.** A configured default per space index (`spaceConfig`), a
  custom name per space set through the menu (`show()`), and a desktop lozenge
  (`desktopLozenge`) that shows the current space's name and position.
- **A Mission Control legend** (`toggleMissionControl()`, bind it to a
  hotkey). Opens Mission Control with a lozenge per space stacked in the
  bottom-left corner, in the desktop lozenge's colors and font --
  `01 - Today`, `02 - <untitled>` -- with the current one outlined, so you can
  tell which "Desktop N" to drag a window to. The spaces bar is left as is, so its previews still expand on hover.
  Calling it again closes both; closing Mission Control any other way removes
  the legend. Mission Control opened by a hot corner, F3 or a swipe shows no
  legend.
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
- **An Inbox** (`inbox`, with `linkRouting`). One Chrome window, named
  `📥 Inbox` (`inboxName`), that clicked links land in -- see Link routing.
  With the SpaceManager Inbox extension loaded, every new tab in it goes into
  a tab group for the day it was opened (`📅 Sat, Oct 4`), so you can tell
  today's links from last week's. When a link needs the Inbox and there is
  none, a new one opens on the space showing, its first tab the extension's
  page (`inboxPage`), which pins itself and is how the extension knows the
  window. Its name is never overwritten by Chrome window names.

  The extension is in `chrome-extension/`. Load it once per machine, without
  the Chrome Web Store: `chrome://extensions`, turn on Developer mode, Load
  unpacked, and choose `~/.hammerspoon/Spoons/SpaceManager.spoon/chrome-extension`.
  Its manifest carries a fixed key, so its id (in `inboxPage`) is the same on
  every machine. After the folder changes, press its reload button there.
- **Link routing** (`linkRouting`, off by default). A link clicked in another
  app opens as a new tab in the frontmost Chrome window on the space showing,
  instead of in whichever window Chrome last used -- which pulls the screen to
  that window's space. Hammerspoon becomes the default browser for this
  (macOS asks once). With the Inbox on, a link opens in the Inbox when it is on
  the space showing, over any other window there. With no Chrome window on the
  space showing, `linkRoutingNoChrome` decides: `"newWindow"` (the default)
  opens a new one there, `"inbox"` opens the link in the Inbox wherever it is
  -- macOS moves to its space -- or in a new Inbox here, and `"chrome"` hands
  the link to Chrome. A
  link that cannot be routed is handed to Chrome as usual, and with routing
  off while Hammerspoon is still the default browser, links pass straight
  through to Chrome. Links clicked inside Chrome are not affected.

## Install

Clone (or add as a submodule) into `~/.hammerspoon/Spoons/SpaceManager.spoon`,
then in `init.lua`:

```lua
hs.loadSpoon('SpaceManager')
spoon.SpaceManager.dockOnPrimaryOnly = true
spoon.SpaceManager.desktopLozenge = true
spoon.SpaceManager.spaceConfig = { [1] = "Today" }
spoon.SpaceManager.chromeWindowNames = true
spoon.SpaceManager.linkRouting = true
spoon.SpaceManager.inbox = true
spoon.SpaceManager.linkRoutingNoChrome = "inbox"
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
