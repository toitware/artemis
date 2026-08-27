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
- [ ] **B6 — Migrate without data loss.** Read the existing `fleet.json` and
  `devices.json`, write the new layout explicitly, and make repeated migration
  safe. Decide separately how long the old format remains writable.

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
- Documentation and configuration use "fleet manifest" and "fleet state"
  consistently.
