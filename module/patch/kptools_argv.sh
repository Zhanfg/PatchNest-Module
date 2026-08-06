#!/system/bin/sh
# Normalize kptools patch arguments received from the WebUI argv bridge.
#
# The WebUI historically applied shell quoting to `-A` values even though it
# called spawn() with an argv array. That makes the quote/backslash characters
# part of the real argument. This helper decodes only that known wrapper. It
# never uses eval and leaves every non-`-A` argument byte-for-byte unchanged.

patchnest_decode_spawn_value() {
  _encoded=$1
  [ "${#_encoded}" -le 4096 ] || {
    echo "! -A value exceeds 4096 characters" >&2
    return 1
  }

  case "$_encoded" in
    \"*\")
      _inner=${_encoded#\"}
      _inner=${_inner%\"}
      _clean=$(printf '%s' "$_inner" | tr -d '\000-\037\177')
      [ "$_clean" = "$_inner" ] || {
        echo "! -A value contains control characters" >&2
        return 1
      }
      # Reverse webui/constants.js escapeShell() in the opposite order from
      # encoding: escaped special characters first, doubled backslashes last.
      printf '%s' "$_inner" | sed \
        -e 's/\\"/"/g' \
        -e 's/\\\$/\$/g' \
        -e 's/\\`/`/g' \
        -e 's/\\!/!/g' \
        -e 's/\\\\/\\/g'
      ;;
    \"*|*\")
      echo "! -A value has mismatched WebUI quoting" >&2
      return 1
      ;;
    *)
      _clean=$(printf '%s' "$_encoded" | tr -d '\000-\037\177')
      [ "$_clean" = "$_encoded" ] || {
        echo "! -A value contains control characters" >&2
        return 1
      }
      printf '%s' "$_encoded"
      ;;
  esac
}

run_patchnest_kptools_patch() {
  _original_count=$#
  _processed=0
  _expect_a_value=false

  # Rotate each original positional argument to the end after optional
  # normalization. After exactly N rotations, `$@` contains the normalized
  # arguments in the original order without an intermediate command string.
  while [ "$_processed" -lt "$_original_count" ]; do
    _argument=$1
    shift

    if $_expect_a_value; then
      _argument=$(patchnest_decode_spawn_value "$_argument") || return 2
      _expect_a_value=false
    elif [ "$_argument" = "-A" ]; then
      _expect_a_value=true
    fi

    set -- "$@" "$_argument"
    _processed=$((_processed + 1))
  done

  if $_expect_a_value; then
    echo "! -A requires a value" >&2
    return 2
  fi

  kptools -p -i kernel.ori -k "$KPIMG" -o kernel "$@"
}
