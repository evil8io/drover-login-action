#!/usr/bin/env bash
# Logs in to OpenBao with the GitHub OIDC token. Requests a token of a project ServiceAccount.
# Writes a kubeconfig for the Rancher proxy of the cluster. The inputs of the action are in the
# DROVER_* variables.
{ set +x; } 2>/dev/null
set -euo pipefail
export LC_ALL=C

fail() {
  echo "::error::$*"
  exit 1
}

# check <input> <value> <regex> <expected>
check() {
  local input="$1" value="$2" pattern="$3" expected="$4"
  if [[ ! "$value" =~ $pattern ]]; then
    fail "The input $input is not valid. The value must be $expected."
  fi
}

# check_token <name> <value>
# Fails when the value is not one line of the characters of the token alphabet: A-Z, a-z, 0-9,
# '.', '_', and '-'. A JWT and an OpenBao token contain only these characters.
check_token() {
  local name="$1" value="$2"
  if [[ ! "$value" =~ ^[A-Za-z0-9._-]+$ ]]; then
    fail "The $name is not one line of the characters A-Z, a-z, 0-9, '.', '_', and '-'."
  fi
}

mask() {
  echo "::add-mask::$1"
}

url_pattern='^(https://[A-Za-z0-9.-]+|http://(127\.0\.0\.1|localhost))(:[0-9]+)?$'
name_pattern='^[a-z0-9]([-a-z0-9]*[a-z0-9])?$'

