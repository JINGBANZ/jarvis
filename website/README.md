# Jarvis landing page

One compact introduction with the Settings robot, a short description, one download button,
and links to setup, source, community, and privacy details. Hosted directly on Cloudflare Workers
Static Assets; `public/` is the entire deployed site. There is no frontend build, runtime JavaScript,
or backend.
Wrangler is the only development dependency, pinned in `package.json` and `package-lock.json`.

## Edit and preview

From this directory, with Node.js 22 or later:

```sh
npm ci
npm run dev
```

Open the localhost URL printed by Wrangler. This also exercises Cloudflare's asset routing
and `_headers`. Check desktop and narrow mobile widths, both system color schemes, keyboard
navigation, and the download and footer links before shipping. Missing URLs must return 404.

| File | Edit here for |
| --- | --- |
| `public/index.html` | Copy, links, and search/social metadata |
| `public/styles.css` | Layout and the light/dark CSS color variables |
| `public/assets/robot.svg` | The static Settings robot illustration and favicon |
| `public/_headers` | Response headers |
| `wrangler.jsonc` | Cloudflare Worker name, asset directory, and routing |

The colors come from [`SettingsTheme.swift`](../Sources/JarvisApp/Settings/SettingsTheme.swift),
the 12px button radius from [`SettingsStyle.swift`](../Sources/JarvisApp/Settings/SettingsStyle.swift),
and the robot paths from
[`RobotHeadView+Geometry.swift`](../Sources/JarvisApp/Settings/Home/RobotHeadView+Geometry.swift).
Keep those relationships when updating the design. The SVG carries its own small light/dark
palette because an image does not inherit the document's CSS variables.
`--purple-ink` slightly deepens the light-mode purple for small text to meet contrast requirements
against the lavender background; outlines and the large hero headline keep the app's exact color.

Download buttons use GitHub's `releases/latest/download/Jarvis.dmg` URL, so ordinary app releases
need no website edit. Keep platform requirements, provider setup, and privacy copy consistent
with the repository README and wiki. Link to the existing guides for detailed setup and privacy
information rather than growing the landing page into a manual.

## Connect Cloudflare once

In your Cloudflare account, create a Worker using the GitHub repository integration and authorize
access to `JINGBANZ/jarvis`. Configure these values:

| Setting | Value |
| --- | --- |
| Worker name | `jarvis-website` (must match `wrangler.jsonc`) |
| Production branch | `main` |
| Root directory | `website` |
| Build command | Leave empty |
| Deploy command | `npm run deploy` |
| Preview command | `npx wrangler preview` |
| Build watch include paths | `website/*` (relative to the repository root) |

Enable builds for non-production branches to get previews. Cloudflare installs the pinned npm
dependencies from the lockfile. Source stays on GitHub; Cloudflare runs deployment and serves
the page. No GitHub Actions deployment workflow or repository deployment token is needed.

The default `workers.dev` URL works before a custom domain is attached. Under **Settings →
Domains & Routes → Add → Custom domain**, attach the chosen hostname from an active zone in the
same Cloudflare account. Cloudflare manages its DNS record and TLS certificate. If both the apex
and `www` should work, choose a canonical hostname and configure Cloudflare's redirect rule for
the other. Once chosen, add that URL as the canonical URL and `og:url` in `index.html`.

Cloudflare setup is account state: committing these files does not create the Worker or connect
GitHub. For a manual deployment after authenticating locally:

```sh
npx wrangler login
npm run deploy
```

Do not put Cloudflare credentials in the repository. Account access should be granted through
Cloudflare's login and GitHub integration.

## Update and roll back

Open a PR for changes, check its Cloudflare preview, and merge to `main` to publish. Run the
repository Gate from the repository root on macOS:

```sh
swift build && ./scripts/run-tests.sh
```

To validate deployment configuration without publishing, run from `website/`:

```sh
npm run deploy -- --dry-run
```

For an urgent rollback, choose the previous version under the Worker's **Deployments** tab and
select **Rollback**. Then revert the corresponding source change through a PR so the next
deployment keeps the correction.

Cloudflare references: [static assets](https://developers.cloudflare.com/workers/static-assets/),
[Git build settings](https://developers.cloudflare.com/workers/ci-cd/builds/configuration/),
[build watch paths](https://developers.cloudflare.com/workers/ci-cd/builds/build-watch-paths/),
[custom domains](https://developers.cloudflare.com/workers/configuration/routing/custom-domains/),
[rollbacks](https://developers.cloudflare.com/workers/versions-and-deployments/rollbacks/).
