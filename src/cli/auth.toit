// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import cli show Cli

interface Authenticatable:
  /**
  Ensures that the user is authenticated.

  If the user is not authenticated, the $block is called with an
    error string.
  */
  ensure-authenticated [block]

  /**
  Signs the user up with the given $email and $password.
  */
  sign-up --email/string --password/string

  /**
  Signs the user in with the given $email and $password.
  */
  sign-in --email/string --password/string

  /**
  Signs the user in using OAuth.
  */
  sign-in --provider/string --cli/Cli --open-browser/bool

  /**
  Updates the user's email and/or password.
  */
  update --email/string? --password/string?

  /**
  Logs the user out.
  */
  logout
