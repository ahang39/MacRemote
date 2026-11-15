# Security policy

## Supported versions

Security fixes target the latest source on the default main branch. Check the repository release notes for supported binary versions when published.

## Report a vulnerability

Please use GitHub's **private vulnerability reporting** for the repository once enabled (repository *Security* tab → *Report a vulnerability*). Do not include exploit steps, authentication material, private certificates, or unredacted logs in public issues. If private reporting is not enabled yet, open a **minimal public request for a private contact channel** without vulnerability details.

Include the affected commit, supported macOS version, reproducible impact and whether an authenticated RDP client is required. Remove hostnames, IP addresses, credentials, clipboard contents and screenshots containing personal data.

## Deployment guidance

Current RDP authentication is **TLS + macOS PAM without NLA**. The alpha is intended for trusted private networks and active local users, not direct Internet exposure. Verify server certificates before typing a Mac password; do not disable certificate checks on an untrusted network.
