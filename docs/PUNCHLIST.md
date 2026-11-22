# CareCast Punchlist

Known issues and small fixes to come back to. Note which repo each item lives in.

## Open

### Frame drops to "unassigned" on a flaky internet connection
- **Repo:** `frameapp` (`D:\software_projects\frameapp`)
- **Logged:** 2026-10-19
- **Symptom:** Frame shows the slideshow, then switches to the "CareCast frame is ready for setup" / unassigned screen, then comes back on its own a few minutes later. Seen right after a power cycle too: it found its assignment, then lost it, then recovered about 5 minutes later.
- **Cause:** `resolveAssignmentAndApply` in `MainActivity.kt` polls `deviceAssignments/<deviceId>` every 60s. Any failed lookup (timeout, DNS failure, HTTP 5xx) is treated the same as "no assignment". The frame immediately stops the slideshow, clears the images and shows the setup screen. It recovers once a later retry succeeds (backoff 3s, 6s, 12s… up to 60s).
- **Fix:** Once a frame has resolved a resident, only drop to unassigned when Firestore really says so: lookup status `missing`, or `found` with `enabled=false` or no residentId. On `lookup failed: …`, keep the current resident and slideshow and keep retrying quietly. Ship it as a new frame release through Device Manager OTA, and check the versionCode against what's actually installed on prod devices first.
- **Confirm on a device:** the setup screen's "Backend lookup:" line reads `lookup failed: SocketTimeoutException` / `UnknownHostException`. Or run `adb logcat -d | Select-String -Pattern "assignment lookup failed"`.
