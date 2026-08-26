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
for name in b artifact-store update-broker broker-state-reader broker-event-reader pod-store; do
  supabase functions deploy --no-verify-jwt "$name"
done
```

`b` is the multiplexed v0 endpoint used by existing devices and older CLIs.
The other functions form the interface-oriented v1 API used by new CLIs.

(The `--no-verify-jwt` might not be necessary, since the `config.toml` already
has entries for the functions. I haven't tested it without it, though.)
