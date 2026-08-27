# Artemis backend and fleet architecture roadmap

This document tracks the direction of the backend work. It is intentionally
organized as **independent workstreams**, not as a sequence. Workstream letters
and task numbers are stable references, not priorities or execution order.
Only the dependencies called out explicitly below impose ordering.

## North star

Artemis should orchestrate a fleet without requiring Supabase. The CLI should
compose small interfaces for fleet state, goals, pods, and artifacts, and each
interface should be backed independently by files, HTTP, or another provider.
Supabase remains one possible implementation rather than the architecture.

For the V1 device API, devices use HTTP-family protocols:

- a broker endpoint tells a device its desired state;
- artifact endpoints provide the referenced firmware and application data;
- separate URL templates allow those endpoints to be hosted independently;
- HTTPS is available where authenticity is required, while content-addressed
  verification can make an HTTP artifact mirror safe to use;
- transports such as MQTT or LoRa remain possible future extensions, but the V1
  device does not need a generic transport plug-in system.

The CLI hides the selected implementations from normal commands. A fleet stored
in Git and files should be as valid a deployment as one stored behind HTTP.

## Foundation in the current dependent PR stack

The stack leading to this roadmap has already established useful foundations.
They are listed here to distinguish follow-up work from direction that still
needs to be invented:

- Artemis V1 is the boundary for the new API generation; V0 clients remain on
  the old combined edge function.
- CLI access is split into `ArtifactStore`, `BrokerBackend`, and `PodStore`
  contracts with provider-neutral HTTP implementations.
- Supabase exposes interface-oriented HTTP edge functions while retaining the
  old function for existing clients.
- Device HTTP operations have independent URL templates, so goals, reports, and
  artifact downloads need not share a host or path.
- CLI-side and embedded service-side server configurations have been separated.

These changes are pending with their respective PRs until merged. The roadmap
does not require all remaining work to accumulate in that same stack.

## Terminology

The overloaded term "fleet configuration" should be replaced with these names:

- **Fleet manifest**: the small, local `fleet.json` file that tells the CLI how
  to access a fleet. It contains the fleet identity and maps interfaces to
  backend configurations or references. It does not contain fleet state.
- **Fleet state**: the desired, reviewable state of the fleet, including devices,
  groups, and group-to-pod assignments.
- **Fleet state store**: the interface used by the CLI to read and update fleet
  state. The initial implementation is a directory of files.
- **Pod specification**: the input used to build a pod. Settings that must work
  after all servers are lost, including recovery endpoints, ultimately become
  part of the built pod.

`FleetFile` can eventually become `FleetManifest`, and an interface for the
state can be named `FleetStateStore`. Until that migration is complete, code and
documentation should avoid introducing new uses of the ambiguous phrase
"fleet config."

## Architectural boundaries

### CLI-side interfaces

Backend selection happens per interface, not through a provider-wide
`CombinedBackend`. A single configured server may be passed to several backend
implementations when that is convenient, but the implementations remain
separate.

The intended boundaries are:

| Interface | Responsibility | Plausible implementations |
| --- | --- | --- |
| Fleet state store | Devices, groups, and desired pod assignments | Files first; HTTP or a database later |
| Broker client | Write goals; read desired/reported state and optional events | HTTP; a provider-specific adapter only if needed |
| Pod store | Pod descriptions, manifests, tags, and content-addressed pod parts | Files, HTTP |
| Artifact store | Firmware patches and application images consumed by devices | Files/static hosting, HTTP |

Reported state and events belong with the broker client, not the fleet state
store. Servers may omit either optional read capability, and the CLI should
report that cleanly. Device inventory in the fleet state store means the CLI's
declared set of devices; broker-reported device records are observations, not
the source of that declared state.

### Device-side interfaces

The device has a broker interface and an artifact interface. Each operation uses
a URL template supplied in its embedded configuration. The templates may point
at different hosts and may use different schemes. The device does not need to
know whether the server uses one edge function, several functions, static files,
Supabase, Cloudflare, or another implementation.

