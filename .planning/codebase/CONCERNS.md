# Codebase Concerns

**Analysis Date:** 2026-03-15

## Tech Debt

**Artemis API Package Duplication:**
- Issue: Artemis API package has been temporarily copied from the official repository instead of imported as a dependency. Comments in `src/service/service.toit` (line 8-18) and `src/service/containers.toit` (line 10-18) explicitly state the API will be deleted once changes stabilize.
- Files: `src/service/service.toit`, `src/service/containers.toit`, `artemis-pkg-copy/`
- Impact: Maintenance burden when API changes - all changes must be synchronized with two copies. Risk of divergence between local copy and upstream. When deleted, import statements must be updated throughout codebase.
- Fix approach: Monitor when `toit-artemis` package reaches stable API, then switch imports from `artemis-pkg.api` back to `artemis.api` and remove `artemis-pkg-copy/` directory. Add pre-commit hook or CI check to prevent accidental modifications to copied package.

**Container Image Bundled Detection Heuristic:**
- Issue: Determining if a container image is bundled relies on checking if `image.name != null` (see `src/service/containers.toit` lines 46-50). This is documented as "a bit of a hack" in TODO comment.
- Files: `src/service/containers.toit` (lines 46-50)
- Impact: Brittle logic that could break if API changes. Unclear contract between image name presence and bundled status. No explicit bundled property available.
- Fix approach: Add explicit bundled flag to container image API, or create dedicated method in API to check bundled status rather than inferring from name.

**Container Lookup by GID Linear Search:**
- Issue: Finding a container by GID requires linear iteration through all jobs (see `src/service/containers.toit` lines 88-93). TODO suggests optimization via secondary map.
- Files: `src/service/containers.toit` (lines 88-93)
- Impact: O(n) lookup on potentially frequent GID lookups. If number of containers grows, performance degrades.
- Fix approach: Maintain secondary `jobs-by-gid_` map alongside existing `jobs_` map. Update map on container add/remove operations.

**Firmware Part Matching by Index:**
- Issue: Firmware parts are matched between old and new firmware by array index rather than by name/type (see `src/service/firmware-update.toit` line 115 TODO).
- Files: `src/service/firmware-update.toit` (lines 115-116)
- Impact: Risk of corruption if firmware structure changes and parts reorder. Assumes rigid part ordering across firmware versions.
- Fix approach: Implement name/type-based matching for firmware parts. Store part metadata (name/type) and use for matching instead of array indices.

**Container Image Installation Error Handling Gap:**
- Issue: Container loading in `src/service/containers.toit` (lines 59-63) has ambiguous error handling. If container image not found in flash, job is silently skipped but comments ask "Should we drop such an app from the current state?"
- Files: `src/service/containers.toit` (lines 52-67)
- Impact: Missing container images fail silently, potentially leaving device in inconsistent state. No logging or recovery mechanism.
- Fix approach: Explicitly log missing container images. Consider whether to treat as error vs silent skip. Possibly preserve container metadata for later recovery.

**Container Required Status Management:**
- Issue: Required container marking logic (lines 69-77) iterates connections but assumes containers exist. No validation that required containers are actually installed.
- Files: `src/service/containers.toit` (lines 69-77)
- Impact: Can mark nonexistent containers as required without error. May cause synchronization to hang waiting for unavailable containers.
- Fix approach: Validate that all required containers exist before marking. Log warnings for missing required containers. Consider fallback strategy.

**Container Image Reference Counting:**
- Issue: Image cleanup uses manual iteration through all jobs to check if image is still referenced (see `src/service/containers.toit` lines 135-138 TODO). Comment suggests reference counting would be better.
- Files: `src/service/containers.toit` (lines 135-138)
- Impact: O(n) cleanup on container uninstall. Scales poorly with number of containers. Easy to miss edge cases where image is still in use.
- Fix approach: Implement reference counting system where each job increments/decrements ref count on its image. Only uninstall when ref count reaches zero.

**Synchronization Error Loop Prevention:**
- Issue: In `src/service/synchronize.toit` (lines 487-490), there's a comment about coding errors in `synchronize-step_` that could cause tight error loops with no fallback mechanism. Example log pattern shown suggests network lookup failures cascading.
- Files: `src/service/synchronize.toit` (lines 487-490)
- Impact: Coding errors in synchronization step handling could cause device to spin in error loop without recovery. Difficult to diagnose from device logs.
- Fix approach: Add explicit error classification in synchronize-step_ that distinguishes between transient network errors and coding errors. Implement exponential backoff with maximum retries. Consider safe-mode trigger for persistent errors.

