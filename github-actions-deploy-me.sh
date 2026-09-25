#!/usr/bin/env bash
#
# github-actions-deploy-me.sh
#
# GitHub Actions OIDC deploy client.
#
# Downloads nothing, stores nothing, prints no tokens. It:
#   1. confirms it runs inside GitHub Actions,
#   2. derives the environment from GITHUB_REF
#        refs/heads/main -> STAGING
#        refs/tags/*     -> PRODUCTION
#      any other ref -> clear failure, no deploy,
#   3. parses the DEPLOY organization variable (ENVIRONMENT|URL|...),
#   4. requests an OIDC JWT from GitHub for a fixed audience,
#   5. POSTs it as a Bearer token to <endpoint>/deploy.
#
# Usage:
#   github-actions-deploy-me.sh [params...]
#
# Everything the script needs (repository, owner, ref, sha, environment)
# comes from the GitHub Actions environment. Extra CLI params are sent
# in the payload as UNTRUSTED metadata only.
#
# Required environment:
#   GITHUB_REPOSITORY, GITHUB_REPOSITORY_OWNER, GITHUB_REF, GITHUB_SHA,
#   ACTIONS_ID_TOKEN_REQUEST_URL, ACTIONS_ID_TOKEN_REQUEST_TOKEN,
#   DEPLOY
#
# Dependencies: bash >= 4, curl, python3 (both preinstalled on
# ubuntu-latest runners). No jq required.
#
# Audience (fixed and documented):
#   https://deploy.umapps.net
#
set -euo pipefail

# Fixed audience for this project. Must match the server/auth library.
AUDIENCE="https://deploy.umapps.net"

err() {
  printf 'error: %s\n' "$*" >&2
}

# Trim leading/trailing whitespace (spaces, tabs, newlines).
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Derive the trusted environment from an authenticated git ref.
# Prints STAGING or PRODUCTION. Returns nonzero for anything else.
environment_from_ref() {
  local ref="$1"
  if [[ "$ref" == "refs/heads/main" ]]; then
    printf 'STAGING'
  elif [[ "$ref" == refs/tags/?* ]]; then
    printf 'PRODUCTION'
  else
    return 1
  fi
}

