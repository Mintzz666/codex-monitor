# Codex Monitor 1.5.0 maintenance review

Reviewed on 2026-11-07. This is a targeted maintenance and release review, not a
complete security audit or a long-term performance benchmark.

## Changes grounded in observed problems

- Login recovery previously missed clients restored before the watcher and
  slow launches beyond eight seconds. Ship the existing recovery fixes with a
  one-minute untouched-client window, native action-boundary checks and hidden
  background restoration. Interactive, ambiguous and old instances are skipped.
- The health checker knew about the login watcher, but the appearance panel did
  not display it. Add that status and localize the management window title.
- Menu and panel entry points repeatedly launched a full health check. Reuse a
  successful report for 30 seconds and an attention report for 5 seconds;
  **Check now** always checks again. Bound helper execution time. This changes
  scheduling; CPU, memory and energy savings have not been measured.
- Ship the bilingual reset countdown, including the awaiting-reset state and
  minute updates, with explicit boundary coverage.
- Remove the unused network/proxy adapter implementation from the compatibility
  entry point. Keep its filename for existing LaunchAgents. The appearance
  agent continues to reuse Monitor's identity-validated shared quota; the
  pinned project-color and Token implementation remains unchanged.
- Verify installation identities before stopping Monitor, retain a checked ZIP
  backup, verify the final installed signature, and restore the previous app
  after signature or launch failure. Failure injection also exposed macOS Bash
  3.2's unreliable errexit handling for bare conditional expressions; identity
  mismatches now exit explicitly.
- Read version/build settings from project.yml, require matching release tags,
  and verify the app actually inside the DMG. Resolve the native compiler's
  SDK explicitly instead of accidentally mixing Xcode with a newer CLT SDK.
- Stop scanning generated build/cache directories during public-source checks;
  exclude Python bytecode. Keep runtime allowlists, licenses and source history.
  Do not automatically delete user data or historical backups.

## Measured package size

Compare the downloaded, checksum-verified public 1.4.9 release with the local
public-identifier universal 1.5.0 candidate. Each application total comes from
its DMG. Local installations retain their existing private identifiers and
optional local artwork; they are not used as the public size baseline.

| Measure | Public 1.4.9 / Build 46 | Local 1.5.0 / Build 50 candidate | Reduction |
|---|---:|---:|---:|
| Application file bytes | 8,495,361 | 7,173,996 | 15.55% |
| DMG bytes | 4,588,711 | 3,641,248 | 20.65% |

The candidate application has 21 files. Badge runtime, diagnostics and license
selection remains 12 files plus its manifest; development material stays in
source. The candidate DMG SHA-256 is `9a696b84946be2c63d46592ba9995d0e15a8f3af6630ef54981b2fe5fde8204c`.
CI rebuilds may differ in bytes across SDKs; the published asset must be
downloaded and checked separately. These measurements concern disk size only.

## Validation

- Swift deterministic verifier: **87 PASS**, including countdown boundaries,
  account switching, shared snapshots, RPC compatibility, time budgets and
  proxy inheritance. No second live quota collector is started.
- Node health/shared-quota/packaged-installer tests: **25 PASS**. Shared-quota
  fixtures cover account switches during a read, stale/oversized payloads,
  disconnected Monitor recovery and refusal to call a second app-server.
- Startup-controller deterministic suite: PASS, against the bundled controller.
- Runtime package selection tests: **5 PASS**.
- Application installation failure tests: **4 PASS**, in a disposable directory
  with process and launch commands isolated.
- Native startup recovery: **1 PASS**, no skipped cases in the final run.
  It launches only a disposable windowless application and isolates its port
  probe from the real client's CDP listener. Occupied-port refusal is tested
  separately in the controller suite. Earlier attempts encountered desktop
  input or the real listener; they are not counted as recovery passes.
- Universal app and widget build; signatures; runtime manifest; public
  identifiers; no embedded build-machine paths; DMG checksum and exact app
  comparison through a read-only mount: PASS for the local public candidate.
- English and Chinese native menu renders inspected, using fixture usage values.
- Swift format lint completes with pre-existing style warnings in unchanged
  files; diff whitespace and public-source privacy checks pass.

## Remaining checks

A real computer reboot/login cycle is separate from the disposable native
recovery test and has not been performed during this release. Future ChatGPT
updates can change integration behavior. Widget timeline scheduling is owned
by macOS; a valid bundle and shared snapshot do not prove a desktop widget has
rendered every timeline update. No long-term CPU, memory or energy claim is made.
