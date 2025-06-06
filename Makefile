# Copyright (C) 2022 Toitware ApS.

SHELL=bash
.SHELLFLAGS += -e

ifeq ($(OS),Windows_NT)
  EXE_SUFFIX=.exe
  DETECTED_OS=$(OS)
else
  EXE_SUFFIX=
  DETECTED_OS=$(shell uname)
endif

TOIT ?= toit$(EXE_SUFFIX)

LOCAL_DEV_SDK ?= v2.0.0-alpha.184
SETUP_LOCAL_DEV_SERVICE ?= v0.0.1

SUPABASE_DIRS := supabase_artemis public/supabase_broker

# If the 'DEV_TOIT_REPO_PATH' variable is set, use the toit in its bin
# directory.
ifneq ($(DEV_TOIT_REPO_PATH),)
	TOIT := $(DEV_TOIT_REPO_PATH)/build/host/sdk/bin/toit$(EXE_SUFFIX)
endif

export ARTEMIS_CONFIG := $(HOME)/.config/artemis-dev/config

.PHONY: all
all: build

.PHONY: build
build: rebuild-cmake install-pkgs
	(cd build && ninja build)

.PHONY: build/CMakeCache.txt
build/CMakeCache.txt:
	$(MAKE) rebuild-cmake

.PHONY: install-pkgs
install-pkgs: rebuild-cmake
	(cd build && ninja download_packages)

.PHONY: disable-supabase-tests
disable-supabase-tests: build/CMakeCache.txt
	cmake -DWITH_LOCAL_SUPABASE=OFF build

.PHONY: disable-qemu-tests
disable-qemu-tests: build/CMakeCache.txt
	cmake -DWITH_QEMU=OFF build

.PHONY: test
test: install-pkgs rebuild-cmake download-sdk
	(cd build && ninja check)

.PHONY: test-serial
test-serial: install-pkgs rebuild-cmake download-sdk
	(cd build && ninja check_serial)

.PHONY: test-supabase
test-supabase: install-pkgs rebuild-cmake download-sdk
	(cd build && ninja check_supabase)

# From https://app.supabase.com/project/voisfafsfolxhqpkudzd/settings/auth
ARTEMIS_HOST := voisfafsfolxhqpkudzd.supabase.co
ARTEMIS_ANON := eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZvaXNmYWZzZm9seGhxcGt1ZHpkIiwicm9sZSI6ImFub24iLCJpYXQiOjE2NzMzNzQyNDEsImV4cCI6MTk4ODk1MDI0MX0.dmfxNl5WssxnZ8jpvGJeryg4Fd47fOcrlZ8iGrHj2e4
ARTEMIS_CERTIFICATE := Baltimore CyberTrust Root

# From https://supabase.com/dashboard/project/ezxwpyeoypvnnldpdotx/settings/api
ARTEMIS_TEST_HOST := ezxwpyeoypvnnldpdotx.supabase.co
ARTEMIS_TEST_ANON := eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImV6eHdweWVveXB2bm5sZHBkb3R4Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3MDY3MjQxOTcsImV4cCI6MjAyMjMwMDE5N30.lnzyjQAD1QHqKTCnkuXvuwUuMqDKMw7z7cH8vETeCiQ
ARTEMIS_TEST_CERTIFICATE := Baltimore CyberTrust Root

.PHONY: setup-remote-test-supabase
setup-remote-test-supabase:
	@ $(TOIT) run -- src/cli/cli.toit config broker add supabase \
		--certificate "$(ARTEMIS_TEST_CERTIFICATE)" \
		artemis-remote-test-supabase \
		$(ARTEMIS_TEST_HOST) \
		$(ARTEMIS_TEST_ANON)
	@ $(TOIT) run -- src/cli/cli.toit config broker default --artemis artemis-remote-test-supabase
	@ $(TOIT) run -- src/cli/cli.toit config broker default artemis-remote-test-supabase

.PHONY: start-http
start-http: install-pkgs
	@ # Adds the local Artemis server and makes it the default.
	@ # Use the public IP, so that we can flash devices which then can use
	@ # the broker.
	@ $(TOIT) run -- src/cli/cli.toit config broker add http \
		--host=`$(TOIT) run -- tools/lan_ip/lan-ip.toit` \
		--port 4999 \
		--path / \
		--admin-header "X-Artemis-Header=true" \
		--device-header "X-Artemis-Header=true" \
		artemis-local-http
	@ $(TOIT) run -- src/cli/cli.toit config broker default --artemis artemis-local-http
	@ # Adds the local broker and makes it the default.
	@ $(TOIT) run -- src/cli/cli.toit config broker add http \
		--host=`$(TOIT) run -- tools/lan_ip/lan-ip.toit` \
		--port 4998 \
		--path / \
		--admin-header "X-Artemis-Header=true" \
		--device-header "X-Artemis-Header=true" \
		broker-local-http
	@ $(TOIT) run -- src/cli/cli.toit config broker default broker-local-http
	@ rm -rf $$HOME/.cache/artemis/artemis-local-http
	@ rm -rf $$HOME/.cache/artemis/broker-local-http
	@ $(TOIT) run -- tools/http_servers/combined.toit \
		--artemis-port 4999 \
		--broker-port 4998

.PHONY: start-supabase stop-supabase start-supabase-no-config reload-supabase-schemas
# Starts the Supabase servers but doesn't add them to the config.
# This is useful so that the tests succeed.
start-supabase-no-config:
	@ rm -rf $$HOME/.cache/artemis/artemis-local-supabase
	@ rm -rf $$HOME/.cache/artemis/broker-local-supabase
	@ for dir in $(SUPABASE_DIRS); do \
		if supabase status --workdir $$dir &> /dev/null; then \
			supabase stop --no-backup --workdir $$dir; \
		fi; \
		supabase start --workdir $$dir; \
	done
	@ $(MAKE) reload-supabase-schemas

