# Artemis

Artemis consists of two parts:  A service that runs on the devices, and a CLI
that allows you to control the devices.

They communicate together using MQTT or HTTP via a cloud service.  Currently the
cloud service is AWS's IoT service or a Supabase instance.  On the ESP32, the
device keeps track of its device id after the initial flashing.

To configure your Artemis CLI to use our Supabase setup in the cloud, you can
use the following command:

``` sh
make add-default-brokers
```

If you want to work locally, use one of the following `make` clauses:
- `add-local-http-brokers`: configures Artemis to use a local HTTP server. The
  output of the Makefile gives instructions on how to launch the HTTP server.
  You can also `make start-http` to get the instructions.
- `add-local-supabase-brokers`: configures Artemis to use a local Supabase
  instance. You have to launch the Supabase docker containers first. They
  are located in `supabase_artemis` and `supabase_broker`. Launch them
  using `supabase start --workdir ...`.

  You can also run `make start-supabase` to get the instructions. This also gives
  instuctions on how to log in.

Note that the `add-local-*` clauses use your external IP address, so that
flashed devices can connect to the local server. This means that you might
need to re-run the `add-local-*` clauses if your external IP address changes.

Before being able to flash a device, you need to log in, and create an
organization first. Also, you need to upload a valid Artemis service to
the Artemis server.

In general a typical local workflow with HTTP servers looks like this:

``` sh
# Make all binaries and (incidentally) download dependencies.
make
# Set up local servers.
make add-local-http-brokers
# Make sure to start the http servers in some other terminal.

toit.run src/cli/cli.toit auth artemis signup \
    --email 'test@toit.io' \
    --password password
toit.run src/cli/cli.toit auth artemis login \
    --email 'test@toit.io' \
    --password password
toit.run src/cli/cli.toit auth broker login \
    --email 'test@toit.io' \
    --password password

# Create an organization.
toit.run src/cli/cli.toit org create 'Test Org'

# Upload the local service.
toit.run tools/service_image_uploader/uploader.toit service \
    --sdk-version v2.0.0-alpha.58 \
    --service-version v0.0.1 \
    --local

# Flash a device.
# Make sure the specification is using the SDK/service versions you uploaded in the previous step.
toit.run src/cli/cli.toit device flash --port=/dev/ttyUSB0 --specification some_specification.json
```

For Supabase, the workflow is similar, but authentication is different. I recommend to
use the preseeded user entries `test-admin@toit.io` and `test@example.com` (with
password `password`). This way you don't have to create a new user.

``` sh
# Make all binaries and (incidentally) download dependencies.
make
# Start docker if it's not yet running.
supabase start --workdir supabase_artemis
supabase start --workdir supabase_broker
make add-local-supabase-brokers

toit.run src/cli/cli.toit auth artemis login \
    --email 'test-admin@toit.io' \
    --password password
toit.run src/cli/cli.toit auth broker login \
    --email 'test@example.com' \
    --password password

# Create an organization.
toit.run src/cli/cli.toit org create 'Test Org'

# Upload the local service.
toit.run tools/service_image_uploader/uploader.toit service \
    --sdk-version v2.0.0-alpha.58 \
    --service-version v0.0.1 \
    --local

# Flash a device.
# Make sure the specification is using the SDK/service versions you uploaded in the previous step.
toit.run src/cli/cli.toit device flash --port=/dev/ttyUSB0 --specification some_specification.json
```

Whenever you change the Artemis service, you need to upload it again.

Happy hacking!