## Known Bugs

**Unreachable Code in Connection Handling:**
- Issue: In `src/service/brokers/http/connection.toit` line 41, method `send-request` has `unreachable` statement after a call that never returns normally. The pattern catches result but then claims unreachable.
- Files: `src/service/brokers/http/connection.toit` (lines 38-41)
- Impact: Code is correct but confusing. If control flow changes, compiler won't catch the error because `unreachable` suppresses warnings.
- Fix approach: Refactor to use explicit return or exception. Remove misleading `unreachable` statement.

**Assertion Failures on Checkpoint Misalignment:**
- Issue: Multiple assertions check checkpoint assumptions (see `src/service/firmware-update.toit` lines 112, 145). If checkpoints become misaligned due to corruption, assertions fail and crash instead of recovering gracefully.
- Files: `src/service/firmware-update.toit` (lines 112, 145)
- Impact: Firmware update can crash midway if checkpoint metadata corrupts. Device may be left in unrecoverable state.
- Fix approach: Replace assertions with proper error handling. Detect checkpoint corruption early and clear checkpoint to restart from beginning.

## Security Considerations

**TLS Session Caching in RTC Memory:**
- Risk: HTTP TLS session cache stored in RTC (RAM) memory that survives deep sleep but loses data on power loss (see `src/service/brokers/http/connection.toit` lines 89-92).
- Files: `src/service/brokers/http/connection.toit` (lines 89-92)
- Current mitigation: Sessions cleared on power loss, preventing replayed sessions from being persistent. TLS protocol provides forward secrecy.
- Recommendations: Document that session data is ephemeral. Consider adding integrity check to detect corrupted cached sessions. Periodically rotate session cache even if valid.

**Firmware Checkpoint Validation:**
- Risk: Firmware update checkpoints contain old and new firmware checksums but don't verify checkpoint itself (see `src/service/firmware-update.toit` lines 23-25, 252-258).
- Files: `src/service/firmware-update.toit`
- Current mitigation: Checksums validate firmware content, device storage provides basic integrity.
- Recommendations: Add HMAC or signature to checkpoint structure to detect tampering. Validate checkpoint integrity before using it.

**Network Retry Logic Credential Exposure:**
- Risk: HTTP connection retry logic (lines 56-73 in `src/service/brokers/http/connection.toit`) retries 3 times on 502/520/546 errors. Could theoretically retry with same credentials if broker is compromised.
- Files: `src/service/brokers/http/connection.toit` (lines 56-73)
- Current mitigation: Device headers configured per broker. Client-side secret not exposed.
- Recommendations: Add rate limiting to prevent excessive retry storms. Log all retry attempts for audit trail.

## Performance Bottlenecks

**Network Quarantine State Machine Complexity:**
- Problem: Network connection quarantine logic (see `src/service/network.toit` lines 28-148) involves timestamp checks and duration calculations on every connection attempt. Multiple temporary timers if network fails repeatedly.
- Files: `src/service/network.toit` (lines 28-148)
- Cause: Quarantine deadline stored as absolute monotonic microsecond timestamp, must compare against current time each attempt. No batch cleanup of expired quarantines.
- Improvement path: Implement connection quarantine using deadline queue or timer heap. Batch cleanup of expired quarantines on scheduler tick.

**Scheduler Signal Monitor Custom Implementation:**
- Problem: Scheduler uses custom monitor-based signal mechanism (see `src/service/scheduler.toit` lines 128-137) instead of standard primitives. May not be optimally implemented.
- Files: `src/service/scheduler.toit` (lines 128-137, also TODO comment on line 128)
- Cause: Appears to be custom implementation for non-standard wait semantics. Comment suggests could use standard monitor but doesn't.
- Improvement path: Profile scheduler signal performance. Consider switching to standard Toit monitor primitives if available. Benchmark before/after.