For V1, URL schemes express transport security. Do not add a separate
`use-tls` setting: `http://` and `https://` already carry that information.
Certificates are associated with the HTTPS connection/template that needs them.

## Workstream A: device HTTP and integrity

- [ ] **A1 — HTTP-only V1 device protocol.** Keep the device protocol focused on
  HTTP request/response semantics and URL templates. Do not expose MQTT, LoRa,
  or provider concepts in the V1 configuration.
- [ ] **A2 — Separate device broker and artifact contracts.** The broker contract
  fetches goals and optionally reports state/events. The artifact contract
  downloads application and firmware data. They may share an HTTP helper, but a
  device must be able to configure and replace them independently.
- [ ] **A3 — Explicit scheme policy.** Initially allow the deliberately supported
  schemes and reject unsupported ones at pod-build time. Keep goal and artifact
  policies separate so a deployment can use HTTPS goals and HTTP artifacts.
- [ ] **A4 — Device HTTPS certificates.** Let an HTTPS URL template reference or
  carry the certificate roots needed by the device. Cover private roots as well
  as public roots and avoid duplicating the same DER certificate in a pod.
- [ ] **A5 — CLI certificate lifecycle.** Define how the CLI obtains, validates,
  stores, embeds, displays, and rotates certificates. Non-interactive builds must
  be reproducible; fetching an unpinned certificate during every build is not a
  sufficient long-term design.
- [ ] **A6 — Verify downloaded artifacts before commit.** Compute SHA-256 over the
  materialized firmware data and compare it with the hash from the authenticated
  goal before committing the update. A mismatch must discard the candidate and
  its checkpoint.
- [ ] **A7 — Mixed-security delivery.** Permit an authenticated HTTPS goal to
  reference firmware served over HTTP only after A6 is complete. Document that
  HTTPS authenticates the goal and its hashes, while the hash authenticates the
  bytes obtained from any artifact mirror.

### Integrity verification finding

The current implementation is **not yet sufficient for A7**:

- `src/cli/firmware.toit` calculates SHA-256 identifiers for firmware parts;
- `src/cli/broker.toit` verifies generated patches before uploading them;
- patch resource names are derived from the goal's expected part hash;
- `src/shared/utils/patch.toit` validates that a differential patch applies to
  the expected old bytes;
- however, `src/service/firmware-update.toit` does not compare the materialized
  result with the expected new SHA-256 before calling `FirmwareWriter.commit`.
  Its `on-new-checksum` callback is explicitly unused, and the normal patch
  builders do not emit the otherwise-supported new-output checksum metadata.

Using a hash as an object name is not verification. A6 should include tests that
corrupt a full patch, a differential patch, and a resumed download and prove
that none can be committed. The implementation may hash each materialized part,
the complete image, or both, provided that it checks all downloaded bytes against
values authenticated by the goal and works correctly across checkpoints.

## Workstream B: fleet storage separation

Today `fleet.json` mixes access wiring with state: it contains server entries and
the selected broker, but also group-to-pod assignments and recovery URLs.
`devices.json` is already separate.

The file-backed target should look conceptually like this (exact filenames are a
schema decision):

```text
fleet-root/
  fleet.json                 # Fleet manifest: identity and backend bindings.
  state/                     # FileFleetStateStore root.
    devices.json
    groups.json              # Groups and their desired pod references.
  pods/
    *.yaml                   # Author-maintained pod specifications, if local.
```

- [ ] **B1 — Define `FleetStateStore`.** Its contract covers declared devices,
  groups, and group-to-pod assignments, with no reported state or events.
- [ ] **B2 — Extract the existing file backend.** Move the current state into its
  own directory and access it only through the interface.
- [ ] **B3 — Reduce `fleet.json` to a fleet manifest.** Keep the fleet ID, schema
  version, and interface-to-backend bindings. Backend connection details may be
  embedded or referenced, but operational fleet state must not be mixed in.
