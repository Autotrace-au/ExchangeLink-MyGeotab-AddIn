## Next Steps Roadmap

### Phase 0 – Current Baseline
You have:

- Single container app with PowerShell endpoints in `start-server.ps1`
- App-only Exchange access via certificate
- Basic API key middleware guarding critical endpoints
- Per-client secrets stored in Key Vault using `client-<apiKey>-...` pattern
- Add-In sending API key in request body (not reliably via header)

Goal: Lift security, reliability, observability, and lifecycle management to production standards with minimal churn.

---

### Phase 1 – Immediate (1–3 Days)
Focus: Remove obvious risks, stabilize secret usage, enforce consistent authentication.

1. Enforce header-only API key  
    Remove body fallback in `Test-ApiKeyAuthorization`.  
    Standard missing key response:
    ```json
    { "success": false, "errorCode": "AUTH_MISSING_KEY", "message": "API key required" }
    ```
2. Replace Azure CLI secret retrieval  
    Use native Key Vault cmdlets:
    ```powershell
    Import-Module Az.KeyVault
    $secret = Get-AzKeyVaultSecret -VaultName fleetbridge-vault -Name "<name>" -ErrorAction Stop
    ```
3. In-memory secret cache (TTL 10–15 min)  
    Cache MyGeotab credentials and equipment domain keyed by (temporary) key or key hash.
4. Structured logging  
    Correlation ID via `X-Correlation-Id` (generate GUID if missing).  
    Example JSON log:
    ```json
    {
      "ts": "2025-11-05T12:34:56Z",
      "path": "/api/sync-to-exchange",
      "method": "POST",
      "tenantUid": "b1c1...",
      "keyPrefix": "fk_abcd",
      "status": 200,
      "durationMs": 142,
      "correlationId": "81b7e7d2..."
    }
    ```
5. Security headers & tightened CORS  
    Allowed origins configurable via `ALLOWED_ORIGINS`.  
    Headers:
    - `X-Content-Type-Options: nosniff`
    - `X-Frame-Options: DENY`
    - `Referrer-Policy: no-referrer`
    - `Content-Security-Policy: default-src 'none'; frame-ancestors 'none';`
6. Basic rate limiting  
    Per API key: 60 requests/min sliding window.  
    429 response:
    ```json
    { "success": false, "errorCode": "RATE_LIMIT", "message": "Too many requests", "retryAfterSeconds": 30 }
    ```
7. Standard error schema  
    Fields: `success`, `errorCode`, `message`, `correlationId`, `timestamp`.
8. Immediate docs  
    Add `docs/HARDENING_CHECKLIST.md` and update references to header-based auth.

---

### Phase 2 – Short-Term (Week 1–2)
Focus: Multi-tenant onboarding, metadata abstraction, key lifecycle.

1. Hashed key metadata  
    Secret: `fleetbridge-apikeys-metadata` JSON array:
    ```json
    {
      "keyHash": "<sha256>",
      "tenantUid": "<uuid>",
      "equipmentDomain": "example.com",
      "createdUtc": "2025-11-05T00:00:00Z",
      "revoked": false
    }
    ```
    Adopt secret names: `tenant-<tenantUid>-database`, etc.
2. Onboarding API  
    - `POST /api/tenants/start-onboarding` → returns session + server public key.
    - `POST /api/tenants/complete-onboarding` (encrypted creds + domain) → create secrets, return raw key once, store hash.
3. Key rotation & revocation  
    - `POST /api/keys/rotate` (grace period optional)  
    - `POST /api/keys/revoke` (immediate)  
    - Scripts: `scripts/rotate-client-key.ps1`, `scripts/revoke-client-key.ps1`.
4. Audit logging  
    Table/Cosmos DB partitioned by `tenantUid`. Events: onboarding, rotation, revocation, sync summary, property update summary.
5. Health & readiness  
    - `/health` lightweight  
    - `/ready` deep checks (Key Vault, metadata, Exchange optional).
6. Automated tests  
    Validate 401, 429, revoked, and property update integrity.
7. Metrics endpoint  
    `/metrics` counters: `sync_requests_total`, `property_updates_success_total`, `api_key_auth_failures_total`.