**Linear Iteration for GID Lookup:**
- Problem: Finding containers by GID requires linear scan (already noted in tech debt section). Called potentially during container RPC handlers.
- Files: `src/service/containers.toit` (lines 88-93)
- Cause: No secondary index by GID.
- Improvement path: Add `jobs-by-gid_` secondary map. Keep synchronized with primary jobs map.

**Synchronization State Reporting Overhead:**
- Problem: Every synchronization step compares device state with goal state (see `src/service/synchronize.toit` line 504). Full state comparison for each step could be expensive with large state.
- Files: `src/service/synchronize.toit` (lines 486-546)
- Cause: `report-state-if-changed` function likely deep-compares entire state map.
- Improvement path: Implement incremental state tracking. Only report state deltas instead of full state. Cache last reported state.

## Fragile Areas

**Synchronization Step Error Handling:**
- Files: `src/service/synchronize.toit` (lines 486-546)
- Why fragile: Synchronization loop is complex with many state transitions. Comments explicitly acknowledge risk of coding errors causing tight error loops (lines 487-490). Log examples show network failures cascading into repeated errors.
- Safe modification: Add comprehensive logging at each state transition. Test error paths explicitly (network failures, timeouts, invalid responses). Consider simplifying state machine into smaller methods.
- Test coverage: Needs end-to-end tests simulating network failures at each step. Mock broker should test both success and failure paths.

**Firmware Update Checkpoint System:**
- Files: `src/service/firmware-update.toit`
- Why fragile: Checkpoint tracks progress across firmware update but file corruption or bad timing could corrupt checkpoint state. Part matching by array index assumes firmware structure stability. Multiple writes and flushes with potential failure points.
- Safe modification: Add defensive checksum validation before using checkpoint. Handle missing/corrupt checkpoints gracefully by clearing and restarting. Add comprehensive logging of checkpoint lifecycle.
- Test coverage: Test checkpoint corruption scenarios. Test firmware updates interrupted at each checkpoint. Test part reordering in firmware structure.

**Container Manager Image Lifecycle:**
- Files: `src/service/containers.toit` (lines 33-150)
- Why fragile: Image installation, uninstallation, and bundled status tracking have implicit assumptions about image names and availability. Manual iteration for reference counting. Silent failures on missing images.
- Safe modification: Add validation at each image operation. Explicit logging of image state changes. Consider immutable image metadata structures. Add consistency checks on startup.
- Test coverage: Test missing container images at load time. Test concurrent install/uninstall of same image. Test bundled image protection.

**Network Manager Connection Quarantine:**
- Files: `src/service/network.toit` (lines 27-150)
- Why fragile: Quarantine deadline logic based on monotonic time comparisons. Multiple ways quarantine could persist incorrectly (time skew, stored value overflow). Iterates connections multiple times in sort.
- Safe modification: Add safeguards against time inconsistencies. Use saturating arithmetic for deadline calculations. Test quarantine expiration explicitly.
- Test coverage: Test time-based quarantine expiration. Test multiple connection failures and recovery. Test quarantine with network transitions.

**Recovery URL Selection:**
- Files: `src/service/synchronize.toit` (lines 640-641, 652-671)
- Why fragile: Recovery URL picked randomly (line 641). If recovery service is temporarily down, no fallback to try others. Query result cached but minimal validation of response format.
- Safe modification: Validate recovery service response structure before using. Implement retry logic for recovery queries. Log all recovery attempts.
- Test coverage: Test recovery service unavailability. Test malformed recovery response. Test fallback to primary broker.

## Scaling Limits

**Container Lookup Performance:**
- Current capacity: O(n) lookup where n = number of containers. Practical limit ~100-1000 containers before noticeable latency.
- Limit: When containers >1000, GID lookups become observable bottleneck during container RPC calls. Synchronization could stall.
- Scaling path: Implement secondary GID index as noted in tech debt. Consider sharding containers if scale exceeds 10,000.

**State Reporting Frequency:**
- Current capacity: Full state comparison on each synchronization step. With state size <10KB works fine.
- Limit: With large fleets (>10K devices) reporting full state repeatedly, cloud could see excessive traffic. State size growing with container configs could exceed network buffers.
- Scaling path: Implement state delta reporting. Compress state representation. Batch multiple state reports.

