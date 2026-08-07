# KPM signing-key policy

PatchNest treats the KPM signing public key as release-critical configuration.
The key is recorded in both `version.properties` and `module/kpm_verify.sh`, with
a SHA-256 fingerprint calculated over the raw 32-byte Ed25519 public key.

## Current state

The current key status is `development`. It is valid only for local, CI-free,
non-published compatibility and lifecycle testing. It must not be represented as
a production release key.

Run the consistency check:

```sh
python3 scripts/verify_signing_key_policy.py
```

This verifies:

- the configured public key is exactly 32 bytes of lowercase hex;
- the shell verifier contains exactly one literal public key;
- both copies are identical;
- the stored SHA-256 fingerprint matches the raw public key;
- the status is either `development` or `production`.

## Release gate

A publishable candidate must additionally pass:

```sh
python3 scripts/verify_signing_key_policy.py --release-ready
```

This command fails while the status remains `development`. Changing the status
to `production` is permitted only after all of the following are documented:

1. a new Ed25519 keypair was generated outside the repository;
2. the private key is held in an access-controlled signing environment and was
   never committed, uploaded to an issue, included in a build artifact, or
   copied into the module;
3. at least two maintainers verified the raw public key and SHA-256 fingerprint
   through an independent channel;
4. `version.properties`, `module/kpm_verify.sh`, build provenance, and release
   notes identify the same public key;
5. a signed diagnostic KPM is accepted and a tampered artifact is rejected on a
   physical test device;
6. a rotation and revocation procedure exists before the first public release.

The repository stores only the public key and its fingerprint. It must not
contain a private signing seed, expanded private key, encrypted private-key
archive, recovery phrase, or secret-sharing fragment.

## Rotation

A key rotation is a compatibility boundary. It requires:

- a versioned migration note;
- an explicit decision on whether old signatures remain trusted;
- new valid/tampered test vectors;
- an updated public-key fingerprint;
- a complete source, WebUI, package, and physical-device validation run;
- no silent fallback to the previous key.
