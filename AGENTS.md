# AGENTS

## Repo-backed workflows

- Container App deployment entrypoint: `bash ./scripts/deploy-container-app.sh`
- GitHub Actions bootstrap entrypoint: `bash ./scripts/bootstrap-github-actions.sh <github-repo> <subscription-id> <exchange-app-id> <mygeotab-database> <mygeotab-username> <mygeotab-password> <equipment-domain> <exchange-cert-display-name>`
- Main manual deployment workflow: `.github/workflows/deploy-single-tenant.yml`
- Main automatic push deployment workflow: `.github/workflows/deploy-goa-test-on-push.yml`

## Local validation commands found in CI

- Python syntax check: `python -m py_compile function-app/function_app.py`
- MyGeotab add-in inline script parse check:

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

- Manifest sync and version query-string check: see `.github/workflows/pr-code-review.yml`

## PR workflow expectations

- Changes under `mygeotab-addin/` are expected to include a version bump in `mygeotab-addin/configuration.json`
- `configuration.json` and `mygeotab-addin/configuration.json` are expected to stay in sync
- PRs are scanned by Gitleaks through `.github/workflows/pr-secrets-review.yml`

## TODO

- TODO: no dedicated local one-command wrapper for the manifest sync/version validation is checked in; use the CI workflow logic in `.github/workflows/pr-code-review.yml` and `.github/workflows/pr-mygeotab-addin-version-review.yml` as the source of truth
