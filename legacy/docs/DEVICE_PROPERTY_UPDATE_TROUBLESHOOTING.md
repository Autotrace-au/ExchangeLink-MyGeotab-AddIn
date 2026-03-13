# Device Custom Property Update Troubleshooting Guide

This guide documents the end-to-end investigation and resolution of the MyGeotab `Device.customProperties` update failures experienced when migrating logic from the Azure Function implementation to the Azure Container App service.

## 1. Summary

When first ported into the Container App, attempts to update device custom properties:

- Threw intermittent `JsonSerializerException` errors from the MyGeotab API.
- Sometimes "succeeded" but cleared (blanked) existing property values.
- Produced no diagnostics due to indentation issues in an embedded Python here-string.

Root causes were a combination of:

- Over-sending the entire device object with many unrelated fields.
- Mixing raw Python types (bool/int) in `value` with the server seemingly expecting strings for persisted values.
- Fragile inline Python (here-string) causing silent indentation failures that hid internal diagnostic output.
- Post-update verification using a serial number treated as an id (lookups failed, misleading validation).

Final working solution: Send a minimal `customProperties` array (only properties being changed) with all values coerced to strings first. Fallback to typed values only if string attempt fails (not needed in successful flow). Use an external Python script with structured diagnostics and a fallback device lookup (id → serialNumber → name).

## 2. Symptoms & Indicators

| Symptom | Indicator in Logs |
|---------|-------------------|
| `JsonSerializerException` | "SET FAIL" lines during full payload attempt |
| Properties become empty | POST-FETCH showed properties with only `property` objects (no `value`) |
| No diagnostic output | PowerShell showed only wrapper success lines; internal Python never printed diagnostics |
| False negative on verification | "POST-FETCH: device missing" due to lookup using serial as id |

## 3. Environment Context

- Original working logic: Python Azure Function (MyGeotab Python SDK `0.9.4`).
- New target: Azure Container App running PowerShell HTTP listener + external Python script.
- Authentication: API key → Key Vault secrets (username, password, database).
- Properties managed (8 total): `Enable Equipment Booking`, `Allow Recurring Bookings`, `Booking Approvers`, `Fleet Managers`, `Allow Double Booking`, `Booking Window (Days)`, `Maximum Booking Duration (Hours)`, `Mailbox Language`.

## 4. Root Cause Breakdown

1. Payload Structure: Sending the full device object (including many non-custom fields) triggered serialization failure.
2. Type Handling: The service already stored most existing values as empty strings or stringified booleans; raw Python bool/int values inflight aggravated deserialization.
3. Inline Script Instability: Indentation errors in here-string prevented diagnostics, stalling debugging.
4. Lookup Ambiguity: Using serial number as `search={'id': serial}` caused POST-FETCH mismatch.

## 5. Resolution Strategy (Multi-Attempt Flow)

Implemented in `update_device_properties.py`:

1. Build two parallel payload variants:
   - String-coerced (`"true"`, `"14"`, `"en"`, empty string for None).
   - Typed variant (bool/int/str as native Python) WITH preserved `id`/`version` if present.
2. Attempt 1: Minimal string-coerced `customProperties` only (SUCCESS case).
3. Attempt 2 (only if 1 fails): Minimal typed values.
4. Attempt 3 (only if still failing): Reduced full device object (`id`, `name`) + string-coerced properties (RAW REQUEST instrumentation active).
5. Post-Fetch: Re-query device using internal resolved id to confirm persistence (fix applied after anomaly detection).

## 6. Working Payload Example

Minimal payload sent (Attempt 1):

```jsonc
{
  "id": "b1", // internal device id resolved via serial fallback
  "customProperties": [
    {"property": {"id": "aHyFYTfkCekOrp_cTVjvMHw", "propertySet": {"id": "aOiRTzMbyOk2e6a8mHoEilA"}}, "value": "true"},
    {"property": {"id": "aPK5oftbFyEO-ofEEVTsbyg", "propertySet": {"id": "aOiRTzMbyOk2e6a8mHoEilA"}}, "value": "en"},
    {"property": {"id": "aVPsr4LbM60C_XilPLT125A", "propertySet": {"id": "aOiRTzMbyOk2e6a8mHoEilA"}}, "value": "14"}
  ]
}
```

