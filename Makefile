# Copyright (C) 2022 Toitware ApS.

TOIT_RUN_BIN?=toit.run

SETUP_LOCAL_DEV_SDK ?= v2.0.0-alpha.64
SETUP_LOCAL_DEV_SERVICE ?= v0.0.1

.PHONY: all
all: build

.PHONY: build
build: rebuild-cmake install-pkgs
	(cd build && ninja build)

.PHONY: build/host/CMakeCache.txt
build/CMakeCache.txt:
	$(MAKE) rebuild-cmake

.PHONY: install-pkgs
install-pkgs: rebuild-cmake
	(cd build && ninja download_packages)

.PHONY: disable-supabase-tests disable-mosquitto-tests
disable-supabase-tests: build/CMakeCache.txt
	(cd build && cmake -DWITH_LOCAL_SUPABASE=OFF .)

disable-mosquitto-tests: build/CMakeCache.txt
	(cd build && cmake -DWITH_MOSQUITTO=OFF .)

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

.PHONY: add-default-brokers
add-default-brokers: install-pkgs
	@ # Adds the Toitware supabase Artemis server and makes it the default.
	@ $(TOIT_RUN_BIN) src/cli/cli.toit config broker add --no-default supabase \
		--certificate="$(ARTEMIS_CERTIFICATE)" \
		artemis $(ARTEMIS_HOST) "$(ARTEMIS_ANON)"
	@ $(TOIT_RUN_BIN) src/cli/cli.toit config broker default --artemis artemis
	@ $(TOIT_RUN_BIN) src/cli/cli.toit config broker default artemis
	@ # Adds the AWS MQTT broker *without* making it the default.
	@ $(TOIT_RUN_BIN) src/cli/cli.toit config broker add --no-default mqtt \
		--root-certificate "$(AWS_ROOT_CERTIFICATE)" \
		--client-certificate "$(AWS_CLIENT_CERTIFICATE_PATH)" \
		--client-private-key "$(AWS_CLIENT_PRIVATE_KEY_PATH)" \
		aws $(AWS_HOST) $(AWS_PORT)

.PHONY: add-local-http-brokers start-local-http-brokers
add-local-http-brokers: install-pkgs
	@ # Adds the local Artemis server and makes it the default.
	@ # Use the public IP, so that we can flash devices which then can use
	@ # the broker.
	@ $(TOIT_RUN_BIN) src/cli/cli.toit config broker add http \
		--host=`$(TOIT_RUN_BIN) tools/external_ip/external_ip.toit` \
		--port 4999 \
		artemis-local-http
	@ $(TOIT_RUN_BIN) src/cli/cli.toit config broker default --artemis artemis-local-http
	@ # Adds the local broker and makes it the default.
	@ $(TOIT_RUN_BIN) src/cli/cli.toit config broker add http \
		--host=`$(TOIT_RUN_BIN) tools/external_ip/external_ip.toit` \
		--port 4998 \
		broker-local-http
	@ $(TOIT_RUN_BIN) src/cli/cli.toit config broker default broker-local-http

start-local-http-brokers: add-local-http-brokers
	@ rm -rf $$HOME/.cache/artemis/artemis-local-http
	@ rm -rf $$HOME/.cache/artemis/broker-local-http
	@ $(TOIT_RUN_BIN) tools/http_servers/combined.toit \
		--artemis-port 4999 \
		--broker-port 4998

.PHONY: add-local-supabase-brokers start-local-supabase-brokers
add-local-supabase-brokers:
	# Adds the local Artemis server and makes it the default.
	$(TOIT_RUN_BIN) src/cli/cli.toit config broker add supabase \
		artemis-local-supabase \
		$$($(TOIT_RUN_BIN) tests/supabase_local_server.toit supabase_artemis)
	$(TOIT_RUN_BIN) src/cli/cli.toit config broker default --artemis artemis-local-supabase
	$(TOIT_RUN_BIN) src/cli/cli.toit config broker default artemis-local-supabase

start-local-supabase-brokers:
	@ rm -rf $$HOME/.cache/artemis/artemis-local-supabase
	@ if supabase status --workdir supabase_artemis; then \
	  supabase db reset --workdir supabase_artemis; \
	else \
	  supabase start --workdir supabase_artemis; \
	fi
	@ $(MAKE) add-local-supabase-brokers

.PHONY: add-local-customer-broker start-local-customer-broker
add-local-customer-broker:
	@ # Adds the local broker using a second Supabase instance.
	@ $(TOIT_RUN_BIN) src/cli/cli.toit config broker add supabase \
		broker-local-supabase \
		`$(TOIT_RUN_BIN) tests/supabase_local_server.toit supabase_broker`
	@ $(TOIT_RUN_BIN) src/cli/cli.toit config broker default broker-local-supabase

start-local-customer-broker:
	@ rm -rf $$HOME/.cache/artemis/broker-local-supabase
	@ if supabase status --workdir supabase_broker; then \
	  supabase db reset --workdir supabase_broker; \
	else \
	  supabase start --workdir supabase_broker; \
	fi
	@ $(MAKE) add-local-customer-broker

.PHONY: add-local-mosquitto-broker start-local-mosquitto-broker
add-local-mosquitto-broker:
	@ # Adds the local broker and makes it the default.
	@ $(TOIT_RUN_BIN) src/cli/cli.toit config broker add mqtt \
		broker-local-mosquitto \
		`$(TOIT_RUN_BIN) tools/external_ip/external_ip.toit` \
		3998
	@ $(TOIT_RUN_BIN) src/cli/cli.toit config broker default broker-local-mosquitto

start-local-mosquitto-broker: add-local-mosquitto-broker
	@ rm -rf $$HOME/.cache/artemis/broker-local-mosquitto
	@ mosquitto -c tools/mosquitto.conf


.PHONY: setup-local-dev upload-service
setup-local-dev:
	@ # The HTTP server doesn't have any default users.
	if [[ $$($(TOIT_RUN_BIN) src/cli/cli.toit config broker default --artemis) == "artemis-local-http" ]]; then \
	    echo "SIGNING UP"; \
	    $(TOIT_RUN_BIN) src/cli/cli.toit auth artemis signup --email test-admin@toit.io --password password; \
	  fi
	@ $(TOIT_RUN_BIN) src/cli/cli.toit auth artemis login --email test-admin@toit.io --password password
	@ if [[ $$($(TOIT_RUN_BIN) src/cli/cli.toit config broker default --artemis) != $$($(TOIT_RUN_BIN) src/cli/cli.toit config broker default --artemis) ]]; then \
	    $(TOIT_RUN_BIN) src/cli/cli.toit auth broker login --email test@example.com --password password; \
	  fi

	@ $(TOIT_RUN_BIN) src/cli/cli.toit org create "Test Org"

	@ $(MAKE) upload-service

upload-service:
	@ $(TOIT_RUN_BIN) tools/service_image_uploader/uploader.toit service --local \
	    --sdk-version=$(SETUP_LOCAL_DEV_SDK) \
	    --service-version=$(SETUP_LOCAL_DEV_SERVICE) \

# We rebuild the cmake file all the time.
# We use "glob" in the cmakefile, and wouldn't otherwise notice if a new
# file (for example a test) was added or removed.
# It takes <1s on Linux to run cmake, so it doesn't hurt to run it frequently.
.PHONY: rebuild-cmake
rebuild-cmake:
	mkdir -p build
	(cd build && cmake .. -G Ninja)