openbao_url="${DROVER_OPENBAO_URL:-}"
openbao_url="${openbao_url%/}"
rancher_url="${DROVER_RANCHER_URL:-}"
rancher_url="${rancher_url%/}"
cluster="${DROVER_CLUSTER:-}"
project="${DROVER_PROJECT:-}"
role="${DROVER_ROLE:-}"
statement="${DROVER_STATEMENT:-}"
issuer="${DROVER_ISSUER:-github}"
audience="${DROVER_AUDIENCE:-$openbao_url}"
ttl="${DROVER_TTL:-}"
namespace="${DROVER_NAMESPACE:-}"
kubeconfig="${DROVER_KUBECONFIG:-}"
export_kubeconfig="${DROVER_EXPORT_KUBECONFIG:-true}"
ca_certificate="${DROVER_CA_CERTIFICATE:-}"
ca_certificate="${ca_certificate//$'\r'/}"
ca_certificate="${ca_certificate#"${ca_certificate%%[![:space:]]*}"}"
ca_certificate="${ca_certificate%"${ca_certificate##*[![:space:]]}"}"
insecure_skip_tls_verify="${DROVER_INSECURE_SKIP_TLS_VERIFY:-false}"

check openbao-url "$openbao_url" "$url_pattern" 'an https URL with a host and without a path'
check rancher-url "$rancher_url" "$url_pattern" 'an https URL with a host and without a path'
check cluster "$cluster" "$name_pattern" 'a Rancher cluster id, for example c-m-4x2kq7bd'
check project "$project" "$name_pattern" 'a Rancher project id, for example p-abc12'
check role "$role" '^(project-owner|project-member|read-only)$' 'project-owner, project-member, or read-only'
check statement "$statement" '^[a-z0-9]([-a-z0-9]{0,30}[a-z0-9])?$' 'the name of a statement in the trust annotation of the project, at most 32 characters'
check issuer "$issuer" "$name_pattern" 'the name of a JWT issuer of OpenBao, for example github'
check audience "$audience" '^[^[:space:]]+$' 'text without white space'
check ttl "$ttl" '^([0-9]+[smh]?)?$' 'a duration, for example 30m, or empty'
check namespace "$namespace" '^([a-z0-9]([-a-z0-9]*[a-z0-9])?)?$' 'a namespace name, or empty'
check kubeconfig "$kubeconfig" '^(/[^[:cntrl:]]*)?$' 'an absolute path, or empty'
check export-kubeconfig "$export_kubeconfig" '^(true|false)$' 'true or false'
pem_block="-----BEGIN CERTIFICATE-----"$'\n'"([A-Za-z0-9+/=]+"$'\n'")+-----END CERTIFICATE-----"
check ca-certificate "$ca_certificate" "^(${pem_block}("$'\n'"+${pem_block})*)?$" 'one or more PEM certificates, or empty'
check insecure-skip-tls-verify "$insecure_skip_tls_verify" '^(true|false)$' 'true or false'
[[ -d "$kubeconfig" ]] && fail "The input kubeconfig is a directory."
if [[ -n "$ca_certificate" && "$insecure_skip_tls_verify" == true ]]; then
  fail "Set the input ca-certificate or the input insecure-skip-tls-verify. Do not set both, because kubectl does not accept a kubeconfig with both."
fi

if [[ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" || -z "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]]; then
  fail "The job cannot request an OIDC token. Give the job the permission id-token: write."
fi

for tool in curl jq; do
  command -v "$tool" >/dev/null || fail "The runner does not have $tool."
done

login_role="${cluster}_${project}_${statement}"
account_namespace="drover-${cluster}-${project}"
server="${rancher_url}/k8s/clusters/${cluster}"

umask 077
work=$(mktemp -d "${RUNNER_TEMP:-/tmp}/drover-login.XXXXXX")
trap 'rm -rf "$work"' EXIT

# request <name>
# Sends the request of the curl config $work/<name>.curl. Writes the body to $work/<name>.json
# and prints the HTTP status. The tokens are in the config file or in a body file, not on the
# command line. With -q as the first argument, curl does not read a curlrc of the runner.
request() {
  curl -q --silent --show-error --max-time 60 \
    --config "$work/$1.curl" --output "$work/$1.json" --write-out '%{http_code}'
}

# json <name>
# Fails when the response of the request <name> is not a JSON object.
json() {
  jq -e 'type == "object"' "$work/$1.json" >/dev/null 2>&1 \
    || fail "The response of the request $1 is not a JSON object."
}

# errors <name>
# Prints the errors of the response of the request <name> on one line.
errors() {
  jq -r '(.errors // [.message // .error // empty]) | map(tostring) | join("; ") | gsub("\\s+"; " ") | sub("\\s+$"; "")' \
    "$work/$1.json" 2>/dev/null || true
}

openbao_tls=""
if [[ -n "$ca_certificate" ]]; then
  printf '%s\n' "$ca_certificate" > "$work/ca.pem"
  openbao_tls="cacert = \"${work}/ca.pem\""
elif [[ "$insecure_skip_tls_verify" == true ]]; then
  openbao_tls="insecure"
fi

separator='&'
[[ "$ACTIONS_ID_TOKEN_REQUEST_URL" == *\?* ]] || separator='?'
encoded_audience=$(jq -rn --arg audience "$audience" '$audience | @uri')
cat > "$work/oidc.curl" <<EOF
url = "${ACTIONS_ID_TOKEN_REQUEST_URL}${separator}audience=${encoded_audience}"
header = "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}"
header = "Accept: application/json"
EOF
status=$(request oidc) || fail "The OIDC token request to GitHub failed (curl exit code $?)."
[[ "$status" == 200 ]] || fail "GitHub did not return an OIDC token (HTTP $status): $(errors oidc)"
json oidc
jwt=$(jq -r '.value // empty' "$work/oidc.json")
[[ -n "$jwt" ]] || fail "The OIDC token response does not contain a value."
check_token "OIDC token" "$jwt"
mask "$jwt"

jq --arg role "$login_role" '{role: $role, jwt: .value}' "$work/oidc.json" > "$work/login.body"
cat > "$work/login.curl" <<EOF
url = "${openbao_url}/v1/auth/jwt/${issuer}/login"
request = "POST"
header = "Content-Type: application/json"
data-binary = "@${work}/login.body"
${openbao_tls}
EOF
status=$(request login) || fail "The login request to $openbao_url failed (curl exit code $?)."
[[ "$status" == 200 ]] \
  || fail "OpenBao refused the login with the role $login_role at auth/jwt/$issuer (HTTP $status): $(errors login)"
json login
client_token=$(jq -r '.auth.client_token // empty' "$work/login.json")
[[ -n "$client_token" ]] || fail "The login response does not contain a client token."
check_token "OpenBao token" "$client_token"
mask "$client_token"
echo "OpenBao accepted the login with the role $login_role at $openbao_url."

jq -n --arg namespace "$account_namespace" --arg ttl "$ttl" \
  '{kubernetes_namespace: $namespace} + (if $ttl == "" then {} else {ttl: $ttl} end)' > "$work/creds.body"
cat > "$work/creds.curl" <<EOF
url = "${openbao_url}/v1/kubernetes/${cluster}/creds/${project}-${role}"
request = "POST"
header = "Content-Type: application/json"
header = "X-Vault-Token: ${client_token}"
data-binary = "@${work}/creds.body"
${openbao_tls}
EOF
status=$(request creds) || fail "The token request to $openbao_url failed (curl exit code $?)."
[[ "$status" == 200 ]] \
  || fail "OpenBao did not return a token of $account_namespace/$role (HTTP $status): $(errors creds)"
json creds
token=$(jq -r '.data.service_account_token // empty' "$work/creds.json")
[[ -n "$token" ]] || fail "The token response does not contain a ServiceAccount token."
check_token "ServiceAccount token" "$token"
mask "$token"
expires_in=$(jq -r '.lease_duration // 0' "$work/creds.json")
echo "OpenBao returned a token of $account_namespace/$role for the cluster $cluster. It expires in $expires_in seconds."

if [[ -z "$kubeconfig" ]]; then
  kubeconfig="$(mktemp -d "${RUNNER_TEMP:-/tmp}/drover-kubeconfig.XXXXXX")/kubeconfig"
fi
kubeconfig_dir=$(dirname "$kubeconfig")
mkdir -p "$kubeconfig_dir"
new_kubeconfig=$(mktemp "$kubeconfig_dir/.kubeconfig.XXXXXX")
jq --arg cluster "$cluster" --arg server "$server" --arg user "${project}-${role}" --arg namespace "$namespace" \
  --arg ca "$ca_certificate" --arg insecure "$insecure_skip_tls_verify" '{
  apiVersion: "v1",
  kind: "Config",
  clusters: [{
    name: $cluster,
    cluster: ({server: $server}
      + (if $ca == "" then {} else {"certificate-authority-data": ($ca | @base64)} end)
      + (if $insecure == "true" then {"insecure-skip-tls-verify": true} else {} end))
  }],
  users: [{name: $user, user: {token: .data.service_account_token}}],
  contexts: [{
    name: $cluster,
    context: ({cluster: $cluster, user: $user} + (if $namespace == "" then {} else {namespace: $namespace} end))
  }],
  "current-context": $cluster
}' "$work/creds.json" > "$new_kubeconfig"
mv -f "$new_kubeconfig" "$kubeconfig"
echo "The action wrote the kubeconfig to $kubeconfig. The server is $server."

{
  echo "kubeconfig=$kubeconfig"
  echo "server=$server"
  echo "token=$token"
  echo "expires-in=$expires_in"
} >> "${GITHUB_OUTPUT:?}"
if [[ "$export_kubeconfig" == true ]]; then
  echo "KUBECONFIG=$kubeconfig" >> "${GITHUB_ENV:?}"
fi
