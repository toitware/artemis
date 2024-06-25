// Copyright (C) 2024 Toitware ApS.

import artemis-pkg.artemis as artemis
import host.os
import http
import net
import system.storage

TEST-URL-ENV ::= "TEST-URL"

main:
  client := http.Client net.open
  test-url := os.env[TEST-URL-ENV]
  client.get --uri=test-url

  artemis.reboot --safe-mode
