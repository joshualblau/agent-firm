// Firm visual-regression config template. Copy into a project that has UI-visible changes.
// Requires @playwright/test (NOT the bare `playwright` library). Verified against Playwright v1.61.
import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  testDir: './tests',
  // Deterministic, cross-machine baseline paths (keeps per-project + per-platform separation).
  snapshotPathTemplate: '{testDir}/__screenshots__{/projectName}/{testFilePath}/{arg}{ext}',
  expect: {
    toHaveScreenshot: {
      threshold: 0.2,            // per-pixel YIQ color tolerance (Playwright default)
      maxDiffPixelRatio: 0.01,   // tolerate up to 1% differing pixels (anti-aliasing noise)
      animations: 'disabled',    // default for toHaveScreenshot; explicit for clarity
      caret: 'hide',             // default; stops a blinking caret from flaking a run
      scale: 'css',              // default; stable across HiDPI runners
      stylePath: './tests/screenshot.css',
    },
  },
  // Pin ONE browser for baselines. Baselines are only valid for the exact browser+OS that made them.
  projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],
});
