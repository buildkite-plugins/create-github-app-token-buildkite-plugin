#!/usr/bin/env bats

setup() {
  export TEST_TMPDIR="$(mktemp -d)"
  export TMPDIR="$TEST_TMPDIR/tmp"
  export MOCK_LOG="$TEST_TMPDIR/requests.log"
  mkdir -p "$TMPDIR" "$TEST_TMPDIR/bin"
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$TEST_TMPDIR/key.pem" 2>/dev/null
  export TEST_PRIVATE_KEY="$(cat "$TEST_TMPDIR/key.pem")"
  export TEST_REAL_CAT="$(command -v cat)"
  export TEST_REAL_MKTEMP="$(command -v mktemp)"
  export PATH="$TEST_TMPDIR/bin:$PATH"
  export BUILDKITE_REPO="git@github.com:acme/widgets.git"
  export BUILDKITE_PLUGIN_CREATE_GITHUB_APP_TOKEN_CLIENT_ID="Iv1.0123456789abcdef"
  export BUILDKITE_PLUGIN_CREATE_GITHUB_APP_TOKEN_PRIVATE_KEY_ENV="TEST_PRIVATE_KEY"
  unset GITHUB_TOKEN ACME_GITHUB_TOKEN
  unset_plugin_options
  create_mocks
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

unset_plugin_options() {
  unset BUILDKITE_PLUGIN_CREATE_GITHUB_APP_TOKEN_APP_ID
  unset BUILDKITE_PLUGIN_CREATE_GITHUB_APP_TOKEN_APP_ID_ENV
  unset BUILDKITE_PLUGIN_CREATE_GITHUB_APP_TOKEN_CLIENT_ID_ENV
  unset BUILDKITE_PLUGIN_CREATE_GITHUB_APP_TOKEN_GITHUB_API_URL
  unset BUILDKITE_PLUGIN_CREATE_GITHUB_APP_TOKEN_INSTALLATION_ID
  unset BUILDKITE_PLUGIN_CREATE_GITHUB_APP_TOKEN_INSTALLATION_ID_ENV
  unset BUILDKITE_PLUGIN_CREATE_GITHUB_APP_TOKEN_OUTPUT_VARIABLE
  unset BUILDKITE_PLUGIN_CREATE_GITHUB_APP_TOKEN_OWNER
  unset BUILDKITE_PLUGIN_CREATE_GITHUB_APP_TOKEN_PERMISSIONS_CONTENTS
  unset BUILDKITE_PLUGIN_CREATE_GITHUB_APP_TOKEN_PERMISSIONS_PULL_REQUESTS
  unset BUILDKITE_PLUGIN_CREATE_GITHUB_APP_TOKEN_PERMISSIONS_REPOSITORY_PROJECTS
  unset BUILDKITE_PLUGIN_CREATE_GITHUB_APP_TOKEN_PRIVATE_KEY_SECRET
  unset BUILDKITE_PLUGIN_CREATE_GITHUB_APP_TOKEN_REPOSITORIES
  unset BUILDKITE_PLUGIN_CREATE_GITHUB_APP_TOKEN_REPOSITORIES_0
  unset BUILDKITE_PLUGIN_CREATE_GITHUB_APP_TOKEN_REPOSITORIES_1
  unset BUILDKITE_PLUGIN_CREATE_GITHUB_APP_TOKEN_SKIP_REVOKE
  unset BUILDKITE_PLUGIN_CREATE_GITHUB_APP_TOKEN_OUTPUT_VARIABLE_NAME
}

create_mocks() {
  cat >"$TEST_TMPDIR/bin/buildkite-agent" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1 $2" == "secret get" ]]; then
  [[ "$#" -eq 3 && "$3" == GITHUB_APP_PRIVATE_KEY ]]
  printf '%s' "$TEST_PRIVATE_KEY"
elif [[ "$1 $2" == "redactor add" ]]; then
  [[ "$#" -eq 2 ]]
  token="$(cat)"
  printf 'redactor:%s\n' "$token" >>"$MOCK_LOG"
else
  exit 2
fi
MOCK
  cat >"$TEST_TMPDIR/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
method=GET output= payload= url=
config= auth=
[[ "$1" == -q ]]
shift
while (($#)); do
  [[ "$1" != *Bearer* ]] || exit 9
  case "$1" in
    --config)
      [[ "$2" == - && -z "$config" ]]
      config="$(cat)"
      shift 2
      ;;
    --request) method="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    --data) payload="$2"; shift 2 ;;
    --header|--connect-timeout|--max-time|--write-out) shift 2 ;;
    --silent|--show-error) shift ;;
    *) url="$1"; shift ;;
  esac
