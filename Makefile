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

ARTEMIS_HOST := uelhwhbsyumuqhbukich.supabase.co
ARTEMIS_ANON := eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVlbGh3aGJzeXVtdXFoYnVraWNoIiwicm9sZSI6ImFub24iLCJpYXQiOjE2NjM1OTU0NDYsImV4cCI6MTk3OTE3MTQ0Nn0.X6yvaUJDoN0Zk1xjYy_Ap-w6NhCc5BtyWnh5zGdoPFo
ARTEMIS_CERTIFICATE := Baltimore CyberTrust Root

TOITWARE_TESTING_HOST := fjdivzfiphllkyxczmgw.supabase.co
TOITWARE_TESTING_ANON := eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZqZGl2emZpcGhsbGt5eGN6bWd3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE2NjQ5NTQxMjIsImV4cCI6MTk4MDUzMDEyMn0.ge4XAeh3xEHQokn-ayPKi1N0cQO_c8bhBzLli-I9bqU
TOITWARE_TESTING_CERTIFICATE := Baltimore CyberTrust Root

.PHONY: add-default-brokers
add-default-brokers:
	toit.run src/cli/cli.toit config broker add supabase \
		--certificate="$(ARTEMIS_CERTIFICATE)" artemis $(ARTEMIS_HOST) "$(ARTEMIS_ANON)"
	toit.run src/cli/cli.toit config broker add supabase \
		--certificate="$(TOITWARE_TESTING_CERTIFICATE)" toitware-testing $(TOITWARE_TESTING_HOST) "$(TOITWARE_TESTING_ANON)"


# We rebuild the cmake file all the time.
# We use "glob" in the cmakefile, and wouldn't otherwise notice if a new
# file (for example a test) was added or removed.
# It takes <1s on Linux to run cmake, so it doesn't hurt to run it frequently.
.PHONY: rebuild-cmake
rebuild-cmake:
	mkdir -p build
	(cd build && cmake .. -G Ninja)
