# Copyright (C) 2022 Toitware ApS.

TOIT_RUN_BIN?=toit.run

.PHONY: all
all: test

.PHONY: build/host/CMakeCache.txt
build/CMakeCache.txt:
	$(MAKE) rebuild-cmake

.PHONY: install-pkgs
install-pkgs: rebuild-cmake
	(cd build && ninja download_packages)

.PHONY: test
test: install-pkgs rebuild-cmake
	(cd build && ninja check)

# From https://app.supabase.com/project/voisfafsfolxhqpkudzd/settings/auth
ARTEMIS_HOST := voisfafsfolxhqpkudzd.supabase.co
ARTEMIS_ANON := eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZvaXNmYWZzZm9seGhxcGt1ZHpkIiwicm9sZSI6ImFub24iLCJpYXQiOjE2NzMzNzQyNDEsImV4cCI6MTk4ODk1MDI0MX0.dmfxNl5WssxnZ8jpvGJeryg4Fd47fOcrlZ8iGrHj2e4
ARTEMIS_CERTIFICATE := Baltimore CyberTrust Root

# From https://app.supabase.com/project/ghquchonjtjzuuxfmaub/settings/api
TOITWARE_TESTING_HOST := ghquchonjtjzuuxfmaub.supabase.co
TOITWARE_TESTING_ANON := eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImdocXVjaG9uanRqenV1eGZtYXViIiwicm9sZSI6ImFub24iLCJpYXQiOjE2NzMzNzQ4ODIsImV4cCI6MTk4ODk1MDg4Mn0.bJB3EdVwFN34yk50JLHv8Pw5IA5gqtEJrXU1MtjEWGc
TOITWARE_TESTING_CERTIFICATE := Baltimore CyberTrust Root

AWS_HOST := a2hn36ey2yxmvx-ats.iot.eu-west-1.amazonaws.com
AWS_PORT := 8883
AWS_ROOT_CERTIFICATE := Amazon Root CA 1
AWS_CLIENT_CERTIFICATE_PATH := aws/client-certificate.pem
AWS_CLIENT_PRIVATE_KEY_PATH := aws/client-key.pem

.PHONY: add-default-brokers add-supabase-artemis add-supabase-toitware-testing add-mqtt-aws
add-default-brokers: add-supabase-artemis add-supabase-toitware-testing add-mqtt-aws

add-supabase-artemis:
	# Adds the Toitware supabase Artemis server and makes it the default.
	$(TOIT_RUN_BIN) src/cli/cli.toit config broker add --no-default supabase \
		--certificate="$(ARTEMIS_CERTIFICATE)" \
		artemis $(ARTEMIS_HOST) "$(ARTEMIS_ANON)"
	$(TOIT_RUN_BIN) src/cli/cli.toit config broker default --artemis artemis

add-supabase-toitware-testing:
	# Adds the Toitware supabase server and makes it the default.
	$(TOIT_RUN_BIN) src/cli/cli.toit config broker add supabase \
		--certificate="$(TOITWARE_TESTING_CERTIFICATE)" \
		toitware-testing $(TOITWARE_TESTING_HOST) "$(TOITWARE_TESTING_ANON)"

add-mqtt-aws:
	# Adds the AWS MQTT broker *without* making it the default
	$(TOIT_RUN_BIN) src/cli/cli.toit config broker add --no-default mqtt \
		--root-certificate "$(AWS_ROOT_CERTIFICATE)" \
		--client-certificate "$(AWS_CLIENT_CERTIFICATE_PATH)" \
		--client-private-key "$(AWS_CLIENT_PRIVATE_KEY_PATH)" \
		aws $(AWS_HOST) $(AWS_PORT)

.PHONY: add-local-http-brokers add-local-http-artemis add-local-http-broker
add-local-http-brokers: add-local-http-artemis add-local-http-broker start-http

add-local-http-artemis:
	# Adds the local Artemis server and makes it the default.
	# Use the public IP, so that we can flash devices which then can use
	# the broker.
	$(TOIT_RUN_BIN) src/cli/cli.toit config broker add http \
		--host=`ip route get 1 | head -n 1 | sed -E 's/.*src.* ([0-9]+[.][0-9]+[.][0-9]+[.][0-9]+).*/\1/'` \
		--port 4999 \
		artemis-local-http
	$(TOIT_RUN_BIN) src/cli/cli.toit config broker default --artemis artemis-local-http

add-local-http-broker:
	# Adds the local broker and makes it the default.
	$(TOIT_RUN_BIN) src/cli/cli.toit config broker add http \
		--host=`ip route get 1 | head -n 1 | sed -E 's/.*src.* ([0-9]+[.][0-9]+[.][0-9]+[.][0-9]+).*/\1/'` \
		--port 4998 \
		broker-local-http
	$(TOIT_RUN_BIN) src/cli/cli.toit config broker default broker-local-http

start-http:
	@echo "Run the following commands in separate terminals:"
	@echo $(TOIT_RUN_BIN) tools/http_servers/artemis_server.toit -p 4999
	@echo $(TOIT_RUN_BIN) tools/http_servers/broker.toit -p 4998 &

.PHONY: add-local-supabase-brokers add-local-supabase-artemis add-local-supabase-broker
add-local-supabase-brokers: add-local-supabase-artemis add-local-supabase-broker start-supabase

add-local-supabase-artemis:
	# Adds the local Artemis server and makes it the default.
	$(TOIT_RUN_BIN) src/cli/cli.toit config broker add supabase \
		artemis-local-supabase \
		`$(TOIT_RUN_BIN) tests/supabase_local_server.toit supabase_artemis`
	$(TOIT_RUN_BIN) src/cli/cli.toit config broker default --artemis artemis-local-supabase

add-local-supabase-broker:
	# Adds the local broker and makes it the default.
	$(TOIT_RUN_BIN) src/cli/cli.toit config broker add supabase \
		broker-local-supabase \
		`$(TOIT_RUN_BIN) tests/supabase_local_server.toit supabase_broker`
	$(TOIT_RUN_BIN) src/cli/cli.toit config broker default broker-local-supabase

start-supabase:
	@echo "Start the docker containers by running 'supabase start' in"
	@echo "./supabase_artemis and ./supabase_broker"
	@echo "Use the following command to log in as non-admin user"
	@echo "  $(TOIT_RUN_BIN) src/cli/cli.toit auth artemis login --email test@example.com --password password"
	@echo "  $(TOIT_RUN_BIN) src/cli/cli.toit auth broker login --email test@example.com --password password"
	@echo "Use the following command to log in as admin Artemis user"
	@echo "  $(TOIT_RUN_BIN) src/cli/cli.toit auth artemis login --email test-admin@toit.io --password password"
	@echo "If you want to use the Artemis server as both broker and artemis server,"
	@echo "run the following command:"
	@echo "  $(TOIT_RUN_BIN) src/cli/cli.toit config broker default artemis-local-supabase

# We rebuild the cmake file all the time.
# We use "glob" in the cmakefile, and wouldn't otherwise notice if a new
# file (for example a test) was added or removed.
# It takes <1s on Linux to run cmake, so it doesn't hurt to run it frequently.
.PHONY: rebuild-cmake
rebuild-cmake:
	mkdir -p build
	(cd build && cmake .. -G Ninja)
