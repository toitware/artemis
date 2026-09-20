# Workspace fleets

An `artemis.yaml` selects the backends used to access a fleet. Each HTTP binding
names a server, an endpoint path, and an optional scope. The server describes
the connection and public trust material; the binding owns the scope. The CLI
passes scope values through to the selected backend without interpreting them
as organization IDs. An omitted scope is JSON null.

This format is being exercised before its migration target is frozen. Existing
`fleet.json` installations continue to use their current commands and readers.

## Initialize a local fleet

Create `artemis.yaml` in your project directory:

```yaml
$schema: https://toit.io/schemas/artemis/workspace/v1.json
servers: {}
backends:
  fleet:
    type: file
    directory: fleet
```

Run `artemis fleet init` there, or select the workspace with
`artemis fleet init --fleet path/to/project`. This creates:

```text
artemis.yaml
fleet/
  fleet.yaml      # Schema version and stable fleet ID.
  groups.json     # Groups and desired pod references.
  devices.json    # Declared device inventory.
```

Initialization is local and does not require credentials, an organization, or
network access. The initial group is `default`, referencing `my-pod@latest`.
The fleet directory must not already exist. Initialization prepares its files
in a temporary sibling directory and renames that directory into place.
Relative file-backend paths are resolved against the manifest's directory.

Group listing and mutations use the declared fleet directly. For example:

```sh
artemis fleet group list
artemis fleet group add staging --pod app@latest --force
```

`--force` skips checking that the referenced pod exists. Without it, operations
that select a new pod check the configured pod store. Group renames, removals,
and device moves operate locally. Missing backends are reported when used, so a
fleet with only file storage can still perform local operations.

File writes are deterministic and replace individual files atomically. An
operation touching both groups and devices is not yet a transaction across
those files. One file per device is a potential later layout change.

## Scope and credentials

This example uses independent broker, pod, and artifact endpoints:

```yaml
$schema: https://toit.io/schemas/artemis/workspace/v1.json
servers:
  control:
    type: toit-http
    url: https://control.example.net
    credentials: control-login
  content:
    type: toit-http
    url: https://content.example.net
    credentials: content-login
backends:
  fleet:
    type: file
    directory: fleet
  broker:
    type: http
    server: control
    endpoint: /api/broker
    scope: fleet-control-scope
  pods:
    type: http
    server: content
    endpoint: /api/pods
    scope: pod-storage-scope
  artifacts:
    type: http
    server: content
    endpoint: /api/artifacts
    scope: artifact-storage-scope
```

`credentials` names a server entry in local CLI configuration. For HTTP servers,
its `admin_headers` supply request credentials. For Supabase, the session is
looked up under `auths.<local-server-name>`, as with existing login commands.
The local entry must match the workspace server's type and URL. Its URL, scope,
device settings, and certificate roots do not override the manifest. Credentials
are resolved only when the corresponding backend is opened. A server without a
credential reference uses no local credentials.

Configure these local entries using the existing `config broker add` and login
commands. Workspace manifests reject embedded `admin_headers`. Public API keys
and `root_certificate_ders64` may be committed; private tokens remain local.
Roots are embedded as base64 DER bytes, so these settings require no certificate
fetch during initialization. Certificate acquisition and rotation remain later
work.

The HTTP endpoint is appended to the server URL. It must be an absolute path
without a hostname, query, or fragment. Shared servers reuse a connection while
each backend retains its own endpoint and scope. HTTP scopes must be values
understood by the receiving service; existing Artemis servers expect an
organization UUID.

Structured scopes in JSON request bodies retain their JSON value. In HTTP query
parameters, maps and lists are JSON-encoded before URL encoding; scalar scopes
use their string representation.

For a combined Supabase deployment, use one server:

```yaml
servers:
  primary:
    type: supabase
    url: https://your-project.supabase.co
    anon: <public-api-key>
    credentials: project-login
```

Bind broker, pods, and artifacts to `/functions/v1/broker`,
`/functions/v1/pod-store`, and `/functions/v1/artifact-store`, respectively, and
give each the appropriate organization UUID as its scope. The Supabase adapter
supplies authentication; the explicit paths are used as written.

## Current workflow coverage

Workspace fleets support `fleet init`, `fleet group` operations, and `pod list`.
The backend factory also constructs independent broker and artifact interfaces.
This first integration step leaves pod building, provisioning, device commands,
rollout, recovery commands, and broker migration on the existing fleet format.
Those commands report an explicit error when given a workspace. Embedded device
configuration and pod-specific recovery defaults are follow-up work, before
freezing the format and implementing migration.
