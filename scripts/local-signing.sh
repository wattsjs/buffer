#!/usr/bin/env bash
# Source this helper, then call buffer_configure_signing normal|synthetic.
# Keep xcodebuild arguments as an array; config is never sourced or evaluated.

buffer_configure_signing() {
  local signing_root
  signing_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  BUFFER_SIGNING_IDENTITY="$(python3 "$signing_root/scripts/local_signing.py" --mode "$1")" || return $?
  BUFFER_SIGNING_ARGS=(
    CODE_SIGN_STYLE=Manual
    "CODE_SIGN_IDENTITY=$BUFFER_SIGNING_IDENTITY"
    DEVELOPMENT_TEAM=
    CODE_SIGNING_ALLOWED=YES
  )
  if [[ "$BUFFER_SIGNING_IDENTITY" == '-' ]]; then
    BUFFER_SIGNING_ARGS+=(CODE_SIGNING_REQUIRED=NO)
  else
    BUFFER_SIGNING_ARGS+=(CODE_SIGNING_REQUIRED=YES)
  fi
}

buffer_verify_signing() {
  local app_path="$1"
  /usr/bin/codesign --verify --deep --strict "$app_path" || return $?
  if [[ "$BUFFER_SIGNING_IDENTITY" != '-' ]]; then
    # Current codesign treats -R <arg> as a requirement file. The
    # string form is -R=<requirement>.
    /usr/bin/codesign --verify --strict \
      -R="certificate leaf = H\"$BUFFER_SIGNING_IDENTITY\" and identifier \"com.wattsjs.buffer\"" \
      "$app_path" || return $?
  fi
}
