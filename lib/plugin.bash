#!/usr/bin/env bash

PLUGIN_PREFIX="BUILDKITE_PLUGIN_CREATE_GITHUB_APP_TOKEN_"

plugin_fail() {
  printf 'create-github-app-token: %s\n' "$*" >&2
  return 1
}

plugin_config() {
  local name="$1" default="${2-}" variable
  variable="${PLUGIN_PREFIX}${name//-/_}"
  variable="$(printf '%s' "$variable" | tr '[:lower:]' '[:upper:]')"
  printf '%s' "${!variable:-$default}"
}

plugin_indirect_value() {
  local reference="$1" description="$2"
  [[ "$reference" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
    plugin_fail "${description} must be a valid environment variable name"
    return 1
  }
  [[ -n "${!reference:-}" ]] || {
    plugin_fail "environment variable ${reference} is empty or unset"
    return 1
  }
  printf '%s' "${!reference}"
}

plugin_base64url() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

plugin_json_error() {
  local file="$1" fallback="$2" message
  message="$(jq -r 'if type == "object" and (.message | type) == "string" then .message | gsub("[[:cntrl:]]"; " ") | .[:500] else empty end' "$file" 2>/dev/null || true)"
  printf '%s' "${message:-$fallback}"
}

plugin_api_request() {
  local method="$1" path="$2" auth="$3" body_file="$4" expected="$5" payload="${6-}"
  local status
  local -a args=(--silent --show-error --connect-timeout 10 --max-time 60
    --request "$method" --output "$body_file" --write-out '%{http_code}'
    --header 'Accept: application/vnd.github+json'
    --header 'X-GitHub-Api-Version: 2022-11-28'
    --header 'User-Agent: create-github-app-token-buildkite-plugin'
    --header "Authorization: Bearer ${auth}")
  if [[ -n "$payload" ]]; then
    args+=(--header 'Content-Type: application/json' --data "$payload")
  fi

  status="$(curl "${args[@]}" "${GITHUB_APP_API_URL}${path}")" || {
    GITHUB_APP_HTTP_STATUS=unknown
    GITHUB_APP_HTTP_MESSAGE='GitHub API request failed'
    plugin_fail "GitHub API request failed for ${method} ${path}"
    return 1
  }
  if [[ "$status" != "$expected" ]]; then
    GITHUB_APP_HTTP_STATUS="$status"
    GITHUB_APP_HTTP_MESSAGE="$(plugin_json_error "$body_file" 'GitHub API request failed')"
    return 1
  fi
}

plugin_create_jwt() (
  local issuer="$1" key="$2" now header claims signing_input key_file signature
  now="$(date +%s)"
  header="$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | plugin_base64url)"
  claims="$(jq -cn --arg iss "$issuer" --argjson iat "$((now - 60))" --argjson exp "$((now + 540))" '{iat:$iat,exp:$exp,iss:$iss}' | plugin_base64url)"
  signing_input="${header}.${claims}"

  key_file="$(mktemp "${TMPDIR:-/tmp}/github-app-key.XXXXXX")"
  chmod 600 "$key_file"
  trap 'rm -f "$key_file"' EXIT
  trap 'exit 1' HUP INT TERM
  key="${key//\\n/$'\n'}"
  printf '%s\n' "$key" >"$key_file"
  openssl pkey -in "$key_file" -noout >/dev/null 2>&1 || {
    plugin_fail 'private key is not a valid PEM-encoded private key'
    return 1
  }
  signature="$(printf '%s' "$signing_input" | openssl dgst -sha256 -sign "$key_file" | plugin_base64url)" || {
    plugin_fail 'failed to sign GitHub App JWT'
    return 1
  }
  printf '%s.%s' "$signing_input" "$signature"
)

plugin_current_repository() {
  local remote="${BUILDKITE_REPO:-}" path
  [[ -n "$remote" ]] || plugin_fail 'owner/repositories are not configured and BUILDKITE_REPO is empty'
  case "$remote" in
    git@*:*) path="${remote#*:}" ;;
    ssh://git@*/*) path="${remote#ssh://git@*/}" ;;
    http://*/*|https://*/*) path="${remote#*://*/}" ;;
    *) plugin_fail 'could not determine owner/repository from BUILDKITE_REPO' ; return 1 ;;
  esac
  path="${path%.git}"
  [[ "$path" =~ ^[^/]+/[^/]+$ ]] || {
    plugin_fail 'BUILDKITE_REPO must identify an owner/repository Git remote'
    return 1
  }
  printf '%s' "$path"
}

