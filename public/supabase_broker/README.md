# Supabase broker

This folder contains source code and instructions for deploying your own
Artemis broker on Supabase.

When hosting your own broker, Toitware has no access to your data. You are
responsible for securing your broker and data.

## Beta

This is a beta release. Breaking changes may still happen.

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
    step 2. From this directory:
   ```
   supabase link --project-ref <your-project-ref>
   ```
6. Push the migrations from this repository (still from this directory):
    ```
    supabase db push
    ```
7. Make the `toit_artemis` schema public: Go to your project settings -> API
   and add `toit_artemis` to the "Exposed schemas" list.
   https://supabase.com/dashboard/project/YOUR-PROJECT-ID/settings/api
8. Push the edge functions:
    ```
    supabase functions deploy --no-verify-jwt b
    ```

At this point your Supabase project is ready to be used by Artemis.

Note that Artemis uses a separate schema (`toit_artemis`) for its tables. You
can use the main database schema for your own data.

You can optionally enable OAuth2 for your broker. Follow the instructions
on https://supabase.com/docs/guides/auth/social-login.

### Self-hosted Supabase

You can use a self-hosted Supabase (locally or in the cloud). The steps
might differ from the above, but the general idea is the same.
Feel free to contact us on Discord if you need help.

## CLI configuration

Once the broker is set up, you can configure the Artemis CLI to use it
for all communication with the devices.

*Make sure to use a recent version of the Artemis CLI.*

Get the anon key from the API section of the settings.

Configure the Artemis CLI to use your broker:
```shell
artemis config broker add supabase "my_own_broker" \
    --no-default \
    --certificate "Baltimore CyberTrust Root" \
    "<project-ref>.supabase.co" \
    "<anon-key>"
```

If you use the `migration` command below you don't need to set the
broker as default broker (flag `--no-default`). If you do, then all
new fleets will use this broker by default.

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

## Migration

If you have been using the Artemis broker on Toitware's servers, you can
migrate your data to your own Supabase broker.

```
artemis fleet migration start --broker my_own_broker
```

Note: from now on you can use `artemis fleet login` to authenticate with
your broker. This may be convenient if fleets have different brokers.

Build and upload new pods. Typically these are using the same
pod specifications as before. If you then do a `fleet roll-out` the
devices will start migrating to the new broker.

Once all devices have moved to the new broker:

```
artemis fleet migration finish
```
