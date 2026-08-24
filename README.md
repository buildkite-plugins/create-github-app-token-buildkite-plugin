# Create GitHub App Token Buildkite Plugin

Creates a short-lived GitHub App installation access token for a command step. The token is registered with the Buildkite redactor before it is exported, narrowed to the current repository by default, and revoked in `pre-exit` after the job finishes.

This is the Buildkite equivalent of [`actions/create-github-app-token`](https://github.com/actions/create-github-app-token), with a reference-only private-key interface suitable for Buildkite Secrets and external secret-manager plugins.

## Example using Buildkite Secrets

Store the App private key as a Buildkite Secret named `GITHUB_APP_PRIVATE_KEY`. The plugin retrieves it only during `pre-command`, rather than injecting the long-lived private key into the whole job environment:

```yaml
steps:
  - command: gh api /user
    plugins:
      - buildkite-plugins/create-github-app-token#v1.0.0:
          client-id: Iv1.0123456789abcdef
          private-key-secret: GITHUB_APP_PRIVATE_KEY
          permissions:
            contents: read
```

`private-key-secret` requires a Buildkite agent that supports `buildkite-agent secret get`. Access to the secret must be allowed by the cluster's agent access policy.

Alternatively, inject a Buildkite Secret into a named environment variable (agent v3.106.0+) and reference the **name**, not the value:

```yaml
steps:
  - command: git ls-remote "https://x-access-token:${GITHUB_TOKEN}@github.com/acme/private-repo.git"
    secrets:
      GITHUB_APP_KEY: GITHUB_APP_PRIVATE_KEY
    plugins:
      - buildkite-plugins/create-github-app-token#v1.0.0:
          app-id: "123456" # Compatibility with Apps using a numeric App ID.
          private-key-env: GITHUB_APP_KEY
          owner: acme
          repositories:
            - private-repo
          permissions:
            contents: read
```

Never put the private key or an expanded environment variable in plugin configuration. Pipeline configuration is uploaded to Buildkite and may be visible to people who can inspect builds. This plugin deliberately has no inline `private-key` option.

## Configuration

### App identity

- **`client-id`**: GitHub App client ID. Preferred by GitHub as the JWT issuer.
- **`client-id-env`**: Name of an environment variable containing the client ID.
- **`app-id`**: Numeric GitHub App ID, supported as a compatibility alias.
- **`app-id-env`**: Name of an environment variable containing the App ID.

Configure exactly one identity source. When compatibility fields overlap, `client-id-env`, `client-id`, `app-id-env`, then `app-id` take precedence.

### Private key

Exactly one is required:

- **`private-key-secret`**: Name of a Buildkite Secret. The hook calls `buildkite-agent secret get`.
- **`private-key-env`**: Name of an environment variable populated by Buildkite Secrets or another secret manager.

Both normal multi-line PEM and PEM containing literal `\n` separators are accepted. Temporary key files are mode `0600` under a private umask and are removed immediately after signing.

### Installation and repository scope

- **`installation-id`**: Optional numeric installation ID. Skips installation discovery.
- **`installation-id-env`**: Environment-variable name containing an installation ID.
- **`owner`**: GitHub organization or user. When supplied without `repositories`, the token can access every repository granted to the installation.
- **`repositories`**: Repository names (maximum 500). Entries may be bare names or `owner/name`; all must have the configured owner.

Without `owner` or `repositories`, the owner and repository are derived from `BUILDKITE_REPO`, including SSH and HTTPS GitHub Enterprise Server remotes. The token is narrowed to that repository. Supplying only `owner` intentionally requests the installation's full repository scope.

### Token options

- **`permissions`**: Map of GitHub permission names to `read` or `write`. Omitted permissions cannot exceed the App installation's grants. If omitted, GitHub uses the installation's granted permissions.
- **`github-api-url`**: HTTPS API root. Defaults to `https://api.github.com`; for GHES this is usually `https://github.example.com/api/v3`.
- **`output-variable`**: Exported variable name. Defaults to `GITHUB_TOKEN`.
- **`skip-revoke`**: Keep the token valid until GitHub expires it (normally one hour). Defaults to `false`.

Example with an explicit installation and GitHub Enterprise Server:

```yaml
plugins:
  - buildkite-plugins/create-github-app-token#v1.0.0:
      client-id-env: GITHUB_APP_CLIENT_ID
      private-key-env: GITHUB_APP_PRIVATE_KEY
      installation-id-env: GITHUB_APP_INSTALLATION_ID
      github-api-url: https://github.example.com/api/v3
      owner: engineering
      repositories: api,web
      output-variable: GHES_TOKEN
      permissions:
        contents: read
        pull_requests: write
```

## Security model

- The App private key is a long-lived, high-value credential. Restrict its Buildkite Secret access policy to the required pipelines and steps, rotate it, and grant the App only necessary permissions.
- The installation token is passed to the command through an environment variable. Commands and processes in the job can read it. Do not run untrusted code in a step that has access to the token.
- The token is sent only to the configured HTTPS GitHub API URL. Proxy and custom CA behavior follows `curl` (`HTTPS_PROXY`, `NO_PROXY`, and the system trust store).
- The token is registered with `buildkite-agent redactor add` before export. Agent v3.67.0 or newer is required; creation fails closed if dynamic redaction is unavailable. Buildkite Secrets are independently redacted by Buildkite.
- Revocation is best-effort so a GitHub outage during `pre-exit` does not hide the command's result. A short-lived token may remain valid until expiry if revocation fails or the agent is terminated before `pre-exit`.
- On Agent Stack for Kubernetes, hooks and commands must share an environment and filesystem for the exported token and revocation state. Verify this lifecycle for your pod/container configuration.

## Requirements

Unix-like agent with Bash, Buildkite Agent, curl, jq, and OpenSSL. No language runtime or package installation is required.

## Development

```sh
docker compose run --rm tests
docker compose run --rm shellcheck
docker compose run --rm lint
```

The test suite uses Bats and exercises JWT creation, discovery, narrowing, redaction, revocation, failures, and cleanup.

## License

MIT — see [LICENSE](LICENSE).
