# Setup

* Install 'deno'.
* Install the deno extension.
* Run the vscode command "Deno: Initialize Workspace Configuration" with
  this folder as root.
* In this folder run `deno check --config deno.json <function>/index.ts` for
  the function you are changing.

# Development
When starting the supabase containers (`make start-supabase` or
`make start-supabase-no-config`) the edge functions are automatically started.
However, local instances don't have any logging enabled.

For development it's thus recommended to call `supabase functions serve`
(inside this folder).

# Deployment
To deploy the edge functions, run:

```sh
for name in b device artifact-store broker pod-store; do
  supabase functions deploy --no-verify-jwt "$name"
done
```

`b` is the multiplexed v0 endpoint used by existing devices and older CLIs.
The other functions form the interface-oriented v1 API.

The `device` function accepts device requests without a user JWT. It exposes
`GET /device/{device-id}/goal`, `PUT /device/{device-id}/state`, and
`POST /device/{device-id}/events`. New device configurations receive that URL
as a template and a separate template for direct artifact downloads.

The remaining v1 functions are CLI-facing and forward their bearer tokens to
the RLS-protected APIs.
