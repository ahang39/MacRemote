# Contributing to MacRemote

Thanks for helping make native Windows-to-Mac remote desktop better. MacRemote welcomes focused contributions.

## Before you contribute

- Read [LICENSE](LICENSE) and [third-party notices](THIRD_PARTY_NOTICES.md).
- Use issues for reproducible bug reports, small improvements and design discussion.
- **Never include** real Mac account credentials, session recordings, private certificates, local IP addresses or unredacted system logs.
- Keep changes focused and testable. Avoid adding services, dependencies or fallback state machines without a clear verified need.
- Only contribute work you have the right to license. Upstream FreeRDP fixes should be supplied as isolated patches against the pinned release, with original upstream licensing respected.

## Development

See [build and tests](docs/m2/README.md) and [engineering rules](docs/ENGINEERING.md).

- Use small conventional commits, e.g. `fix(input): release mouse button on disconnect`.
- Run relevant tests. The local build script runs 11 CTests plus Swift settings tests; GitHub checks cover lightweight source-level validation.
- Keep README and tests aligned with observed behavior. Mark client integration steps that still require hands-on validation.
- Pull requests should explain the behavior change, tests, compatibility effects and any dependency/license changes.

## Rights in contributions

By submitting a contribution, you represent that you have the right to license it and agree to make your original contribution available under **PolyForm Noncommercial 1.0.0**, unless a different license is agreed in writing. Upstream FreeRDP changes and patches remain subject to their original Apache-2.0 license.

Copyright stays with each contributor. This repository does not grant the maintainers extra relicensing rights over third-party contributions.
