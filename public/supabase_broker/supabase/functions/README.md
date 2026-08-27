# Setup

* Install 'deno'.
* Install the deno extension.
* Run the vscode command "Deno: Initialize Workspace Configuration" with
  this folder as root.
* In this folder run: `deno cache --import-map=./import_map.json' b/index.ts`
  or any other file that needs syntax.

# Development
When starting the supabase containers (`make start-supabase` or
`make start-supabase-no-config`) the edge functions are automatically started.
However, local instances don't have any logging enabled.

For development it's thus recommended to call `supabase functions serve`
(inside this folder).

# Deployment
To deploy the edge functions, run:

```sh
for name in b artifact-store broker pod-store; do
  supabase functions deploy --no-verify-jwt "$name"
done
```

`b` is the multiplexed v0 endpoint used by existing devices and older CLIs.
The other functions form the interface-oriented v1 API used by new CLIs.

The v0 endpoint accepts device requests without a user JWT. The v1 functions
are CLI-facing and forward their bearer tokens to the RLS-protected APIs.
