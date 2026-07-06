# Visual-regression templates

Copy these into a project that has UI-visible changes, then generate baselines in the pinned container.

```
cp -R ~/agent-firm/agent-firm/templates/visual/{playwright.config.ts,tests} <project>/
cd <project>
npm i -D @playwright/test          # NOTE: @playwright/test, not the bare `playwright` library

# Generate Linux baselines in a version-matched Playwright image (baselines are per browser+OS):
docker run --rm -it -v "$PWD:/work" -w /work mcr.microsoft.com/playwright:v1.61.0-noble \
  npx playwright test --update-snapshots=changed
git add tests/__screenshots__ && git commit -m "visual baselines"
```

Then the firm gates on visuals automatically:
- `firm-visual-check` (what `qa-tester` runs): asserts against committed baselines, `--update-snapshots=none`,
  never writes them. A diff is a **BLOCK**.
- `firm-visual-baseline` (human-only): regenerates changed baselines for a **reviewed** update. QA never calls it.

Determinism levers already wired in the templates: `animations:'disabled'`, `caret:'hide'`,
`stylePath` (`tests/screenshot.css` kills animations/transitions/caret), per-test `mask` for live regions,
and `maxDiffPixelRatio: 0.01` for anti-aliasing noise. Baselines are only valid for the exact image that
generated them — pin the Playwright image tag to your `@playwright/test` version and bump them together.
