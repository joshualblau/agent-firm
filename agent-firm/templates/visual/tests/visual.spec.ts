// Firm visual-regression spec template. Mask dynamic regions; keep assertions deterministic.
import { test, expect } from '@playwright/test';

test('homepage looks correct', async ({ page }) => {
  await page.goto('/');
  await expect(page).toHaveScreenshot('homepage.png', {
    // Overpaint regions that legitimately change run-to-run (clocks, avatars, ids) so they don't flake.
    mask: [page.getByTestId('current-time'), page.locator('.avatar')],
    maskColor: '#FF00FF',      // default magenta
    animations: 'disabled',    // default; explicit
    maxDiffPixelRatio: 0.01,
  });
});