plugin_collect_repositories() {
  local scalar variable value
  GITHUB_APP_CONFIGURED_REPOSITORIES=()
  scalar="$(plugin_config repositories)"
  if [[ -n "$scalar" ]]; then
    while IFS= read -r value; do
      [[ -n "$value" ]] && GITHUB_APP_CONFIGURED_REPOSITORIES+=("$value")
    done < <(printf '%s\n' "$scalar" | tr ',' '\n')
  fi
  while IFS= read -r variable; do
    GITHUB_APP_CONFIGURED_REPOSITORIES+=("${!variable}")
  done < <(compgen -A variable "${PLUGIN_PREFIX}REPOSITORIES_" | sort -t_ -k8,8n)
  ((${#GITHUB_APP_CONFIGURED_REPOSITORIES[@]} <= 500)) || plugin_fail 'repositories cannot contain more than 500 entries'
}

plugin_target() {
  local configured_owner="$1" current="" entry entry_owner entry_repo
  local -a requested=()
  plugin_collect_repositories || return
  requested=("${GITHUB_APP_CONFIGURED_REPOSITORIES[@]}")

  if ((${#requested[@]} == 0)) && [[ -z "$configured_owner" ]]; then
    current="$(plugin_current_repository)" || return
    configured_owner="${current%%/*}"
    requested=("${current#*/}")
  fi
  if ((${#requested[@]} > 0)) && [[ -z "$configured_owner" ]]; then
    current="$(plugin_current_repository)" || return
    configured_owner="${current%%/*}"
  fi

  GITHUB_APP_OWNER="$configured_owner"
  [[ "$GITHUB_APP_OWNER" =~ ^[A-Za-z0-9-]+$ ]] || {
    plugin_fail 'owner must contain only letters, numbers, and hyphens'
    return 1
  }
  GITHUB_APP_REPOSITORIES=()
  for entry in "${requested[@]}"; do
    entry="${entry%.git}"
    if [[ "$entry" == */* ]]; then
      entry_owner="${entry%%/*}"
      entry_repo="${entry#*/}"
      [[ "$entry_owner" == "$configured_owner" ]] || {
        plugin_fail "repository ${entry} does not belong to owner ${configured_owner}"
        return 1
      }
    else
      entry_repo="$entry"
    fi
    [[ "$entry_repo" =~ ^[A-Za-z0-9._-]+$ ]] || {
      plugin_fail "invalid repository name: ${entry_repo}"
      return 1
    }
    GITHUB_APP_REPOSITORIES+=("$entry_repo")
  done
}

plugin_permissions_json() {
  local variable key value result='{}'
  while IFS= read -r variable; do
    key="${variable#"${PLUGIN_PREFIX}"PERMISSIONS_}"
    key="$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')"
    value="${!variable}"
    [[ "$key" =~ ^[a-z][a-z0-9_]*$ ]] || {
      plugin_fail "invalid permission name: ${key}"
      return 1
    }
    [[ "$value" == read || "$value" == write ]] || {
      plugin_fail "permission ${key} must be read or write"
      return 1
    }
    result="$(jq -cn --argjson current "$result" --arg key "$key" --arg value "$value" '$current + {($key):$value}')"
  done < <(compgen -A variable "${PLUGIN_PREFIX}PERMISSIONS_" | sort)
  printf '%s' "$result"
}

plugin_discover_installation() {
  local jwt="$1" response="$2" path
  if ((${#GITHUB_APP_REPOSITORIES[@]} > 0)); then
    path="/repos/${GITHUB_APP_OWNER}/${GITHUB_APP_REPOSITORIES[0]}/installation"
    plugin_api_request GET "$path" "$jwt" "$response" 200 || {
      plugin_fail "could not find a GitHub App installation for ${GITHUB_APP_OWNER}/${GITHUB_APP_REPOSITORIES[0]} (HTTP ${GITHUB_APP_HTTP_STATUS}: ${GITHUB_APP_HTTP_MESSAGE})"
      return 1
    }
  else
    path="/orgs/${GITHUB_APP_OWNER}/installation"
    if ! plugin_api_request GET "$path" "$jwt" "$response" 200; then
      path="/users/${GITHUB_APP_OWNER}/installation"
      plugin_api_request GET "$path" "$jwt" "$response" 200 || {
        plugin_fail "could not find a GitHub App installation for owner ${GITHUB_APP_OWNER} (HTTP ${GITHUB_APP_HTTP_STATUS}: ${GITHUB_APP_HTTP_MESSAGE})"
        return 1
      }
    fi
  fi
  jq -er '.id | select(type == "number" or type == "string")' "$response" 2>/dev/null || plugin_fail 'GitHub installation response did not contain an installation ID'
}

github_app_token_create() {
  local client_id client_id_env app_id_env private_key private_key_env private_key_secret
  local installation_id installation_id_env output_variable skip_revoke jwt permissions payload token
  local response state_dir
  umask 077

  client_id="$(plugin_config client-id)"
  client_id_env="$(plugin_config client-id-env)"
  app_id_env="$(plugin_config app-id-env)"
  if [[ -n "$client_id_env" ]]; then
    client_id="$(plugin_indirect_value "$client_id_env" client-id-env)" || return
  fi
  if [[ -z "$client_id" && -n "$app_id_env" ]]; then
    client_id="$(plugin_indirect_value "$app_id_env" app-id-env)" || return
  fi
  [[ -n "$client_id" ]] || client_id="$(plugin_config app-id)"
  [[ "$client_id" =~ ^(Iv1\.[A-Fa-f0-9]+|[0-9]+)$ ]] || {
    plugin_fail 'client-id/app-id is missing or malformed'
    return 1
  }

  private_key_env="$(plugin_config private-key-env)"
  private_key_secret="$(plugin_config private-key-secret)"
  if [[ -n "$private_key_secret" && -n "$private_key_env" ]]; then
    plugin_fail 'configure exactly one of private-key-secret or private-key-env'
    return 1
  elif [[ -n "$private_key_secret" ]]; then
    private_key="$(buildkite-agent secret get "$private_key_secret")" || {
      plugin_fail "could not retrieve Buildkite Secret ${private_key_secret}"
      return 1
    }
  elif [[ -n "$private_key_env" ]]; then
    private_key="$(plugin_indirect_value "$private_key_env" private-key-env)" || return
  else
    plugin_fail 'private-key-secret or private-key-env is required'
    return 1
  fi

  GITHUB_APP_API_URL="$(plugin_config github-api-url 'https://api.github.com')"
  GITHUB_APP_API_URL="${GITHUB_APP_API_URL%/}"
  [[ "$GITHUB_APP_API_URL" =~ ^https://[^[:space:]?#]+$ ]] || {
    plugin_fail 'github-api-url must be a valid HTTPS API root without a query or fragment'
    return 1
  }
  output_variable="$(plugin_config output-variable GITHUB_TOKEN)"
  [[ "$output_variable" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
    plugin_fail 'output-variable must be a valid environment variable name'
    return 1
  }
  skip_revoke="$(plugin_config skip-revoke false)"
  [[ "$skip_revoke" == true || "$skip_revoke" == false ]] || {
    plugin_fail 'skip-revoke must be true or false'
    return 1
  }

  plugin_target "$(plugin_config owner)" || return
  jwt="$(plugin_create_jwt "$client_id" "$private_key")" || return
  unset private_key
  response="$(mktemp "${TMPDIR:-/tmp}/github-app-response.XXXXXX")"

  installation_id="$(plugin_config installation-id)"
  installation_id_env="$(plugin_config installation-id-env)"
  if [[ -n "$installation_id_env" ]]; then
    installation_id="$(plugin_indirect_value "$installation_id_env" installation-id-env)" || {
      rm -f "$response"
      return 1
    }
  fi
  if [[ -z "$installation_id" ]]; then
    installation_id="$(plugin_discover_installation "$jwt" "$response")" || {
      rm -f "$response"
      return 1
    }
  fi
  [[ "$installation_id" =~ ^[0-9]+$ ]] || {
    rm -f "$response"
    plugin_fail 'installation-id is malformed'
    return 1
  }

  permissions="$(plugin_permissions_json)" || {
    rm -f "$response"
    return 1
  }
  payload='{}'
  if [[ "$permissions" != '{}' ]]; then
    payload="$(jq -cn --argjson permissions "$permissions" '{permissions:$permissions}')"
  fi
  if ((${#GITHUB_APP_REPOSITORIES[@]} > 0)); then
    payload="$(jq -cn --argjson current "$payload" --args '$current + {repositories:$ARGS.positional}' -- "${GITHUB_APP_REPOSITORIES[@]}")"
  fi
  plugin_api_request POST "/app/installations/${installation_id}/access_tokens" "$jwt" "$response" 201 "$payload" || {
    local api_status="$GITHUB_APP_HTTP_STATUS" api_message="$GITHUB_APP_HTTP_MESSAGE"
    rm -f "$response"
    plugin_fail "could not create installation token (HTTP ${api_status}: ${api_message})"
    return 1
  }
  token="$(jq -er '.token | select(type == "string" and length > 0)' "$response" 2>/dev/null)" || {
    rm -f "$response"
    plugin_fail 'GitHub token response did not contain a token'
    return 1
  }

  buildkite-agent redactor add "$token" >/dev/null || {
    plugin_api_request DELETE '/installation/token' "$token" "$response" 204 || true
    rm -f "$response"
    unset token
    plugin_fail 'could not register the installation token with the Buildkite redactor (agent v3.67.0 or newer is required)'
    return 1
  }

  if [[ "$skip_revoke" == false ]]; then
    state_dir="$(mktemp -d "${TMPDIR:-/tmp}/github-app-token-state.XXXXXX")" || {
      plugin_api_request DELETE '/installation/token' "$token" "$response" 204 || true
      rm -f "$response"
      unset token
      plugin_fail 'could not create private token state directory'
      return 1
    }
    printf '%s' "$token" >"${state_dir}/token"
    printf '%s' "$GITHUB_APP_API_URL" >"${state_dir}/api-url"
    export BUILDKITE_PLUGIN_CREATE_GITHUB_APP_TOKEN_STATE_DIR="$state_dir"
  fi
  printf -v "$output_variable" '%s' "$token"
  export "${output_variable?}"
  export BUILDKITE_PLUGIN_CREATE_GITHUB_APP_TOKEN_OUTPUT_VARIABLE_NAME="$output_variable"
  unset token jwt
  rm -f "$response"
  printf '%s\n' 'GitHub App installation token created and registered for redaction'
}

github_app_token_cleanup() {
  local state_dir="${BUILDKITE_PLUGIN_CREATE_GITHUB_APP_TOKEN_STATE_DIR:-}" token response status
  local output_variable="${BUILDKITE_PLUGIN_CREATE_GITHUB_APP_TOKEN_OUTPUT_VARIABLE_NAME:-}"
  if [[ -z "$state_dir" ]]; then
    [[ -n "$output_variable" ]] && unset "$output_variable"
    unset BUILDKITE_PLUGIN_CREATE_GITHUB_APP_TOKEN_OUTPUT_VARIABLE_NAME
    return 0
  fi
  case "$state_dir" in
    "${TMPDIR:-/tmp}"/github-app-token-state.*) ;;
    *)
      printf '%s\n' 'create-github-app-token: token state path is invalid; revocation was not attempted' >&2
      unset BUILDKITE_PLUGIN_CREATE_GITHUB_APP_TOKEN_STATE_DIR
      [[ -n "$output_variable" ]] && unset "$output_variable"
      unset BUILDKITE_PLUGIN_CREATE_GITHUB_APP_TOKEN_OUTPUT_VARIABLE_NAME
      return 0
      ;;
  esac
  if [[ ! -d "$state_dir" || ! -f "$state_dir/token" || ! -f "$state_dir/api-url" ]]; then
    printf '%s\n' 'create-github-app-token: token state is missing; revocation was not attempted' >&2
    rm -rf "$state_dir"
    unset BUILDKITE_PLUGIN_CREATE_GITHUB_APP_TOKEN_STATE_DIR
    [[ -n "$output_variable" ]] && unset "$output_variable"
    unset BUILDKITE_PLUGIN_CREATE_GITHUB_APP_TOKEN_OUTPUT_VARIABLE_NAME
    return 0
  fi
  token="$(cat "${state_dir}/token")"
  GITHUB_APP_API_URL="$(cat "${state_dir}/api-url")"
  response="${state_dir}/response"
  if ! plugin_api_request DELETE '/installation/token' "$token" "$response" 204; then
    status="${GITHUB_APP_HTTP_STATUS:-unknown}"
    printf 'create-github-app-token: warning: token revocation failed (HTTP %s)\n' "$status" >&2
  else
    printf '%s\n' 'GitHub App installation token revoked'
  fi
  unset token
  rm -rf "$state_dir"
  unset BUILDKITE_PLUGIN_CREATE_GITHUB_APP_TOKEN_STATE_DIR
  [[ -n "$output_variable" ]] && unset "$output_variable"
  unset BUILDKITE_PLUGIN_CREATE_GITHUB_APP_TOKEN_OUTPUT_VARIABLE_NAME
}
