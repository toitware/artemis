# Artemis

Artemis consists of two parts:  A service that runs on the devices, and a CLI
that allows you to control the devices.

They communicate together using HTTP via a cloud service.  Currently the
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

Note that the `add-local-*` clauses use your LAN IP address, so that
flashed devices can connect to the local server. This means that you might
need to re-run the `add-local-*` clauses if your LAN IP address changes.

Before being able to flash a device, you need to log in, and create an
organization first. Also, you need to upload a valid Artemis service to
the Artemis server. All of this can be done by running `make setup-local-dev`. This
uses the `test-admin@toit.io` user for Artemis (creating it if it doesn't
exist), and the `test@example.com` user for the broker (if the broker is
not the same server as Artemis). The organization is called "Test Org".

In general a typical local workflow with HTTP servers looks like this:

``` sh
# Optionally, set your DEV_TOIT_REPO_PATH environment variable.
export DEV_TOIT_REPO_PATH=$PWD/../toit

# Make all binaries and (incidentally) download dependencies.
make
# Set up local servers.
make start-http
# Login, upload a service image and create an org:
make setup-local-dev

# Make a directory for your development fleet.
mkdir fleet

# Alias the CLI command. (Don't use the built on in `build/bin`,
# as it uses your production configuration).
alias artdev="toit.run $PWD/src/cli/cli.toit --fleet-root=$PWD/fleet"

# Create a fleet
artdev fleet init

# Update my-pod.json and change the WiFi credentials.
# If you intend to reuse that directory, you might also want to
# update the artemis-version to "v0.0.1". The 'make setup-local-dev'
# command above uploads the service snapshot under both versions.

# Create a pod.
artdev pod upload fleet/my-pod.json

# Flash a device.
artdev serial flash --port=/dev/ttyUSB0
```

Whenever you change the Artemis service, you need to upload it again. Use
`make upload-service` for that. You can then create a new pod with
`artdev fleet pod upload fleet/my-pod.json`, and roll it out with
`artdev fleet roll-out`.

Happy hacking!