# Parse DEPLOY (ENVIRONMENT|URL|ENVIRONMENT|URL|...) and print the URL
# for the wanted environment. Returns nonzero with a clear message on:
# empty input, odd field count, empty env/URL, duplicated env,
# or missing wanted environment.
parse_deploy_var() {
  local raw="$1"
  local wanted="$2"

  if [[ -z "$(trim "$raw")" ]]; then
    err "DEPLOY is empty or not set (expected GitHub Actions organization variable 'DEPLOY' in ENVIRONMENT|URL|... format)"
    return 1
  fi

  local -a parts
  IFS='|' read -r -a parts <<< "$raw"

  if (( ${#parts[@]} % 2 != 0 )); then
    err "malformed DEPLOY: odd number of '|' separated fields (expected ENVIRONMENT|URL pairs)"
    return 1
  fi

  local -A seen=()
  local i env url
  for (( i = 0; i < ${#parts[@]}; i += 2 )); do
    env="$(trim "${parts[$i]}")"
    url="$(trim "${parts[$((i + 1))]}")"
    if [[ -z "$env" ]]; then
      err "malformed DEPLOY: empty environment name"
      return 1
    fi
    if [[ -z "$url" ]]; then
      err "malformed DEPLOY: environment '$env' has no URL"
      return 1
    fi
    if [[ -n "${seen[$env]:-}" ]]; then
      err "malformed DEPLOY: duplicated environment '$env'"
      return 1
    fi
    seen["$env"]="$url"
  done

  if [[ -z "${seen[$wanted]:-}" ]]; then
    err "No endpoint configured for environment $wanted"
    return 1
  fi
  printf '%s' "${seen[$wanted]}"
}

# Request an OIDC JWT from GitHub Actions. Prints the token.
# The token is held in a shell variable by the caller, never logged
# and never written to disk.
request_oidc_token() {
  local request_url="$1"
  local request_token="$2"
  ACTIONS_ID_TOKEN_REQUEST_URL="$request_url" \
  ACTIONS_ID_TOKEN_REQUEST_TOKEN="$request_token" \
  OIDC_AUDIENCE="$AUDIENCE" \
  python3 - <<'PYEOF'
import json
import os
import urllib.parse
import urllib.request

base = os.environ["ACTIONS_ID_TOKEN_REQUEST_URL"]
runner_token = os.environ["ACTIONS_ID_TOKEN_REQUEST_TOKEN"]
audience = os.environ["OIDC_AUDIENCE"]

sep = "&" if ("?" in base) else "?"
url = base + sep + "audience=" + urllib.parse.quote(audience, safe="")
req = urllib.request.Request(
    url, headers={"Authorization": "Bearer " + runner_token}
)
try:
    with urllib.request.urlopen(req, timeout=30) as resp:
        data = json.loads(resp.read().decode("utf-8"))
except Exception as exc:
    raise SystemExit("error: failed to request OIDC token from GitHub: %s" % exc)
value = data.get("value", "")
if not value:
    raise SystemExit("error: GitHub OIDC endpoint returned no token")
print(value, end="")
PYEOF
}

# Build the JSON payload. Reads fields from the environment and extra
# CLI params from argv (untrusted metadata). Prints JSON to stdout.
build_payload() {
  PAYLOAD_REPOSITORY="$1"
  PAYLOAD_OWNER="$2"
  PAYLOAD_REF="$3"
  PAYLOAD_SHA="$4"
  PAYLOAD_ENVIRONMENT="$5"
  shift 5
  PAYLOAD_REPOSITORY="$PAYLOAD_REPOSITORY" \
  PAYLOAD_OWNER="$PAYLOAD_OWNER" \
  PAYLOAD_REF="$PAYLOAD_REF" \
  PAYLOAD_SHA="$PAYLOAD_SHA" \
  PAYLOAD_ENVIRONMENT="$PAYLOAD_ENVIRONMENT" \
  python3 - "$@" <<'PYEOF'
import json
import os
import sys

payload = {
    "repository": os.environ["PAYLOAD_REPOSITORY"],
    "repositoryOwner": os.environ["PAYLOAD_OWNER"],
    "ref": os.environ["PAYLOAD_REF"],
    "sha": os.environ["PAYLOAD_SHA"],
    "environment": os.environ["PAYLOAD_ENVIRONMENT"],
}
if len(sys.argv) > 1:
    payload["params"] = sys.argv[1:]
print(json.dumps(payload))
PYEOF
}

main() {
  # 1. Confirm a compatible GitHub Actions environment.
  local missing=()
  for var in GITHUB_REPOSITORY GITHUB_REF GITHUB_SHA \
             ACTIONS_ID_TOKEN_REQUEST_URL ACTIONS_ID_TOKEN_REQUEST_TOKEN DEPLOY; do
    if [[ -z "${!var:-}" ]]; then
      missing+=("$var")
    fi
  done
  if (( ${#missing[@]} > 0 )); then
    err "not running in a compatible GitHub Actions environment (missing: ${missing[*]}). This script must run as a step of a workflow with 'id-token: write' permission and DEPLOY wired from vars.DEPLOY."
    return 1
  fi

  local repository="$GITHUB_REPOSITORY"
  # GITHUB_REPOSITORY_OWNER exists on runners; fall back to the repo prefix.
  local owner="${GITHUB_REPOSITORY_OWNER:-${repository%%/*}}"
  local ref="$GITHUB_REF"
  local sha="$GITHUB_SHA"

  # 2-4. Derive the environment from the ref. Never trust client input:
  # there is no CLI flag or env var that overrides this.
  local environment
  if ! environment="$(environment_from_ref "$ref")"; then
    err "ref '$ref' is not deployable (only refs/heads/main -> STAGING and refs/tags/* -> PRODUCTION)"
    return 1
  fi

  # 5-7. Resolve the endpoint from DEPLOY.
  local endpoint
  if ! endpoint="$(parse_deploy_var "$DEPLOY" "$environment")"; then
    return 1
  fi

  if [[ "$endpoint" != https://* && "$endpoint" != http://* ]]; then
    err "malformed endpoint URL for environment $environment: '$endpoint' (expected https://...)"
    return 1
  fi

  # Never send the OIDC bearer token over plain HTTP on an external
  # network. HTTP is accepted only for loopback test endpoints.
  local scheme="${endpoint%%://*}"
  local rest="${endpoint#*://}"
  local hostport="${rest%%/*}"
  local host="${hostport%%:*}"
  if [[ "$scheme" != "https" ]]; then
    if [[ "$host" != "127.0.0.1" && "$host" != "localhost" && "$host" != "::1" ]]; then
      err "refusing to send OIDC token over insecure HTTP to '$endpoint' (use HTTPS, or HTTP only on 127.0.0.1/localhost for tests)"
      return 1
    fi
  fi

  # 8. Request the OIDC token (kept in memory only).
  local oidc_token
  if ! oidc_token="$(request_oidc_token "$ACTIONS_ID_TOKEN_REQUEST_URL" "$ACTIONS_ID_TOKEN_REQUEST_TOKEN")"; then
    return 1
  fi

  # 9-13. POST the deployment request.
  local payload
  payload="$(build_payload "$repository" "$owner" "$ref" "$sha" "$environment" "$@")"
  local url="${endpoint%/}/deploy"

  local response http_code body
  if ! response="$(printf '%s' "$payload" | curl --fail --silent --show-error \
      --request POST \
      --connect-timeout 10 --max-time 60 \
      --header "Content-Type: application/json" \
      --header "Authorization: Bearer $oidc_token" \
      --data @- \
      --write-out '\n%{http_code}' \
      "$url" 2>&1)"; then
    # Never include the token in error output (curl errors echo only
    # the URL/transfer diagnostics, but stay explicit about it).
    unset oidc_token
    err "deploy request to $url failed for environment $environment"
    # Surface the captured diagnostics without any secret.
    printf '%s\n' "$response" >&2
    return 1
  fi
  unset oidc_token

  http_code="$(printf '%s' "$response" | tail -n 1)"
  body="$(printf '%s' "$response" | sed '$d')"
  if [[ "$http_code" != 2* ]]; then
    err "deploy request to $url returned HTTP $http_code for environment $environment"
    printf '%s\n' "$body" >&2
    return 1
  fi

  printf 'deploy accepted: environment=%s repository=%s ref=%s (HTTP %s)\n' \
    "$environment" "$repository" "$ref" "$http_code"
  if [[ -n "$body" ]]; then
    printf '%s\n' "$body"
  fi
}

# Allow sourcing the file in tests without running main.
if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
  main "$@"
fi
