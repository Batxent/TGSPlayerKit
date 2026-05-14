# Security Policy

TGS files can originate from untrusted remote input. Treat compressed and decoded payloads as hostile until validated.

## Supported Versions

No stable release has been published yet. Security fixes apply to the main branch until the first tagged release.

## Reporting

Please do not open a public issue for vulnerabilities. Report privately to the repository maintainer listed on GitHub.

Include:

- A minimal `.tgs` or JSON sample when safe to share.
- Expected behavior.
- Actual behavior.
- Device and OS version.
- Whether the issue occurs during decode, native animation load, rendering, or UIKit submission.

## Current Safety Boundaries

- Compressed input size is capped by `TGSDecoderLimits.maxCompressedBytes`.
- Decoded JSON size is capped by `TGSDecoderLimits.maxDecodedBytes`.
- Unknown binary input is rejected before native rendering.
- UIKit submission is isolated from the native rendering protocol.
