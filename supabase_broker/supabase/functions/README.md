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
To deploy the edge functions, run
  `supabase functions deplay --no-verify-jwt b`.

(The `--no-verify-jwt` might not be necessary, since the `config.toml` already
has an entry for the `b` functions. I haven't tested it without it, though.)