- [ ] **B4 — Preserve Git workflows.** Writes are deterministic, diffs remain
  readable, and ordinary state changes can be code-reviewed and reproduced.
- [ ] **B5 — Prove replaceability.** Add a small in-memory test implementation or
  contract suite to show that commands do not depend on file layout. This proves
  that a database implementation is possible without implementing one.
- [ ] **B6 — Migrate without data loss.** Use the explicit migration tooling in
  G to convert the existing `fleet.json` and `devices.json` into the new layout.
  Do not make the normal fleet-state implementation a permanent reader for all
  historical layouts.

The manifest may still contain backend configuration because that is precisely
how the CLI accesses the fleet. The separation is between access/wiring and
fleet state, not between frequently and infrequently changed fields.

## Workstream C: recovery configuration belongs to pods

Recovery URLs are already baked into built pods, but their source of truth is
currently `fleet.json`. This makes the build depend on unrelated fleet state and
prevents two pods in a fleet from carrying different recovery policies.

The current mechanism calls these recovery URLs: a device uses one to obtain a
replacement broker configuration. They are therefore the existing form of
backup-server configuration discussed in this roadmap.

- [ ] **C1 — Add recovery endpoints to pod specifications.** Include validation
  and schema/documentation updates.
- [ ] **C2 — Allow an optional fleet default.** Resolve values as pod override,
  then fleet-manifest default, then no recovery endpoint. The resolved value is
  embedded in the pod; later default changes do not mutate an existing pod.
- [ ] **C3 — Move recovery commands.** Commands should inspect or update a pod
  specification/default rather than pretending recovery is live fleet state.
- [ ] **C4 — Provide a compatibility migration.** Existing fleet-level
  `recovery-urls` can become the manifest default until users move it into pod
  specifications.

This workstream is independent of the fleet-state directory extraction. It only
shares a small manifest migration with B3/B6.

## Workstream D: backend implementations and conformance

- [ ] **D1 — Stabilize contracts before adding providers.** Specify optional
  capabilities, errors, pagination, atomicity expectations, content addressing,
  and authentication ownership for each interface.
- [ ] **D2 — Add reusable conformance tests.** Run the same behavioral suite
  against file and HTTP implementations. Provider demos should reuse it where
  possible.
- [ ] **D3 — File implementations.** Treat local files/static directories as
  first-class backends, not test doubles.
- [ ] **D4 — HTTP implementations.** Keep provider-neutral URL/request behavior
  in the HTTP implementation. Authentication is configuration, not a reason to
  leak provider types into callers.
- [ ] **D5 — Direct Supabase access only if justified.** There is no current need
  for a direct CLI-to-Supabase implementation; edge functions and HTTP keep the
  CLI more portable.
- [ ] **D6 — Capability discovery or clear configuration.** Do not infer a
  provider or a "combined" server from its hostname. Either configure supported
  interfaces explicitly or use a small provider-neutral capabilities document.

Cloudflare can therefore be an HTTP implementation even if its HTTP endpoints
use Cloudflare storage or a database internally. Backend provider and CLI
protocol are separate choices.

## Workstream E: internal responsibilities

`src/cli/broker.toit` currently combines remote broker/store access, artifact and
patch upload, goal construction, and envelope customization. Pod construction is
particularly hard to discover because `Pod.from-specification` delegates the
actual envelope build to `Broker.customize-envelope`.

- [ ] **E1 — Make `Artemis` the workflow orchestrator.** Top-level operations
  should be visible from the main object and delegate focused work to helpers.
- [ ] **E2 — Introduce a discoverable pod builder.** Move envelope customization,
  service/container installation, embedded device configuration, and recovery
  assets behind a `PodBuilder` (for example `src/cli/pod-builder.toit`).
- [ ] **E3 — Split artifact preparation from upload.** Patch creation and local
  verification should not require a broker object. Uploading consumes the
  prepared content through `ArtifactStore`.
