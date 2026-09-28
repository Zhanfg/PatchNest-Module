# FR-014 device candidate v2

Reviewed runtime base: `f927a2738b7b3ae4cfc4a811897a1be9bc6acbe3`.

This branch is for physical FR-014 validation only. Relative to the reviewed runtime base, module runtime behavior may differ only by removal of `module/FLASH_REVIEW_BLOCKED` and addition of `module/FR014_DEVICE_CANDIDATE`. Repository-side candidate packaging may additionally require that marker and reject the normal blocker.

Do not merge or publish this branch as a general release until the physical lifecycle evidence passes.