done
[[ "$config" =~ ^header\ =\ \"Authorization:\ Bearer\ ([^\"]+)\"$ ]]
auth="${BASH_REMATCH[1]}"
if [[ "$method" == DELETE ]]; then
  [[ "$auth" == ghs_test_token ]]
else
  [[ "$auth" == *.*.* ]]
fi
printf '%s %s %s\n' "$method" "$url" "$payload" >>"$MOCK_LOG"
if [[ "${MOCK_CURL_FAIL:-false}" == true ]]; then exit 7; fi
if [[ "$method" == DELETE ]]; then
  : >"$output"
  printf '%s' "${MOCK_REVOKE_STATUS:-204}"
elif [[ "$url" == */access_tokens ]]; then
  if [[ "${MOCK_TOKEN_STATUS:-201}" == 201 ]]; then printf '{"token":"ghs_test_token"}' >"$output"; else printf '{"message":"Bad credentials","secret":"must-not-leak"}' >"$output"; fi
  printf '%s' "${MOCK_TOKEN_STATUS:-201}"
elif [[ "$url" == */installation ]]; then
  if [[ "${MOCK_DISCOVERY_STATUS:-200}" == 200 ]]; then printf '{"id":42}' >"$output"; else printf '{"message":"Not Found","private":"must-not-leak"}' >"$output"; fi
  printf '%s' "${MOCK_DISCOVERY_STATUS:-200}"
else
  exit 3
fi
MOCK
  chmod +x "$TEST_TMPDIR/bin/buildkite-agent" "$TEST_TMPDIR/bin/curl"
}

create_token() {
  source "$BATS_TEST_DIRNAME/../lib/plugin.bash"
  github_app_token_create
}

@test "discovers installation and narrows default token to current repository" {
  create_token
  [[ "$GITHUB_TOKEN" == ghs_test_token ]]
  grep -F 'GET https://api.github.com/repos/acme/widgets/installation' "$MOCK_LOG"
  payload="$(awk '/access_tokens/{sub(/^.*access_tokens /, ""); print}' "$MOCK_LOG")"
  [[ "$(jq -r '.repositories[0]' <<<"$payload")" == widgets ]]
  [[ "$(jq 'has("permissions")' <<<"$payload")" == false ]]
}

@test "uses an explicit installation ID without discovery" {
  export BUILDKITE_PLUGIN_CREATE_GITHUB_APP_TOKEN_INSTALLATION_ID=99
  create_token
  grep -F 'POST https://api.github.com/app/installations/99/access_tokens' "$MOCK_LOG"
  ! grep -F '/installation ' "$MOCK_LOG"
}

@test "sends repository and permission narrowing payload" {
  export BUILDKITE_PLUGIN_CREATE_GITHUB_APP_TOKEN_OWNER=acme
  export BUILDKITE_PLUGIN_CREATE_GITHUB_APP_TOKEN_REPOSITORIES_0=api
  export BUILDKITE_PLUGIN_CREATE_GITHUB_APP_TOKEN_REPOSITORIES_1=web
  export BUILDKITE_PLUGIN_CREATE_GITHUB_APP_TOKEN_PERMISSIONS_CONTENTS=read
  export BUILDKITE_PLUGIN_CREATE_GITHUB_APP_TOKEN_PERMISSIONS_PULL_REQUESTS=write
  export BUILDKITE_PLUGIN_CREATE_GITHUB_APP_TOKEN_PERMISSIONS_REPOSITORY_PROJECTS=admin
  create_token
  payload="$(awk '/access_tokens/{sub(/^.*access_tokens /, ""); print}' "$MOCK_LOG")"
  jq -e '.repositories == ["api","web"] and .permissions == {contents:"read",pull_requests:"write",repository_projects:"admin"}' <<<"$payload"
}

@test "derives owner from a qualified repository without BUILDKITE_REPO" {
  unset BUILDKITE_REPO
  export BUILDKITE_PLUGIN_CREATE_GITHUB_APP_TOKEN_REPOSITORIES='acme/api'
  create_token
  grep -F 'GET https://api.github.com/repos/acme/api/installation' "$MOCK_LOG"
}

@test "accepts modern opaque GitHub App client IDs" {
  export BUILDKITE_PLUGIN_CREATE_GITHUB_APP_TOKEN_CLIENT_ID=Iv23f8doAlphaNumer1c
  create_token
  [[ "$GITHUB_TOKEN" == ghs_test_token ]]
}

@test "exports a custom output variable and registers redaction first" {
  export BUILDKITE_PLUGIN_CREATE_GITHUB_APP_TOKEN_OUTPUT_VARIABLE=ACME_GITHUB_TOKEN
  create_token
  [[ "$ACME_GITHUB_TOKEN" == ghs_test_token ]]
  [[ "$BUILDKITE_PLUGIN_CREATE_GITHUB_APP_TOKEN_OUTPUT_VARIABLE_NAME" == ACME_GITHUB_TOKEN ]]
  grep -Fx 'redactor:ghs_test_token' "$MOCK_LOG"
  [[ "$(tail -1 "$MOCK_LOG")" == redactor:* ]]
}

@test "removes the referenced private key variable before the command" {
  create_token
  [[ -z "${TEST_PRIVATE_KEY+x}" ]]
}

@test "retrieves a private key from Buildkite Secrets" {
  unset BUILDKITE_PLUGIN_CREATE_GITHUB_APP_TOKEN_PRIVATE_KEY_ENV
  export BUILDKITE_PLUGIN_CREATE_GITHUB_APP_TOKEN_PRIVATE_KEY_SECRET=GITHUB_APP_PRIVATE_KEY
  create_token
  [[ "$GITHUB_TOKEN" == ghs_test_token ]]
}

@test "accepts escaped PEM newlines" {
  export TEST_PRIVATE_KEY="${TEST_PRIVATE_KEY//$'\n'/\\n}"
  create_token
  [[ "$GITHUB_TOKEN" == ghs_test_token ]]
}

@test "uses custom GHES API URL and parses its HTTPS repository remote" {
  export BUILDKITE_REPO=https://github.example.com/acme/enterprise.git
  export BUILDKITE_PLUGIN_CREATE_GITHUB_APP_TOKEN_GITHUB_API_URL=https://github.example.com/api/v3/
  create_token
  grep -F 'GET https://github.example.com/api/v3/repos/acme/enterprise/installation' "$MOCK_LOG"
}

@test "revokes token and deletes private state" {
  create_token
  state="$BUILDKITE_PLUGIN_CREATE_GITHUB_APP_TOKEN_STATE_DIR"
  [[ -f "$state/token" ]]
  [[ "$(stat -c '%a' "$state/token")" == 600 ]]
  github_app_token_cleanup
  grep -F 'DELETE https://api.github.com/installation/token' "$MOCK_LOG"
  [[ ! -e "$state" ]]
  [[ -z "${GITHUB_TOKEN:-}" ]]
  [[ -z "${BUILDKITE_PLUGIN_CREATE_GITHUB_APP_TOKEN_OUTPUT_VARIABLE_NAME:-}" ]]
}

@test "skip-revoke creates no token state" {
  export BUILDKITE_PLUGIN_CREATE_GITHUB_APP_TOKEN_SKIP_REVOKE=true
  create_token
  [[ -z "${BUILDKITE_PLUGIN_CREATE_GITHUB_APP_TOKEN_STATE_DIR:-}" ]]
  github_app_token_cleanup
  [[ -z "${GITHUB_TOKEN:-}" ]]
  ! grep -F 'DELETE ' "$MOCK_LOG"
}

@test "revocation failure is non-fatal and still removes state" {
  export MOCK_REVOKE_STATUS=500
  create_token
  state="$BUILDKITE_PLUGIN_CREATE_GITHUB_APP_TOKEN_STATE_DIR"
  run github_app_token_cleanup
  [[ "$status" -eq 0 ]]
  [[ "$output" == *'warning: token revocation failed (HTTP 500)'* ]]
  [[ ! -e "$state" ]]
}

@test "unreadable state does not make cleanup fatal" {
  create_token
  state="$BUILDKITE_PLUGIN_CREATE_GITHUB_APP_TOKEN_STATE_DIR"
  export MOCK_UNREADABLE_STATE="$state/token"
  cat >"$TEST_TMPDIR/bin/cat" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == "$MOCK_UNREADABLE_STATE" ]]; then
  exit 1
