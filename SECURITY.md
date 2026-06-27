# Security

Skillui is a local macOS utility that shells out to the `skills` CLI and reads configured development folders. Please report security issues privately rather than opening a public issue.

## Reporting

Email the maintainer or use a private GitHub security advisory once the repository is published.

Include:

- Affected version or commit.
- Steps to reproduce.
- Impact and any relevant local files or settings involved.

## Security Model

- GitHub personal access tokens are stored in Keychain.
- Skillui does not store a database of scanned skills.
- Default project scanning is limited to common development roots and excludes protected personal folders.
- Application updates come from GitHub Releases and should be distributed as signed, notarized DMGs.
