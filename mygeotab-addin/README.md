# MyGeotab Add-In

This folder contains the shared ExchangeLink add-in that runs inside MyGeotab.

## What the add-in does

The add-in is the operator UI for the product. It currently provides:

- property setup and validation for ExchangeLink custom properties
- asset management for Exchange booking settings
- backend URL configuration per tenant
- sync job triggering
- live sync progress and result rendering
- local persistence through MyGeotab add-in storage with browser fallback

The add-in is tenant-neutral. The tenant-specific backend is selected by saving the deployed backend URL in the UI.

## Files

- [`index.html`](index.html): primary UI, styling injection, and client-side logic
- [`styles.css`](styles.css): supporting stylesheet assets
- [`configuration.json`](configuration.json): MyGeotab manifest used by the add-in
- [`images/`](images): icons and visual assets
- [`translations/`](translations): language strings

## Important repo rules

- If files under `mygeotab-addin/` change, bump the version in [`configuration.json`](configuration.json).
- Keep [`../configuration.json`](../configuration.json) and [`configuration.json`](configuration.json) identical.
- The manifest item URL must include the current version in the query string.

These rules are enforced by:

- [`.github/workflows/pr-code-review.yml`](../.github/workflows/pr-code-review.yml)
- [`.github/workflows/pr-mygeotab-addin-version-review.yml`](../.github/workflows/pr-mygeotab-addin-version-review.yml)

## Local validation

Inline script parse check:

```bash
node - <<'NODE'
const fs = require('fs');
const html = fs.readFileSync('mygeotab-addin/index.html', 'utf8');
const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map((m) => m[1]);

if (!scripts.length) {
  throw new Error('No inline scripts found in mygeotab-addin/index.html');
}

scripts.forEach((script, index) => {
  try {
    new Function(script);
  } catch (error) {
    throw new Error(`Inline script ${index} failed to parse: ${error.message}`);
  }
});
NODE
```