fi
exec "$TEST_REAL_CAT" "$@"
MOCK
  chmod +x "$TEST_TMPDIR/bin/cat"
  hash -r
  run github_app_token_cleanup
  [[ "$status" -eq 0 ]]
  [[ "$output" == *'failed to read token state; revocation was not attempted'* ]]
  [[ ! -e "$state" ]]
}

@test "reports sanitized installation discovery failures" {
  export MOCK_DISCOVERY_STATUS=404
  run create_token
  [[ "$status" -ne 0 ]]
  [[ "$output" == *'HTTP 404: Not Found'* ]]
  [[ "$output" != *'must-not-leak'* ]]
}

@test "does not retry user discovery after an organization API failure" {
  export BUILDKITE_PLUGIN_CREATE_GITHUB_APP_TOKEN_OWNER=acme
  export MOCK_DISCOVERY_STATUS=500
  run create_token
  [[ "$status" -ne 0 ]]
  [[ "$output" == *'HTTP 500: Not Found'* ]]
  [[ "$(grep -c '/installation' "$MOCK_LOG")" -eq 1 ]]
  grep -F '/orgs/acme/installation' "$MOCK_LOG"
}

@test "fails closed when plugin configuration sorting fails" {
  cat >"$TEST_TMPDIR/bin/sort" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
  chmod +x "$TEST_TMPDIR/bin/sort"
  export BUILDKITE_PLUGIN_CREATE_GITHUB_APP_TOKEN_REPOSITORIES_0=api
  run create_token
  [[ "$status" -ne 0 ]]
  [[ "$output" == *'failed to sort plugin configuration variables'* ]]
  [[ ! -e "$MOCK_LOG" ]]
}

