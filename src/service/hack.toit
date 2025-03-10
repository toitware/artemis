// Copyright (C) 2025 Toit contributors.

import log.target
import system.api.log show LogServiceClient

clear-log-service_:
  old-service := target.service_
  if old-service is target.DefaultTarget:
    target.service_ := (LogServiceClient).open --if-absent=: old-service
