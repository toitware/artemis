# Supabase broker
This folder contains source code and instructions for deploying your own
Artemis broker on Supabase.

When hosting your own broker, Toitware has no access to your data. You are
responsible for securing your broker and data.

## Alpha
This is an alpha release. Expect breaking changes.

## What does the broker do?
The broker is a service that connects the Artemis command-line tool
to your IoT devices (and the Artemis service that runs on your devices).

All firmware updates, application updates, and health/status information
is sent to and from your devices via the broker.

## Supabase setup
1. Install the Supabase CLI. See https://supabase.com/docs/guides/cli.
2. Create a Supabase account at https://supabase.com/.
3. Create a new project. Remember the database password.
4. Copy the reference ID. It can be found in the general project settings,
   or directly in the URL.
5. Link this repository to your project. You will need the password from
    step 2:
   ```
   supabase link --project-ref <your-project-ref>
   ```
6. Push the migrations from this repository:
    ```
    supabase db push
    ```

At this point your Supabase project is ready to be used by Artemis.

Note that Artemis uses a separate schema (`toit_artemis`) for its tables,
and only has some forwarding functions (all prefixed with `toit_artemis.`)
in the public schema.

You can optionally enable OAuth2 for your broker. Follow the instructions
on https://supabase.com/docs/guides/auth/social-login.

### Self-hosted Supabase
You can use a self-hosted Supabase (locally or in the cloud). The steps
might differ from the above, but the general idea is the same.
Feel free to contact us on Discord if you need help.

## CLI configuration
Once the broker is set up, you can configure the Artemis CLI to use it
for all communication with the devices.

Get the anon key from the API section of the settings.

Configure the Artemis CLI to use your broker:
```shell
artemis config broker add supabase "my_own_broker" \
    --certificate "Baltimore CyberTrust Root" \
    "<project-ref>.supabase.co" \
    "<anon-key>"
```

If you have enabled OAuth log into your broker as follows:
```shell
artemis auth login --broker
```

Otherwise sign up to your broker by email:
```shell
artemis auth signup --broker --email "$EMAIL" --password "$PASSWORD"
```
Confirm your email address. If you haven't configured your Site URL
confirming the email will redirect to a non-existing server, but
the mail should still be confirmed.

You can now log in:
```shell
artemis auth login --broker --email "$EMAIL" --password "$PASSWORD"
```

At this point the Artemis CLI can be used as normal. You can
verify that data is sent through your Supabase broker by looking at
the tables in schema `toit_artemis`.
