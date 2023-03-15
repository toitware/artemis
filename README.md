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
- `start-http`: configures Artemis to use a local HTTP server, and
  launches the http servers (in the foreground)..
- `start-supabase`: configures Artemis to use a local Supabase
  instance. You have to start docker first.

You can use the following `make` clauses to switch the broker (but not the
Artemis server). They have to be run after the `start-local-*` clauses from above:
- `use-customer-supabase-broker`: configures Artemis to use a separate customer
  Supabase broker, and starts it. You have to start docker first.
- `start-mosquitto`: configures Artemis to use a local Mosquitto
  broker, and starts it in the foreground.

Note that the `add-local-*` clauses use your external IP address, so that
flashed devices can connect to the local server. This means that you might
need to re-run the `add-local-*` clauses if your external IP address changes.

Before being able to flash a device, you need to log in, and create an
organization first. Also, you need to upload a valid Artemis service to
the Artemis server. All of this can be done by running `make setup-local-dev`. This
uses the `test-admin@toit.io` user for Artemis (creating it if it doesn't
exist), and the `test@example.com` user for the broker (if the broker is
not the same server as Artemis). The organization is called "Test Org".

In general a typical local workflow with HTTP servers looks like this:

``` sh
# Make all binaries and (incidentally) download dependencies.
make
# Set up local servers.
make start-http
# Login, upload a service image and create an org:
make setup-local-dev

# Flash a device.
# Make sure the specification is using the SDK/service versions you uploaded in the previous step.
toit.run src/cli/cli.toit device flash --port=/dev/ttyUSB0 --specification some_specification.json
```

Whenever you change the Artemis service, you need to upload it again. Use
`make upload-service` for that.

Happy hacking!
