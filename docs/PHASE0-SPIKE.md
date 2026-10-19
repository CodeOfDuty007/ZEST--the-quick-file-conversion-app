# Phase 0 spike: human test script

Build with `make app`, then launch with:

```sh
pkill -x Zest; open build/DerivedData/Build/Products/Debug/Zest.app
```

`make launch` relaunches the last build without rebuilding.

The app lives in the menu bar (pie icon). Every event is appended to
`~/Library/Logs/Zest/spike.log`.

## One-time setup
1. Click the menu-bar icon, press **Request** next to Input Monitoring and Accessibility,
   and enable Zest in System Settings > Privacy & Security.
2. Relaunch with the command above. macOS applies these grants at launch.
3. Note which prompt appears for which request. That answers "which permission does each API trigger".

## Signing and rebuilds
`make cert` (run once) creates a local "Zest Dev" identity in its own keychain, and
`make app` re-signs the build with it. Its code requirement does not change between
builds, so Accessibility and Input Monitoring grants **survive rebuilds**. Without the
identity the build is ad-hoc signed, macOS treats every rebuild as a new app, and stale
entries stay in System Settings looking enabled but do not apply. In that case clear them:

```sh
tccutil reset Accessibility org.zest.Zest
tccutil reset ListenEvent org.zest.Zest
```

Granting permission after switching from ad-hoc to the dev identity needs one fresh grant.

## Spike questions and how to answer them
| Question | Test | Look for in the log |
| --- | --- | --- |
| Does a panel shown mid-drag receive `draggingEntered`? | Drag a PNG from Finder, tap Shift, move onto the ring | `Panel received draggingEntered` |
| Does the wheel stay open while crossing from centre to a wedge? | Same drag, move slowly from the middle to a wedge | No `Wheel closed (draggingExited)` before the drop |
| Which permission does modifier detection need? | Use each Modifier detection option with grants on and off | `Shift down mid-drag` appears, or Modifier events stays 0 |
| Does `changeCount` advance for non-Finder drags? | Drag an image from Safari, an attachment from Mail, a file from VS Code | `File drag:` line, or `Drag without file URLs` |
| Latency, cold and after idle | Tap Shift mid-drag; repeat after 10+ minutes idle | `Wheel shown: N ms … (idle S s)` |
| Does Finder move the source on `.copy`? | Drop on a wedge | `Source files still present after drop: true` and the file is still in Finder |
| Does a normal drop still work afterwards? | Drag a file to a Finder folder (not the wheel), then drag again | The next drag still logs `File drag:` |
| App Nap opt-out | Turn the toggle off, wait, repeat | Compare `Wheel shown` times |
