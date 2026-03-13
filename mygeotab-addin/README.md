# MyGeotab Add-In

This folder contains the active MyGeotab Add-In used by FleetBridge.

## Purpose

The Add-In is the user-facing layer inside MyGeotab. It is responsible for:

- managing FleetBridge settings in the browser
- triggering sync requests to the Azure Function backend
- presenting MyGeotab device and booking configuration UI

## Files

- `index.html` main UI and JavaScript logic
- `styles.css` Add-In styling
- `configuration.json` MyGeotab manifest
- `images/` icons
- `translations/` language resources

## Notes

- The active backend target is Azure Function App
- The repository is being simplified to a single-tenant deployment model
- Historical backend documentation now lives outside this folder under `../legacy/`
