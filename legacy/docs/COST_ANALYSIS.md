# Azure Container Apps vs Azure Functions: Cost Analysis

(Consolidated from original root `COST_ANALYSIS.md`)

## Executive Summary
For this workload (calendar processing & device property updates), Azure Container Apps Consumption plan provides equal or lower cost than Azure Functions Premium while enabling required PowerShell modules. Typical usage scenarios (up to ~100k operations/month) fall entirely within free grants, resulting in $0 monthly runtime cost. Premium Functions required for reliable PowerShell incur minimum fixed instance cost.

## Pricing Comparison (Representative)
| Scenario | Ops/Month | Container Apps Est. | Functions Premium (EP1) | Notes |
|----------|-----------|---------------------|-------------------------|-------|
| Light | 1,000 | $0 (under free) | $146.44 | Scale-to-zero advantage |
| Moderate | 10,000 | $0 (under free) | $146.44 | PowerShell need drives Premium |
| Heavy | 100,000 | $0 (under free) | $146.44+ | Premium fixed cost persists |
| Large | 1,000,000 | ~$41 | $438.32+ (EP3) | Free grant exhausted; still cheaper |

## Why Container Apps Wins
1. True scale-to-zero (idle cost = $0)
2. Native PowerShell 7 support without plan upgrade
3. Generous free grants for vCPU, memory, requests
4. More granular billing based on actual usage
5. Higher replica ceilings (up to 1,000) enabling horizontal scaling

## Cost Formula Snapshot
- vCPU: $0.000024/vCPU-second (first 180,000 free)
- Memory: $0.000024/GiB-second (first 360,000 free)
- HTTP Requests: $0.40 per million (first 2M free)

## Operational Guidance
- Keep container resources at 0.25 vCPU, 0.5 GiB for baseline tasks
- Monitor scaling rules: adjust concurrency before raising replica limits
- Revisit configuration when sustained monthly usage > 1M operations

## Key Takeaway
Container Apps is both the functional and economically preferable platform for this Exchange calendar processing + MyGeotab integration workload.
