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
	$(TOIT_RUN_BIN) src/cli/cli.toit config broker use --artemis artemis

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

# We rebuild the cmake file all the time.
# We use "glob" in the cmakefile, and wouldn't otherwise notice if a new
# file (for example a test) was added or removed.
# It takes <1s on Linux to run cmake, so it doesn't hurt to run it frequently.
.PHONY: rebuild-cmake
rebuild-cmake:
	mkdir -p build
	(cd build && cmake .. -G Ninja)
