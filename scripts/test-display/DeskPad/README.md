# DeskPad display interface

`CGVirtualDisplayPrivate.h` and `LICENSE.md` come from
[Stengo/DeskPad](https://github.com/Stengo/DeskPad) at
`c3349f0e237e000cb4826fb3ea1cdd1c44949461`.
The header is unchanged except that the display initializer is marked nullable:
creation can fail, and the test runner must report that without launching tests.

`../TestDisplay.swift` adapts the display-creation portion of
`DeskPad/Frontend/Screen/ScreenViewController.swift` from the same revision.
It selects one fixed Retina mode and uses a separate display identity. The MIT
license here covers that adapted code as well. No preview, screen capture, mouse
tracking, application installation, or third-party runtime is used.

These private macOS interfaces belong only to the test helper, not the Jarvis app.
