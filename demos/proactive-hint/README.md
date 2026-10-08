# Jarvis proactive hint scene

A silent, ten-second HTML mock for reviewing the Jarvis demo's layout and pacing. An interviewer asks about a Two Sum solution; Jarvis offers a proactive hash-map hint while the conversation continues. All content is synthetic.

## Preview

Requires Node.js 22+ and npm.

```sh
npm ci
npm run check
npm run preview
```

Open [HyperFrames Studio](http://localhost:4318/#project/proactive-hint) and select Play. The timeline can pause, replay, and seek. The managed preview continues running after the terminal command exits; stop it with `npm run stop`.

`npm ci` prepares a local GSAP asset, so playback does not depend on a CDN. Node modules, generated assets, snapshots, and renders are ignored by Git.

## Review and edit

- `BRIEF.md`: story and review scope.
- `frame.md`: composition and visual direction.
- `index.html`: UI, copy, and the paused deterministic GSAP timeline.
- `index.motion.json`: motion assertions checked by HyperFrames.

Run `npm run snapshots` to inspect four key frames. After visual approval, `npm run render` can export the scene at 30 fps. FFmpeg and HyperFrames' browser runtime are required for rendering.

The call and code editor are illustrative. The floating Jarvis panel follows the app's header and timestamp hierarchy. Dialogue captions belong to the film; they are not a product feature.