@test "fails when JWT claims cannot be generated" {
  cat >"$TEST_TMPDIR/bin/jq" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
  chmod +x "$TEST_TMPDIR/bin/jq"
  source "$BATS_TEST_DIRNAME/../lib/plugin.bash"
  run plugin_create_jwt Iv1.0123456789abcdef "$TEST_PRIVATE_KEY"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *'failed to encode JWT claims'* ]]
  [[ -z "$(find "$TMPDIR" -type f -print -quit)" ]]
}

@test "revokes a minted token when private state cannot be written" {
  cat >"$TEST_TMPDIR/bin/mktemp" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == -d ]]; then
  printf '%s\n' /proc/github-app-token-state.unwritable
else
  exec "$TEST_REAL_MKTEMP" "$@"
fi
MOCK
  chmod +x "$TEST_TMPDIR/bin/mktemp"
  run create_token
  [[ "$status" -ne 0 ]]
  [[ "$output" == *'could not write private token state'* ]]
  grep -F 'DELETE https://api.github.com/installation/token' "$MOCK_LOG"
  [[ -z "${GITHUB_TOKEN:-}" ]]
  [[ -z "$(find "$TMPDIR" -type f -print -quit)" ]]
}

@test "reports sanitized token API failures" {
  export MOCK_TOKEN_STATUS=401
  run create_token
  [[ "$status" -ne 0 ]]
  [[ "$output" == *'HTTP 401: Bad credentials'* ]]
  [[ "$output" != *'must-not-leak'* ]]
}