reload-supabase-schemas:
	@ for container in $$(docker ps | grep postgrest: | awk '{print $$1}'); do \
	    docker kill -s SIGUSR1 $$container; \
		done

start-supabase: start-supabase-no-config
	@ # Add the local Artemis server and makes it the default.
	@ $(TOIT) run -- src/cli/cli.toit config broker add supabase \
		artemis-local-supabase \
		$$($(TOIT) run -- tests/supabase-local-server.toit supabase_artemis)
	@ $(TOIT) run -- src/cli/cli.toit config broker default --artemis artemis-local-supabase
	@ $(TOIT) run -- src/cli/cli.toit config broker default artemis-local-supabase
	@ echo "Run 'make use-customer-supabase-broker' to use the customer broker."

stop-supabase:
	@ for dir in $(SUPABASE_DIRS); do \
		supabase stop --no-backup --workdir $$dir; \
	done

.PHONY: update-sql-quashed
update-sql-squashed:
	@ for dir in $(SUPABASE_DIRS); do \
		TMP_DIR=$$(mktemp -d); \
		cp -r $$dir/supabase/migrations/* "$$TMP_DIR"; \
		touch $$dir/supabase/migrations/20990101000000_squashed.sql; \
		supabase --workdir $$dir migration squash; \
		mv $$dir/supabase/migrations/20990101000000_squashed.sql $$dir/squashed.sql; \
		cp -r "$$TMP_DIR/"* $$dir/supabase/migrations/; \
		rm -rf "$$TMP_DIR"; \
	done

.PHONY: use-customer-supabase-broker
use-customer-supabase-broker: start-supabase
	@ # Adds the local broker using a second Supabase instance.
	@ $(TOIT) run -- src/cli/cli.toit config broker add supabase \
		broker-local-supabase \
		`$(TOIT) run -- tests/supabase-local-server.toit public/supabase_broker`
	@ $(TOIT) run -- src/cli/cli.toit config broker default broker-local-supabase

.PHONY: setup-local-dev
setup-local-dev:
	@ # The HTTP server doesn't have any default users.
	@ if [[ $$($(TOIT) run -- src/cli/cli.toit config broker default --artemis) == "artemis-local-http" ]]; then \
	    $(TOIT) run -- src/cli/cli.toit auth signup --email test-admin@toit.io --password password; \
	  fi
	@ $(TOIT) run -- src/cli/cli.toit auth login --email test-admin@toit.io --password password
	@ if [[ $$($(TOIT) run -- src/cli/cli.toit config broker default --artemis) != $$($(TOIT) run -- src/cli/cli.toit config broker default --artemis) ]]; then \
	    $(TOIT) run -- src/cli/cli.toit auth login --broker --email test@example.com --password password; \
	  fi

	@ $(TOIT) run -- src/cli/cli.toit org add "Test Org"

	@ $(MAKE) upload-service

.PHONY: dev-sdk-version
dev-sdk-version:
	@ echo $(LOCAL_DEV_SDK)

.PHONY: upload-service
upload-service:
	@ $(TOIT) run -- tools/service_image_uploader/uploader.toit service --local --force \
		--sdk-version=$(LOCAL_DEV_SDK) \
		--service-version=$(SETUP_LOCAL_DEV_SERVICE)
	@ $(TOIT) run -- tools/service_image_uploader/uploader.toit service --local --force \
		--sdk-version=$(LOCAL_DEV_SDK) \
		--service-version=$$(cmake -DPRINT_VERSION=1 -P tools/gitversion.cmake)

.PHONY: download-sdk
download-sdk: install-pkgs
	@ $(TOIT) run -- tools/service_image_uploader/sdk-downloader.toit download \
	    --version $(LOCAL_DEV_SDK) \
			--envelope=esp32,esp32-qemu
	@ cmake \
		-DDEV_SDK_VERSION=$(LOCAL_DEV_SDK) \
		-DDEV_SDK_PATH="$$($(TOIT) run -- tools/service_image_uploader/sdk-downloader.toit --version $(LOCAL_DEV_SDK) print)" \
		-DDEV_ENVELOPE_ESP32_PATH="$$($(TOIT) run -- tools/service_image_uploader/sdk-downloader.toit --version $(LOCAL_DEV_SDK) print --envelope="esp32")" \
		-DDEV_ENVELOPE_ESP32_QEMU_PATH="$$($(TOIT) run -- tools/service_image_uploader/sdk-downloader.toit --version $(LOCAL_DEV_SDK) print --envelope="esp32-qemu")" \
		-DDEV_ENVELOPE_HOST_PATH="$$($(TOIT) run -- tools/service_image_uploader/sdk-downloader.toit --version $(LOCAL_DEV_SDK) print --host-envelope)" \
		build

# We rebuild the cmake file all the time.
# We use "glob" in the cmakefile, and wouldn't otherwise notice if a new
# file (for example a test) was added or removed.
# It takes <1s on Linux to run cmake, so it doesn't hurt to run it frequently.
.PHONY: rebuild-cmake
rebuild-cmake:
	mkdir -p build
	(cd build && cmake .. -DDEFAULT_SDK_VERSION=$(LOCAL_DEV_SDK) -G Ninja)

.PHONY: update-pkgs
update-pkgs:
	for d in $$(git ls-files | grep package.yaml); do \
	  toit pkg update --project-root $$(dirname $$d); \
	done
