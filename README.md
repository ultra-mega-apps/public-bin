# public-bin — `github-actions-deploy-me.sh`

GitHub Actions OIDC deploy client. The workflow downloads this script
from `main` on every run and executes it. No local copy in the app repo.

## What it does

1. Confirms it runs inside GitHub Actions.
2. Derives the environment from `GITHUB_REF` (never from CLI input):
   `refs/heads/main` → `STAGING`, `refs/tags/*` → `PRODUCTION`.
   Any other ref fails clearly without deploying.
3. Reads the `DEPLOY` organization variable (`ENVIRONMENT|URL|...`)
   and resolves the endpoint for the current environment.
4. Requests an OIDC JWT from GitHub for the fixed audience
   `https://deploy.umapps.net`.
5. `POST <endpoint>/deploy` with `Authorization: Bearer <JWT>` and a JSON
   body (`repository`, `repositoryOwner`, `ref`, `sha`, `environment`,
   plus optional untrusted `params` metadata from CLI args).

## Required environment

`GITHUB_REPOSITORY`, `GITHUB_REPOSITORY_OWNER`, `GITHUB_REF`, `GITHUB_SHA`,
`ACTIONS_ID_TOKEN_REQUEST_URL`, `ACTIONS_ID_TOKEN_REQUEST_TOKEN`, `DEPLOY`.

The workflow needs `id-token: write` permission and
`DEPLOY: ${{ vars.DEPLOY }}` in its env.

Dependencies: `bash`, `curl`, `python3` (all preinstalled on
`ubuntu-latest` runners).

## DEPLOY format

```
STAGING|https://deploy.storage.umapps.net|PRODUCTION|https://oagp1.umapps.net:50000
```

Surrounding spaces are tolerated. Rejected: odd field count, empty
environment/URL, duplicated environment, missing environment
(`No endpoint configured for environment PRODUCTION`), empty input.

## Security notes

- No shared password, no fixed deploy secret; auth is the GitHub OIDC JWT.
- HTTPS is required; plain HTTP is accepted only for `127.0.0.1` /
  `localhost` test endpoints.
- The JWT is kept in memory only: never printed, never written to disk.
- `curl --fail` + timeouts: non-2xx, network errors, timeouts and TLS
  errors all fail the step.

## Example workflow (app repo)

```yaml
name: Deploy
on:
  push:
    branches: [main]
    tags: ['*']
permissions:
  id-token: write
  contents: read
jobs:
  deploy:
    runs-on: ubuntu-latest
    env:
      DEPLOY: ${{ vars.DEPLOY }}
    steps:
      - name: Download deploy client
        run: |
          curl --fail --silent --show-error --location \
            https://raw.githubusercontent.com/ultra-mega-apps/public-bin/main/github-actions-deploy-me.sh \
            --output /tmp/github-actions-deploy-me.sh
          chmod +x /tmp/github-actions-deploy-me.sh
      - name: Deploy
        run: /tmp/github-actions-deploy-me.sh
```

## Tests

```sh
./tests/test-parser.sh
```

Full end-to-end tests (script as a subprocess against a fake OIDC
issuer and a demo server) live in `ultra-mega-apps/deploy-test`.