Key points:

- Only changed properties included.
- All values stringified; no raw booleans or integers.
- No extraneous device fields (e.g., status, groups, capabilities).

## 7. Device Lookup Fallback

Function `fetch_device()` now performs: `id` → `serialNumber` → `name` lookup. This lets callers supply serial or name transparently. After resolving, always use `device['id']` for subsequent updates and verification.

## 8. Diagnostics Instrumentation

Diagnostic sections printed before final JSON result:

- `DEBUG: ORIGINAL customProperties COUNT=` – enumerates existing state.
- `PropertyDefinition ...` – confirms mapping from short keys to Property IDs.
- `SET:` lines – each incoming property key/value with data type.
- `ATTEMPT 1|2|3` – indicates which strategy is executing.
- `PAYLOAD[...]` – preview of outgoing objects (first 15 entries).
- `SET SUCCESS` / `SET FAIL` – outcome per attempt.
- `DEBUG RAW REQUEST BEGIN/END` – full JSON of outbound request (only Attempt 3).
- `POST-FETCH` – final persisted state confirmation.

## 9. Common Pitfalls & Avoidance

| Pitfall | Avoidance |
|---------|-----------|
| Indentation errors in inline Python | Use external `.py` file; never here-string complex logic. |
| Clearing properties | Send minimal `customProperties` only; avoid full device update. |
| Serializer exceptions | String-coerce values first; fall back only if needed. |
| Missing diagnostics | Print all non-final lines before JSON parse in PowerShell wrapper. |
| False post-fetch failure | Always re-query using resolved internal id. |

## 10. Verification Procedure (Rapid)

1. POST to `/api/update-device-properties` with minimal property set.
2. Confirm HTTP 200 and success JSON: `{"success":true,...}`.
3. Check container app logs for:
   - `SET SUCCESS minimal string payload`.
   - Correct `PAYLOAD` values stringified.
   - `POST-FETCH COUNT>0` with updated `value` fields.
4. (Optional) Re-run POST with modified values (e.g., toggle boolean) and repeat log inspection.

## 11. Recovery Checklist (If Issue Reappears)

1. Confirm running revision matches latest image (`az containerapp show`).
2. Check that `update_device_properties.py` is present in container (`logs` should print Python version & mygeotab version).
3. Verify property IDs unchanged (definitions should log successfully).
4. Ensure payload not accidentally expanded (no unexpected keys beyond `customProperties`).
5. Look for `JsonSerializerException` lines – if present, inspect any non-string values; force strings.
6. If POST-FETCH missing: confirm using internal device id (patch if necessary).

## 12. Future Improvements

- Add explicit read-back endpoint `/api/get-device-properties` for post-update verification without log scraping.
- Persist last successful payload & attempt number for audit.
- Implement selective diff logic (send only properties whose value changed vs incoming).
- Add retry with exponential backoff if transient network errors arise.
- Introduce structured logging (JSON lines) for easier ingestion.

## 13. Reference Files

- PowerShell wrapper: `azure-container-app/update-device-properties.ps1`
- Python logic: `azure-container-app/update_device_properties.py`
- HTTP server: `azure-container-app/start-server.ps1`
- Working property mapping: `PROP_NAME_MAP` in `update_device_properties.py`

## 14. Example Request Body

```json
{
  "apiKey": "<client-api-key>",
  "deviceId": "G90Z62EPW054", // serial or internal id or name supported
  "properties": {
    "bookable": true,
    "language": "en",
    "windowDays": 14
  }
}
```

## 15. Key Lessons

1. Minimal, string-coerced custom property payloads are safest.
2. Preserve property identity/version only when present; unnecessary for setting new values.
3. Overly large device objects trigger serialization edge-cases.
4. Externalizing Python eliminates hidden formatting errors.
5. Clear, layered diagnostics accelerate root cause discovery.

---
Last updated: 2025-11-05
