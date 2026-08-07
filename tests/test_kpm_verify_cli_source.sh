#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat >"$WORK/monocypher-ed25519.h" <<'HEADER'
#ifndef MONOCYPHER_ED25519_H
#define MONOCYPHER_ED25519_H
#include <stddef.h>
#include <stdint.h>
int crypto_ed25519_check(const uint8_t signature[64],
                         const uint8_t public_key[32],
                         const uint8_t *message, size_t message_size);
void crypto_wipe(void *secret, size_t size);
#endif
HEADER

cat >"$WORK/monocypher-stub.c" <<'STUB'
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include "monocypher-ed25519.h"
int crypto_ed25519_check(const uint8_t signature[64],
                         const uint8_t public_key[32],
                         const uint8_t *message, size_t message_size)
{
    return public_key[0] == 0xa6 && signature[0] == 0x88
        && message_size == 5 && memcmp(message, "probe", 5) == 0 ? 0 : -1;
}
void crypto_wipe(void *secret, size_t size)
{
    volatile uint8_t *bytes = (volatile uint8_t *)secret;
    while (size-- > 0) { *bytes++ = 0; }
}
STUB

cc -std=c11 -D_GNU_SOURCE -O2 -Wall -Wextra -Werror \
  -I"$WORK" \
  "$ROOT/module/tools/kpm-verify.c" "$WORK/monocypher-stub.c" \
  -o "$WORK/kpm-verify"

PUBLIC_KEY=a6cee3371d164daf9ad2ed38ecaf1d492e7867fc6df31f810e69eaa0dd45259b
SIGNATURE=886199b494a8dcb9ddec3a48385f4ea7e3cbefcc90198c6c807fd2434125b20e32f1b8cdd817e782f7fcf80860c4a32f7c49006089a4efefb4b734bbcb30f703

assert_status() {
  local expected=$1
  shift
  set +e
  "$@" >/dev/null 2>&1
  local actual=$?
  set -e
  if [[ "$actual" -ne "$expected" ]]; then
    echo "expected status $expected, got $actual: $*" >&2
    exit 1
  fi
}

printf '%s' probe >"$WORK/message.bin"
assert_status 0 "$WORK/kpm-verify" "$PUBLIC_KEY" "$SIGNATURE" "$WORK/message.bin"

printf '%s' tampered >"$WORK/message.bin"
assert_status 1 "$WORK/kpm-verify" "$PUBLIC_KEY" "$SIGNATURE" "$WORK/message.bin"

printf '%s' probe >"$WORK/message.bin"
assert_status 2 "$WORK/kpm-verify" bad "$SIGNATURE" "$WORK/message.bin"
assert_status 2 "$WORK/kpm-verify" "$PUBLIC_KEY" bad "$WORK/message.bin"

ln -s "$WORK/message.bin" "$WORK/message-link.bin"
assert_status 2 "$WORK/kpm-verify" "$PUBLIC_KEY" "$SIGNATURE" "$WORK/message-link.bin"

truncate -s $((64 * 1024 * 1024 + 1)) "$WORK/oversized.bin"
assert_status 2 "$WORK/kpm-verify" "$PUBLIC_KEY" "$SIGNATURE" "$WORK/oversized.bin"

assert_status 2 "$WORK/kpm-verify"

printf '%s\n' 'KPM verifier CLI source vectors passed.'
