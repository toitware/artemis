// Copyright (C) 2025 Toit contributors.

import log.target
import system.api.log show LogServiceClient

resolve-log-service_:
  old-service := target.service_
  if old-service is target.StandardLogService_:
    target.service_ = (LogServiceClient).open --if-absent=: old-service