- [ ] **E4 — Keep goal planning separate from transport.** Construct and validate
  desired state independently, then send it through the broker client.
- [ ] **E5 — Slim `Broker`.** It should coordinate broker operations, not build
  pods or know how SDK envelopes are assembled.

These are behavior-preserving refactors and can proceed alongside A, B, or C.
They should land in small moves with tests rather than as one rewrite.

## Workstream F: demonstration deployments

These demos validate the abstractions; they are not prerequisites for one
another and do not need to become production offerings immediately.

### GitHub Pages

- [ ] Serve goals, pods, and artifacts as static content.
- [ ] Generate the static tree from file-backed fleet state.
- [ ] Publish changes through a normal Pages deployment, making the deployment
  delay and cache behavior visible to the CLI.
- [ ] Treat reported state and events as unsupported capabilities.

This is the clearest proof that devices and the CLI no longer require a live
database-backed broker for desired-state delivery.

### Cloudflare

- [ ] Start with provider-neutral HTTP and static/object storage.
- [ ] Evaluate a small state store for reported device state and optional events.
- [ ] Before choosing products, run a research spike covering request, storage,
  write-frequency, retention, consistency, and current cost limits.
- [ ] Keep Cloudflare-specific deployment code outside the core interfaces.

### Home Assistant

- [ ] Start with pure HTTP goal and artifact endpoints.
- [ ] Define how Home Assistant entities map to Artemis device identity and
  desired/reported state.
- [ ] Consider MQTT goal notification later, while retaining HTTP artifact
  downloads. MQTT is an optimization/adapter, not a V1 device requirement.

## Workstream G: migration from V0 to V1

Migration is a product feature, not a collection of compatibility branches.
The desired steady state is one strict current-format reader plus explicit,
versioned migration code that can eventually be removed with its source format.

### Local configuration and fleet files

The current readers accept several historical shapes inline:

- Supabase's singular `root_certificate_der64` and
  `root_certificate_der_id` fields;
- historical `root_certificate_name` and `root_certificate_names` references;
- separate `host`, `port`, `path`, and `use_tls` fields instead of a URL;
- a top-level fleet `organization` instead of per-server `scope`;
- very old fleet files without explicit broker/server entries.

This is useful during development, but keeping these branches in
`ServerConfig.from-json` and `FleetFile.parse` indefinitely makes every future
refactor harder.

- [ ] **G1 — Version every persisted format.** The global CLI configuration,
  fleet manifest, and file-backed fleet state each need an explicit schema
  version. A missing version identifies a known legacy input, not an unbounded
  promise of compatibility.
- [ ] **G2 — Add an explicit migration command.** Provide a command such as
  `artemis config migrate`, with an option to include a selected fleet root.
  Avoid overloading the existing fleet broker-migration commands. Support
  `--check`/dry-run, print every planned file change, write atomically, retain a
  backup, and make rerunning the migration safe.
- [ ] **G3 — Isolate legacy decoders.** The migration command owns small decoders
  for each supported source version. Normal commands accept only the current
  format and return an actionable message telling the user which migration to
  run.
- [ ] **G4 — Cover the known conversions.** Convert singular certificates to
  lists, connection components to URLs, the fleet organization to server scope,
  and the old fleet layout to the manifest/state-store layout. Preserve auth
  data, certificate bytes, file permissions, comments where the format permits,
  and stable fleet/device identities. Resolve old named certificates to their
  DER bytes during migration instead of merely treating their presence as
  `use_tls=true`.
- [ ] **G5 — Test real historical fixtures.** Keep sanitized configuration and
  fleet files produced by selected released CLIs. Test migration output rather
  than testing that the production reader silently accepts those inputs.
- [ ] **G6 — Define the support window.** State which source versions can migrate
  directly and whether older versions must first use an intermediate CLI. Once
  the migration command is released and tested, remove inline legacy parsing and
  its compatibility tests.

The migration command necessarily knows how to decode old data. That does not
mean the rest of the CLI must continue to do so.

### Server upgrade

