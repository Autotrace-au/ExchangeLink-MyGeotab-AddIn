# MyGeotab Add-In

This folder contains the active MyGeotab Add-In used by FleetBridge.

## Purpose

The Add-In is the user-facing layer inside MyGeotab. It is responsible for:

- managing FleetBridge settings in the browser
- triggering sync requests to the Azure backend
- presenting MyGeotab device and booking configuration UI
- storing the customer-specific backend URL and group settings with browser fallback

## Files

- `index.html` main UI and JavaScript logic
- `styles.css` Add-In styling
- `configuration.json` MyGeotab manifest
- `images/` icons
- `translations/` language resources

## Notes

- The active backend target is Azure Container Apps
- The shared Add-In build is tenant-neutral; each customer enters their own backend URL in the Sync tab
- The Add-In persists settings through MyGeotab AddInData and falls back to browser localStorage
- The repository is being simplified to a single-tenant deployment model
- Historical backend documentation has been removed from this repository
