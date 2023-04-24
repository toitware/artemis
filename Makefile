# Copyright (C) 2022 Toitware ApS.

TOIT_RUN_BIN?=toit.run

SETUP_LOCAL_DEV_SDK ?= v2.0.0-alpha.79
SETUP_LOCAL_DEV_SERVICE ?= v0.0.1

export ARTEMIS_CONFIG := $(HOME)/.config/artemis-dev/config

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

.PHONY: disable-supabase-tests
disable-supabase-tests: build/CMakeCache.txt
	(cd build && cmake -DWITH_LOCAL_SUPABASE=OFF .)

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

.PHONY: start-http
start-http: install-pkgs
	@ # Adds the local Artemis server and makes it the default.
	@ # Use the public IP, so that we can flash devices which then can use
	@ # the broker.
	@ $(TOIT_RUN_BIN) src/cli/cli.toit config broker add http \
		--host=`$(TOIT_RUN_BIN) tools/lan_ip/lan_ip.toit` \
		--port 4999 \
		artemis-local-http
	@ $(TOIT_RUN_BIN) src/cli/cli.toit config broker default --artemis artemis-local-http
	@ # Adds the local broker and makes it the default.
	@ $(TOIT_RUN_BIN) src/cli/cli.toit config broker add http \
		--host=`$(TOIT_RUN_BIN) tools/lan_ip/lan_ip.toit` \
		--port 4998 \
		broker-local-http
	@ $(TOIT_RUN_BIN) src/cli/cli.toit config broker default broker-local-http
	@ rm -rf $$HOME/.cache/artemis/artemis-local-http
	@ rm -rf $$HOME/.cache/artemis/broker-local-http
	@ $(TOIT_RUN_BIN) tools/http_servers/combined.toit \
		--artemis-port 4999 \
		--broker-port 4998

.PHONY: start-supabase stop-supabase start-supabase-no-config
# Starts the Supabase servers but doesn't add them to the config.
# This is useful so that the tests succeed.
start-supabase-no-config:
	@ rm -rf $$HOME/.cache/artemis/artemis-local-supabase
	@ if supabase status --workdir supabase_artemis &> /dev/null; then \
	  supabase db reset --workdir supabase_artemis; \
	else \
	  supabase start --workdir supabase_artemis; \
	fi
	@ rm -rf $$HOME/.cache/artemis/broker-local-supabase
	@ if supabase status --workdir supabase_broker &> /dev/null ; then \
	  supabase db reset --workdir supabase_broker; \
	else \
	  supabase start --workdir supabase_broker; \
	fi

start-supabase: start-supabase-no-config
	@ # Add the local Artemis server and makes it the default.
	@ $(TOIT_RUN_BIN) src/cli/cli.toit config broker add supabase \
		artemis-local-supabase \
		$$($(TOIT_RUN_BIN) tests/supabase_local_server.toit supabase_artemis)
	@ $(TOIT_RUN_BIN) src/cli/cli.toit config broker default --artemis artemis-local-supabase
	@ $(TOIT_RUN_BIN) src/cli/cli.toit config broker default artemis-local-supabase
	@ echo "Run 'make use-customer-supabase-broker' to use the customer broker."

stop-supabase:
	@ supabase stop --workdir supabase_artemis
	@ supabase stop --workdir supabase_broker

.PHONY: use-customer-supabase-broker
use-customer-supabase-broker: start-supabase
	@ # Adds the local broker using a second Supabase instance.
	@ $(TOIT_RUN_BIN) src/cli/cli.toit config broker add supabase \
		broker-local-supabase \
		`$(TOIT_RUN_BIN) tests/supabase_local_server.toit supabase_broker`
	@ $(TOIT_RUN_BIN) src/cli/cli.toit config broker default broker-local-supabase

.PHONY: setup-local-dev
setup-local-dev:
	@ # The HTTP server doesn't have any default users.
	@ if [[ $$($(TOIT_RUN_BIN) src/cli/cli.toit config broker default --artemis) == "artemis-local-http" ]]; then \
	    $(TOIT_RUN_BIN) src/cli/cli.toit auth signup --email test-admin@toit.io --password password; \
	  fi
	@ $(TOIT_RUN_BIN) src/cli/cli.toit auth login --email test-admin@toit.io --password password
	@ if [[ $$($(TOIT_RUN_BIN) src/cli/cli.toit config broker default --artemis) != $$($(TOIT_RUN_BIN) src/cli/cli.toit config broker default --artemis) ]]; then \
	    $(TOIT_RUN_BIN) src/cli/cli.toit auth login --broker --email test@example.com --password password; \
	  fi

	@ $(TOIT_RUN_BIN) src/cli/cli.toit org create "Test Org"

	@ $(MAKE) upload-service

.PHONY: upload-service
upload-service:
	@ $(TOIT_RUN_BIN) tools/service_image_uploader/uploader.toit service --local --force \
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