The first V1 server upgrade is additive: the existing database, storage, RLS
policies, and multiplexed `b` edge function remain, and operators deploy the new
interface-oriented functions next to it. We should package and test that fact
instead of relying on a README loop.

- [ ] **G7 — Provide one server upgrade entry point.** A script or command takes
  the deployment variant and project reference, performs preflight checks,
  applies forward-only database migrations if any, deploys the required
  functions, and verifies their health/capabilities. It must be usable for both
  the combined Artemis deployment and the standalone broker deployment.
- [ ] **G8 — Keep the initial upgrade zero-downtime.** Deploy V1 endpoints before
  changing any CLI default. Keep `b` and its database contract available while
  V0 devices exist. New migrations must be additive during this period, with a
  documented rollback for the functions.
- [ ] **G9 — Test upgrades, not only fresh installs.** Start the last supported V0
  database/deployment, seed representative data, apply the upgrade, and run both
  V0 and V1 API suites against the upgraded server. Test the combined and
  standalone variants.
- [ ] **G10 — Make retirement observable.** Define how an operator can determine
  that no V0 devices remain before removing `b` or old database compatibility.
  Reported service version is a better gate than elapsed time alone.

### Old-device migration test

Released CLI binaries make this a realistic end-to-end test. For example,
[v0.36.0](https://github.com/toitware/artemis/releases/tag/v0.36.0) has Linux,
macOS, and Windows CLI assets on the main Artemis GitHub release, including
published SHA-256 metadata. The repository does not need to commit an old
executable.

- [ ] **G11 — Pin an old-CLI fixture.** Store the release tag, asset name, and
  expected digest in the test definition. Download/cache it in CI and verify the
  digest. Keep the selected version fixed until deliberately advancing the
  oldest supported migration source. The verified initial Linux candidate is
  `v0.36.0/artemis-linux.tar.gz`, SHA-256
  `170b347dd84dde4c228638e90a10a7e87e8026132a5a30a9ba503792a625aea9`.
- [ ] **G12 — Exercise the complete handover.** Use the old CLI to create a V0
  fleet, pod, and device against the V0 server; upgrade the server; migrate the
  local configuration with the new CLI; then use the new CLI to upload and roll
  out a V1 pod.
- [ ] **G13 — Prove the device crosses APIs.** The V0 device must receive the V1
  goal and artifacts through `b`, reboot into the V1 Artemis service, and then
  fetch/report through the new operation-specific device URLs. Instrument or
  disable `b` after the reboot so the test cannot pass while silently staying on
  the old API.
- [ ] **G14 — Cover identity and interrupted updates.** Verify that the device ID,
  fleet membership, desired state, and reported state survive the handover.
  Include an interrupted firmware update so the upgrade does not bypass the
  checkpoint/integrity behavior.

This test is a CLI migration test even though it observes a device: the new CLI
must migrate the files, publish compatible state through V1 server interfaces,
and build the V1 pod that moves the device.

## Workstream H: one source for Supabase deployments

There are currently two Supabase project trees:
`supabase_artemis` is the combined Artemis server and broker, while
`public/supabase_broker` is the standalone broker. Their database histories and
some policies are legitimately different. The edge-function code is mostly
duplicated, however: `b`, `device`, `artifact-store`, `pod-store`, `_shared`, and
the dependency configuration are copies. The new `broker` function has already
drifted because the combined deployment also inserts into its `public.devices`
inventory table.

The recommended layout is one canonical function implementation plus two small
deployment descriptions:

```text
supabase/
  functions/                 # Canonical handlers and shared code.
  deployments/
    combined/                # Config, seed, migrations, and thin adapters.
    standalone-broker/       # Config, seed, migrations, and thin adapters.
```

- [ ] **H1 — Extract canonical handlers.** Shared request parsing, RLS clients,
  storage operations, and RPC calls live in one function tree.
- [ ] **H2 — Model real differences as adapters.** The combined broker's
  additional `public.devices` insert becomes an explicit `notify-created` hook
  or thin entrypoint, rather than a fork of the whole broker function.
- [ ] **H3 — Select a Supabase CLI layout.** Supabase supports
  [per-function custom entrypoints](https://supabase.com/docs/guides/local-development/cli/config#functionsfunction_nameentrypoint)
  relative to the project root. Validate with the repository's pinned Supabase
  CLI version that a shared path works for both local `supabase start` and
  remote deployment. If either path is unsupported, generate complete temporary
  project workdirs from the canonical tree; do not check generated function
  copies into Git.
- [ ] **H4 — Keep migration histories deployment-specific initially.** Existing
  remote migration histories must not be rewritten. New shared broker SQL can be
  authored once and assembled into each deployment's forward migrations, but
  historical combined and standalone migrations remain distinct.
- [ ] **H5 — Test both assembled projects.** CI performs Deno checks once on the
  canonical functions, starts both deployment variants, and runs their policy
  and API suites. It also fails if a generated workdir is dirty or differs from
  the canonical source.
- [ ] **H6 — Make deploy artifacts reproducible.** The server-upgrade entry point
  from G7 records the Artemis commit and deployment variant used to assemble the
  functions and migrations.

The custom-entrypoint option is documented by Supabase, but it should be proven
with the exact CLI version used by Artemis before choosing it over staging. A
staging tool is still a substantial improvement: duplication exists only in
temporary output, not as two manually maintained source trees.

## Workstream I: open-source repository and release cleanup

The release workflow still reflects the former private/public split. It checks
out `toitware/artemis-releases` and `toitware/web-docs`, copies the contents of
`public/`, commits those copies, and finally creates a second release in
`artemis-releases`. The main Artemis repository already publishes the same
release assets; v0.36.0, for example, has matching SHA-256 digests in both
repositories.

The `public/` directory is now a staging boundary rather than a meaningful
ownership boundary. Its contents should move to descriptive canonical paths:

```text
docs/fleet/                  # Artemis documentation source.
examples/                    # Versioned examples.
schemas/                     # Schema source; public URLs remain stable.
supabase/deployments/...     # Standalone broker deployment.
```

- [ ] **I1 — Release only from this repository.** Keep binaries and installers on
  `toitware/artemis` releases. Remove the duplicate `Create public release` step,
  the release-repository checkout, and the personal access token dependency.
- [ ] **I2 — Move canonical source out of `public/`.** Relocate docs, examples,
  schemas, and the standalone Supabase deployment; update Make, CMake, tests,
  local-development commands, and CI paths in the same change.
- [ ] **I3 — Update download consumers first.** `action-setup-artemis`, fleet
  documentation, and the Toit product website currently reference
  `artemis-releases`. Point them at `toitware/artemis` before stopping duplicate
  releases. Preserve historical releases in the old repository and mark it as
  archived/redirected rather than deleting it.
- [ ] **I4 — Decouple documentation publication from releases.** Keep docs
  canonical here. Have the documentation site consume a pinned Artemis ref or a
  documentation artifact without committing a generated copy back to
  `web-docs`. Documentation changes should be previewable before an Artemis
  release.
- [ ] **I5 — Preserve public schema URLs.** Moving `public/schemas` in Git must not
  break `https://toit.io/schemas/artemis/...`. Identify the current publisher,
  change its source path, and add an HTTP test for every stable schema URL.
- [ ] **I6 — Preserve example links.** Change documentation links from the
  release repository to versioned or main-branch paths in this repository and
  decide whether examples use placeholders or release-time generated values.
- [ ] **I7 — Remove the old copy job and `public/`.** Do this only after external
  consumers and publication jobs use the canonical paths. Verify a dry-run
  release without access to the old PAT.

This cleanup can proceed independently of device/API migration except that the
standalone Supabase deployment should move only once; coordinate I2 with H's
canonical layout.

## Explicit dependencies

Anything not listed here may be developed and reviewed independently.

| Work item | Hard dependency | Reason |
| --- | --- | --- |
| A7 mixed HTTPS/HTTP delivery | A6 artifact verification | HTTP artifact bytes are otherwise unauthenticated |
| A4 private HTTPS endpoints | Certificate representation in device config | The device needs a trust anchor |
| A5 reproducible certificate handling | A4 certificate representation | The CLI needs a stable target format |
| B2 file-state extraction | B1 state-store contract | Avoid encoding the old layout into the abstraction |
| B5 replaceability proof | B1 and one implementation | The contract needs something concrete to test |
| Provider demos | D1 stable relevant contracts | Demos should validate rather than redefine boundaries |
| GitHub Pages device demo | A1/A2 plus relevant HTTP contracts | It needs the V1 device protocol and static layout |
| Strict current-format readers | G1–G5 migration tooling and fixtures | Users need a safe path before inline compatibility is removed |
| Remove singular/legacy config parsing | Released migration command | The CLI must still be able to convert supported installations |
| Remove the V0 `b` endpoint | G10 reports no V0 devices | Old devices need it to receive their V1 upgrade goal |
| G13 end-to-end API handover | V1 device service and additive server upgrade | The test needs both sides of the handover |
| One-source Supabase deployment | H1/H2 plus a proven entrypoint or staging strategy | Both variants must still express their real difference |
| Delete `public/` | I2–I6 source moves and consumer updates | Published downloads, docs, schemas, and examples must remain available |
| Stop releases to `artemis-releases` | I3 consumer updates | Installers and actions must use the main repository first |

C (recovery ownership) and E (internal responsibility cleanup) can proceed at
any time. B and D can overlap: conformance tests may be developed while the file
layout is extracted.

## Suggested review-sized changes

These are independent candidates for follow-up PRs, not a prescribed queue:

- Add device-side SHA verification and corruption/resume tests (A6).
- Separate the device broker and artifact contracts (A2).
- Enforce and test the V1 device URL scheme policy (A1/A3).
- Define the certificate representation without automating acquisition (A4).
- Extract `PodBuilder` from `Broker` without behavior changes (E2/E5).
- Define `FleetStateStore` and add an in-memory contract test (B1/B5).
- Move file-backed fleet state into its directory (B2/B3/B6).
- Add recovery endpoints to pod specifications with the old fleet value as a
  default (C1/C2/C4).
- Add backend conformance tests independent of any new provider (D1/D2).
- Build the GitHub Pages static proof of concept (F/GitHub Pages).
- Add format versions and a dry-run config/fleet migration command (G1–G5).
- Add a pinned v0.36.0 CLI fixture and the V0-to-V1 handover test
  (G11–G14).
- Extract canonical Supabase function handlers and thin deployment adapters
  (H1/H2).
- Prototype custom Supabase entrypoints versus generated temporary workdirs
  (H3/H5).
- Move release consumers to the main repository, then remove the duplicate
  release job (I1/I3/I7).
- Move one `public/` category at a time to its canonical path (I2/I4–I6).

## Cross-cutting acceptance criteria

- Core CLI workflows do not branch on provider names.
- A server can implement one, several, or all interfaces.
- Unsupported optional capabilities fail clearly and do not make unrelated
  operations unavailable.
- Content-addressed downloads are verified by the consumer, not merely named by
  a digest.
- Fleet state remains deterministic and reviewable when the file backend is
  selected.
- Existing V0 clients and the old edge function remain isolated from V1 design
  constraints; compatibility does not distort the new interfaces.
- Supported V0 installations have a tested, explicit, and reversible migration
  path; normal current-format readers do not accumulate legacy branches.
- A server upgrade is tested against existing data and keeps V0 and V1 endpoints
  working concurrently during the migration window.
- Shared Supabase functions have one canonical source regardless of deployment
  variant.
- Releases, documentation, schemas, and examples originate from this repository
  without a private-to-public copy step.
- Documentation and configuration use "fleet manifest" and "fleet state"
  consistently.
