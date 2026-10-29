# website/AGENTS.md

Read before editing anything under `website/`. The [root rules](../AGENTS.md) also apply.
Start with [README.md](README.md) for the file map, local preview, deployment, and rollback steps.

## Keep the site simple

- Maintain one static landing page in plain HTML, CSS, and SVG. Preserve the working experience
  without runtime JavaScript or a frontend build. Add dependencies or services only when the
  requested behavior needs them.
- `public/` is the entire published directory. Keep agent instructions, documentation, package
  files, credentials, and development output outside it. Unknown URLs return 404.
- Use the existing npm scripts and pinned Wrangler dependency. Keep `package.json` and
  `package-lock.json` in sync when changing dependencies.

## Match Jarvis Settings

- Use the app's [Settings theme](../Sources/JarvisApp/Settings/SettingsTheme.swift) and
  [spacing and shape tokens](../Sources/JarvisApp/Settings/SettingsStyle.swift) as the visual
  reference: purple structure, teal accents, a soft radial backdrop, and rounded panels.
- Keep colors in the existing CSS variables, with system light and dark appearances. Preserve
  the deeper light-mode `--purple-ink` for readable small text; check contrast across the gradient,
  not just against white. The robot SVG has its own appearance-aware palette.
- Adapt the existing [robot geometry](../Sources/JarvisApp/Settings/Home/RobotHeadView+Geometry.swift)
  when changing the illustration. Favor the existing system fonts, CSS, and local SVG assets.
- Preserve responsive layouts, semantic HTML, keyboard focus, the skip link, and native FAQ
  disclosures. Any added motion must respect reduced-motion preferences.

## Keep product claims accurate

- Ground copy in the [project README](../README.md) and [wiki](../wiki/index.md). The
  [voice-only contract](../wiki/architecture.md#1-vision) means spoken input and on-screen replies.
- Keep system requirements, provider setup, and [privacy details](../wiki/sandbox.md) accurate.
  A private overlay is not a claim that all processing or storage stays on the device.
- Use the existing latest-release download URL so app releases need no routine website edit.
  Keep example hints visibly illustrative. Do not invent testimonials, usage figures, or features,
  or publish private session content in screenshots or examples.

## Validate and deploy

- Follow the [README checks](README.md#edit-and-preview) for rendered changes: desktop and narrow
  mobile layouts, both color schemes, keyboard navigation, FAQ operation, and working links.
  Check browser errors and contrast, including text over gradients. Verify asset responses and
  404s through Wrangler when changing routing, headers, or the published directory.
- Validate deployment configuration with the README's dry-run command when changing deployment
  inputs. For instruction-only edits, check links and consistency with the actual files and scripts;
  a browser rerun is unnecessary when the rendered site is unchanged.
- The root repository Gate still applies. It requires macOS; on other hosts, use the PR's existing
  macOS CI and report the result for the current commit. Website checks do not replace that Gate.
- Keep deployment and hosting on Cloudflare Workers Static Assets, using its Git integration.
  Keep the README aligned with the Worker configuration and published directory. Do not assume
  account integration or a custom domain exists just because the configuration is committed;
  report publication only after verifying the deployment. Never commit Cloudflare credentials.