@test "reports network failures without leaking authorization material" {
  export MOCK_CURL_FAIL=true
  run create_token
  [[ "$status" -ne 0 ]]
  [[ "$output" == *'GitHub API request failed'* ]]
  [[ "$output" != *'Bearer'* ]]
}

@test "fails closed when dynamic redaction is unavailable" {
  cat >"$TEST_TMPDIR/bin/buildkite-agent" <<'MOCK'
#!/usr/bin/env bash
[[ "$1 $2" == "redactor add" ]] && exit 1
exit 2
MOCK
  chmod +x "$TEST_TMPDIR/bin/buildkite-agent"
  run create_token
  [[ "$status" -ne 0 ]]
  [[ "$output" == *'could not register the installation token'* ]]
  [[ -z "${GITHUB_TOKEN:-}" ]]
  [[ -z "$(find "$TMPDIR" -type f -print -quit)" ]]
  grep -F 'DELETE https://api.github.com/installation/token' "$MOCK_LOG"
}

@test "rejects malformed private keys and removes temporary key files" {
  export TEST_PRIVATE_KEY='not a key'
  run create_token
  [[ "$status" -ne 0 ]]
  [[ "$output" == *'not a valid PEM-encoded private key'* ]]
  [[ -z "$(find "$TMPDIR" -type f -print -quit)" ]]
}

@test "rejects malformed output variables" {
  export BUILDKITE_PLUGIN_CREATE_GITHUB_APP_TOKEN_OUTPUT_VARIABLE='BAD-NAME'
  run create_token
  [[ "$status" -ne 0 ]]
  [[ "$output" == *'output-variable must be a valid'* ]]
}

@test "rejects repository owner mismatches" {
  export BUILDKITE_PLUGIN_CREATE_GITHUB_APP_TOKEN_OWNER=acme
  export BUILDKITE_PLUGIN_CREATE_GITHUB_APP_TOKEN_REPOSITORIES='other/repo'
  run create_token
  [[ "$status" -ne 0 ]]
  [[ "$output" == *'does not belong to owner acme'* ]]
}

@test "JWT has skew-safe claims and a valid RSA signature" {
  source "$BATS_TEST_DIRNAME/../lib/plugin.bash"
  before="$(date +%s)"
  jwt="$(plugin_create_jwt Iv1.0123456789abcdef "$TEST_PRIVATE_KEY")"
  after="$(date +%s)"
  claims="$(cut -d. -f2 <<<"$jwt" | tr '_-' '/+')"
  padding=$(( (4 - ${#claims} % 4) % 4 ))
  claims="${claims}$(printf '%*s' "$padding" '' | tr ' ' '=')"
  claims="$(printf '%s' "$claims" | base64 -d 2>/dev/null)"
  [[ "$(jq -r .iss <<<"$claims")" == Iv1.0123456789abcdef ]]
  iat="$(jq -r .iat <<<"$claims")"
  exp="$(jq -r .exp <<<"$claims")"
  ((iat <= before - 60 && iat >= before - 61))
  ((exp >= after + 539 && exp <= after + 540))

  signing_input="${jwt%.*}"
  signature="${jwt##*.}"
  padding=$(( (4 - ${#signature} % 4) % 4 ))
  signature="${signature//_/\/}"
  signature="${signature//-/+}"
  printf '%s' "$signature" >"$TEST_TMPDIR/signature.b64"
  printf '%*s' "$padding" '' | tr ' ' '=' >>"$TEST_TMPDIR/signature.b64"
  base64 -d "$TEST_TMPDIR/signature.b64" >"$TEST_TMPDIR/signature.bin"
  openssl pkey -in "$TEST_TMPDIR/key.pem" -pubout -out "$TEST_TMPDIR/public.pem" 2>/dev/null
  printf '%s' "$signing_input" | openssl dgst -sha256 -verify "$TEST_TMPDIR/public.pem" -signature "$TEST_TMPDIR/signature.bin"
}