---

### Phase 3 – Pre-Launch Stabilization
Focus: Observability depth, CI/CD, dependency hygiene, operational resilience.

1. CI pipeline (GitHub Actions)  
    - PSScriptAnalyzer  
    - Secret scanning (Advanced Security / Trivy)  
    - Container build + vulnerability scan  
    - Python tests with pinned deps
2. Dependency pinning  
    `requirements.txt` (e.g. `mygeotab==<version>` etc.) + PowerShell module version docs.
3. Infrastructure as Code  
    Bicep/Terraform: container app, Key Vault, identity, scaling, Log Analytics.
4. Alerting & SLOs  
    Error rate >5%, P95 latency breach, 401 or 429 spikes, Key Vault failures.
5. Cost & scaling tuning  
    Adjust replicas/concurrency; consider min replicas for latency vs cost.
6. Backup strategy  
    Daily encrypted export of metadata secret; disaster recovery doc.
7. Final docs  
    `docs/MULTI_TENANT_SECURITY.md`, `docs/INCIDENT_RESPONSE.md`.

---

### Phase 4 – Post-Launch / Ongoing
Focus: Advanced security, resilience, tenant experience.

1. Optional JWT layer (short-lived tokens after API key auth)
2. HMAC request signatures (method + path + body hash + timestamp)
3. Application Insights / OpenTelemetry tracing
4. Chaos tests (Key Vault latency, concurrency surges)
5. Tenant portal (rotate keys, metrics, revoke access)
6. Continuous vulnerability management (monthly scans, CVE watch)

---

### Implementation Order (Recommended)
1. Header-only key + secret caching + structured logging
2. Replace CLI with Az module calls
3. Rate limiting + unified error schema
4. Hashed key metadata + secret name migration
5. Onboarding endpoints + Add-In UI update
6. Rotation / revocation endpoints + scripts
7. Audit logging + metrics
8. CI pipeline + scans
9. IaC + alerts + backup docs
10. Advanced features (JWT, HMAC, portal)

---

### Key Code Touch Points
- `start-server.ps1`: middleware, headers, rate limiting, metrics, onboarding routes
- `mygeotab-exchange-sync.ps1`: secret retrieval refactor, tenantUid mapping
- `update-device-properties.ps1`: secret access refactor, structured logging context
- `mygeotab-addin/index.html`: header-based API key, onboarding modal

---

### Metrics & Success Criteria
| Metric | Target |
|--------|--------|
| P95 sync latency | < 2s |
| Non-misuse error rate | < 2% |
| Key Vault request reduction | > 80% post-caching |
| Key rotation time | < 5s |
| Revocation effect | Immediate next request rejection |
| Audit coverage | 100% privileged actions |

---

### Anti-Patterns to Avoid
- Storing mutable flags (revoked) inside secret values
- Logging raw secrets or full API keys
- Using raw API key in secret names (migrate to hash/tenantUid)
- Re-fetching Key Vault secrets on every request without caching

---

### Optional Enhancements (Later)
- Uniform error for revoked vs invalid (anti-enumeration)
- Pre-limit warning headers (`X-RateLimit-Remaining`)
- Azure API Management for firewalling and analytics

---

### Example: Standard Error JSON
```json
{
  "success": false,
  "errorCode": "RATE_LIMIT",
  "message": "Too many requests",
  "correlationId": "5f9b2c1d-df86-4d0d-9aa2-4b673489c901",
  "timestamp": "2025-11-05T13:47:22Z"
}
```

### Example: Structured Log Line
```json
{
  "ts": "2025-11-05T13:47:22Z",
  "path": "/api/update-device-properties",
  "method": "POST",
  "tenantUid": "c3b1e2f4",
  "keyPrefix": "fk_abcd",
  "status": 200,
  "durationMs": 312,
  "correlationId": "5f9b2c1d-df86-4d0d-9aa2-4b673489c901"
}
```

---

### Summary
This roadmap transitions the service from a functional baseline to a production-hardened multi-tenant platform with strong identity controls, lifecycle management, observability, and future extensibility.