**Firmware Update Bandwidth:**
- Current capacity: Binary patching works efficiently for moderate firmware updates (<100MB). Checkpoint system prevents total loss but adds I/O overhead.
- Limit: Very large firmware images (>500MB) could exhaust device storage for intermediate files. Checkpoint system adds latency to firmware writes.
- Scaling path: Stream firmware in smaller chunks. Implement progressive patching. Consider delta-sync for incremental updates.

**Quarantine List Memory:**
- Current capacity: Network quarantine list likely <100 entries. Linear search acceptable.
- Limit: With complex network switching topology, quarantine list could grow large. Linear iteration becomes observable.
- Scaling path: Use time-indexed data structure (timer heap). Batch cleanup of expired entries.

## Dependencies at Risk

**Toit Language Evolution:**
- Risk: Codebase extensively uses Toit language features including custom monitors, task cancellation, and service providers. These could change in future versions.
- Impact: Major version upgrades of Toit SDK could require substantial refactoring, particularly scheduler and service provider code.
- Migration plan: Monitor Toit SDK changelog. Maintain compatibility shim layer for language features if possible. Plan major refactors around SDK upgrade cycles.

**HTTP/TLS Library Stability:**
- Risk: HTTP client implementation in broker connection depends on `http` package. TLS session caching relies on undocumented RTC memory buckets.
- Impact: HTTP library changes could affect connection retry logic. TLS session format changes could break cached sessions.
- Migration plan: Monitor HTTP package updates. Abstract HTTP client creation into service provider. Test TLS session migration path explicitly.

## Missing Critical Features

**Firmware Rollback Recovery:**
- Problem: Firmware update can fail leaving device in incomplete state. Device has rollback capability but no automated recovery triggers it. Manual intervention required.
- Blocks: Can't reliably deploy faulty firmware updates. Devices can get stuck in validation-pending state.
- Recommendation: Implement automatic rollback trigger after N failed sync attempts post-update. Add metadata to track rollback history.

**Container Migration Tool:**
- Problem: No tooling to migrate containers between devices or fleets. Container data is ephemeral.
- Blocks: Can't easily redistribute load or backup container state. Disaster recovery requires manual redeployment.
- Recommendation: Build container export/import tool. Document data migration patterns.

**Network Failover Metrics:**
- Problem: No visibility into why network connections fail or why one connection preferred over another.
- Blocks: Hard to diagnose network configuration issues. Can't optimize connection priority based on actual performance.
- Recommendation: Track and report per-connection success metrics. Log network selection decisions.

## Test Coverage Gaps

**Firmware Update Edge Cases:**
- What's not tested: Checkpoint corruption, firmware download interruption at each part boundary, part reordering in firmware structure, concurrent firmware updates
- Files: `src/service/firmware-update.toit`
- Risk: Firmware updates could fail silently or corrupt device. No recovery from corruption scenarios.
- Priority: High

**Synchronization Error Scenarios:**
- What's not tested: Network errors at each step of synchronization, broker unavailability during image download, timeout handling during state reporting, recovery server fallback
- Files: `src/service/synchronize.toit`
- Risk: Device could get stuck in error loops or miss updates during network issues.
- Priority: High

**Container Lifecycle Management:**
- What's not tested: Missing container images at boot, concurrent install/uninstall of same image, bundled image protection, container reference counting
- Files: `src/service/containers.toit`
- Risk: Container state inconsistencies, orphaned images, incorrect cleanup.
- Priority: Medium

**Network Quarantine System:**
- What's not tested: Quarantine deadline expiration, multiple connection failures, connection switching during quarantine, quarantine list memory growth
- Files: `src/service/network.toit`
- Risk: Connections could remain quarantined indefinitely or not quarantine properly.
- Priority: Medium

**Watchdog Timer Integration:**
- What's not tested: Watchdog creation timeout (line 228), watchdog feeding during long operations, watchdog without service availability
- Files: `src/service/synchronize.toit` (lines 223-237)
- Risk: Watchdog could timeout due to bugs in watchdog integration rather than actual hangs.
- Priority: Medium

**Task Cancellation Handling:**
- What's not tested: Synchronization cancellation during different states, container startup cancellation, proper cleanup on task.cancel
- Files: `src/service/synchronize.toit` (line 434)
- Risk: Incomplete cleanup on cancellation could leave locks held or connections open.
- Priority: Low

---

*Concerns audit: 2026-03-15*
