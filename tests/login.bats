#!/usr/bin/env bats
# For shellcheck, a test body is a subshell.
# shellcheck disable=SC2030,SC2031

load helpers

setup_file() {
  make_certificates
  OLDEST_NODE=""
  if command -v mise >/dev/null; then
    OLDEST_NODE=$(mise exec node@24.0.0 -- node -p process.execPath 2>/dev/null) || OLDEST_NODE=""
  fi
  export OLDEST_NODE
}

setup() {
  start_mock
  login_env
}

teardown() {
  stop_mock
}

@test "logs in, requests the token, and writes the kubeconfig" {
  run action
  [ "$status" -eq 0 ]

  # The OIDC request has the OpenBao URL as the default audience.
  [ "$(request 1 | jq -r .path)" = "/oidc" ]
  [ "$(request 1 | jq -r '.query["api-version"]')" = "2.0" ]
  [ "$(request 1 | jq -r .query.audience)" = "$MOCK_URL" ]
  [ "$(request 1 | jq -r .headers.authorization)" = "bearer request-token" ]
  for n in 1 2 3; do
    [ "$(request "$n" | jq -r '.headers["user-agent"]')" = "drover-login-action" ]
  done

  [ "$(request 2 | jq -r .path)" = "/v1/auth/jwt/github/login" ]
  [ "$(request 2 | jq -r .body.role)" = "c-m-4x2kq7bd_p-abc12_deploy-main" ]
  [ "$(request 2 | jq -r .jwt_claims.aud)" = "$MOCK_URL" ]

  [ "$(request 3 | jq -r .path)" = "/v1/kubernetes/c-m-4x2kq7bd/creds/p-abc12-project-member" ]
  [ "$(request 3 | jq -r '.headers["x-vault-token"]')" = "hvb.mock-client-token" ]
  [ "$(request 3 | jq -r .body.kubernetes_namespace)" = "drover-c-m-4x2kq7bd-p-abc12" ]
  [ "$(request 3 | jq -r '.body | has("ttl")')" = "false" ]
  [ "$(request_count)" -eq 3 ]

  kubeconfig=$(output_value kubeconfig)
  [[ "$kubeconfig" == "$BATS_TEST_TMPDIR"/drover-kubeconfig.*/kubeconfig ]]
  [ "$(output_value server)" = "https://rancher.example.com/k8s/clusters/c-m-4x2kq7bd" ]
  [ "$(output_value token)" = "$SA_TOKEN" ]
  [ "$(output_value expires-in)" = "900" ]
  [ "$(cat "$GITHUB_ENV")" = "KUBECONFIG=$kubeconfig" ]
  [ "$(stat -c %a "$kubeconfig")" = "600" ]
  [ "$(jq -r '.clusters[0].cluster.server' "$kubeconfig")" = "https://rancher.example.com/k8s/clusters/c-m-4x2kq7bd" ]
  [ "$(jq -c '.clusters[0].cluster | keys' "$kubeconfig")" = '["server"]' ]
  [ "$(jq -r '.users[0].user.token' "$kubeconfig")" = "$SA_TOKEN" ]
  [ "$(jq -r '.contexts[0].context.user' "$kubeconfig")" = "p-abc12-project-member" ]
  [ "$(jq -r '.contexts[0].context | has("namespace")' "$kubeconfig")" = "false" ]
  [ "$(jq -r '."current-context"' "$kubeconfig")" = "c-m-4x2kq7bd" ]

  # Each token is in the log only in its mask line.
  grep -q "^OpenBao accepted the login with the role c-m-4x2kq7bd_p-abc12_deploy-main at $MOCK_URL.$" <<<"$output"
  grep -q "^OpenBao returned a token of drover-c-m-4x2kq7bd-p-abc12/project-member for the cluster c-m-4x2kq7bd. It expires in 900 seconds.$" <<<"$output"
  grep -q "^The action wrote the kubeconfig to $kubeconfig. The server is https://rancher.example.com/k8s/clusters/c-m-4x2kq7bd.$" <<<"$output"
  grep -q "^::add-mask::$(request 2 | jq -r .body.jwt)$" <<<"$output"
  grep -q "^::add-mask::hvb.mock-client-token$" <<<"$output"
  grep -q "^::add-mask::$SA_TOKEN$" <<<"$output"
  for token in "$(request 2 | jq -r .body.jwt)" hvb.mock-client-token "$SA_TOKEN"; do
    [ "$(grep -F -- "$token" <<<"$output" | grep -vc '^::add-mask::')" -eq 0 ]
  done
}

# An older runner contains an older Node 24. Node stops at the import of a name that it does not
# have, thus the action must not need a newer release than 24.0.0.
@test "logs in on Node 24.0.0, the first release of Node 24" {
  [ -n "$OLDEST_NODE" ] || skip "mise cannot provide Node 24.0.0"
  export ACTION_NODE="$OLDEST_NODE"
  run action
  [ "$status" -eq 0 ]
  [ "$(request_count)" -eq 3 ]
}

@test "passes the audience, the issuer, the ttl, the namespace, and the kubeconfig path" {
  input audience "https://broker.example.com"
  input issuer "github-enterprise"
  input ttl "30m"
  input namespace "shop"
  input kubeconfig "$BATS_TEST_TMPDIR/custom/kubeconfig"
  input export-kubeconfig "false"
  run action
  [ "$status" -eq 0 ]
  [ "$(request 1 | jq -r .query.audience)" = "https://broker.example.com" ]
  [ "$(request 2 | jq -r .path)" = "/v1/auth/jwt/github-enterprise/login" ]
  [ "$(request 3 | jq -r .body.ttl)" = "30m" ]
  [ "$(output_value expires-in)" = "1800" ]
  [ "$(output_value kubeconfig)" = "$BATS_TEST_TMPDIR/custom/kubeconfig" ]
  [ "$(jq -r '.contexts[0].context.namespace' "$BATS_TEST_TMPDIR/custom/kubeconfig")" = "shop" ]
  [ ! -s "$GITHUB_ENV" ]
}

@test "trusts the CA of the input ca-certificate for OpenBao and writes the CA into the kubeconfig" {
  start_tls_mock
  input openbao-url "$MOCK_TLS_URL"
  ca=$(cat "$TLS_DIR/ca.pem")
  input ca-certificate "$ca"
  run action
  [ "$status" -eq 0 ]
  [ "$(request 2 | jq -r .path)" = "/v1/auth/jwt/github/login" ]
  [ "$(request 3 | jq -r .path)" = "/v1/kubernetes/c-m-4x2kq7bd/creds/p-abc12-project-member" ]
  [ "$(request_count)" -eq 3 ]
  kubeconfig=$(output_value kubeconfig)
  [ "$(jq -r '.clusters[0].cluster["certificate-authority-data"]' "$kubeconfig" | base64 -d)" = "$ca" ]
  [ "$(jq -r '.clusters[0].cluster | has("insecure-skip-tls-verify")' "$kubeconfig")" = "false" ]
}

@test "removes each CR character and the leading and trailing white space from ca-certificate" {
  start_tls_mock
  input openbao-url "$MOCK_TLS_URL"
  ca=$'\n  '"$(sed 's/$/\r/' "$TLS_DIR/ca.pem")"$'\r\n\n'
  input ca-certificate "$ca"
  run action
  [ "$status" -eq 0 ]
  [ "$(request_count)" -eq 3 ]
  kubeconfig=$(output_value kubeconfig)
  [ "$(jq -r '.clusters[0].cluster["certificate-authority-data"]' "$kubeconfig" | base64 -d)" = "$(cat "$TLS_DIR/ca.pem")" ]
}

@test "trusts a server certificate in ca-certificate" {
  start_tls_mock
  input openbao-url "$MOCK_TLS_URL"
  input ca-certificate "$(cat "$TLS_DIR/server.pem")"
  run action
  [ "$status" -eq 0 ]
  [ "$(request_count)" -eq 3 ]
}

@test "accepts a ca-certificate with two certificates" {
  start_tls_mock
  input openbao-url "$MOCK_TLS_URL"
  ca=$(cat "$TLS_DIR/server.pem" "$TLS_DIR/ca.pem")
  input ca-certificate "$ca"
  run action
  [ "$status" -eq 0 ]
  [ "$(request_count)" -eq 3 ]
}

@test "treats a ca-certificate of only white space as empty" {
  input ca-certificate $'\n \n'
  run action
  [ "$status" -eq 0 ]
  [ "$(jq -c '.clusters[0].cluster | keys' "$(output_value kubeconfig)")" = '["server"]' ]
}

@test "does not verify the certificate of OpenBao with insecure-skip-tls-verify, and writes the flag into the kubeconfig" {
  start_tls_mock
  input openbao-url "$MOCK_TLS_URL"
  input insecure-skip-tls-verify "true"
  run action
  [ "$status" -eq 0 ]
  [ "$(request_count)" -eq 3 ]
  kubeconfig=$(output_value kubeconfig)
  jq -e '.clusters[0].cluster["insecure-skip-tls-verify"] == true' "$kubeconfig"
  [ "$(jq -r '.clusters[0].cluster | has("certificate-authority-data")' "$kubeconfig")" = "false" ]
}

@test "fails when the CA of the OpenBao certificate is not in the CA store of the runner" {
  start_tls_mock
  input openbao-url "$MOCK_TLS_URL"
  run action
  [ "$status" -eq 1 ]
  grep -Eq "^::error::The login request to $MOCK_TLS_URL failed: .* \(UNABLE_TO_VERIFY_LEAF_SIGNATURE\)\.$" <<<"$output"
  [ "$(request_count)" -eq 1 ]
}

@test "trusts the CA of NODE_EXTRA_CA_CERTS for OpenBao without ca-certificate" {
  start_tls_mock
  input openbao-url "$MOCK_TLS_URL"
  export NODE_EXTRA_CA_CERTS="$TLS_DIR/ca.pem"
  run action
  [ "$status" -eq 0 ]
  [ "$(request_count)" -eq 3 ]
  [ "$(jq -c '.clusters[0].cluster | keys' "$(output_value kubeconfig)")" = '["server"]' ]
}

@test "verifies the certificate of OpenBao also when NODE_TLS_REJECT_UNAUTHORIZED is 0" {
  start_tls_mock
  input openbao-url "$MOCK_TLS_URL"
  export NODE_TLS_REJECT_UNAUTHORIZED=0
  run action
  [ "$status" -eq 1 ]
  grep -Eq "^::error::The login request to $MOCK_TLS_URL failed: .* \(UNABLE_TO_VERIFY_LEAF_SIGNATURE\)\.$" <<<"$output"
  [ "$(request_count)" -eq 1 ]
}

@test "does not use ca-certificate or insecure-skip-tls-verify for the OIDC request" {
  start_tls_mock
  export ACTIONS_ID_TOKEN_REQUEST_URL="$MOCK_TLS_URL/oidc?api-version=2.0"
  ca=$(cat "$TLS_DIR/ca.pem")
  input ca-certificate "$ca"
  run action
  [ "$status" -eq 1 ]
  grep -Eq "^::error::The OIDC token request to GitHub failed: .* \(UNABLE_TO_VERIFY_LEAF_SIGNATURE\)\.$" <<<"$output"

  unset 'INPUTS[ca-certificate]'
  input insecure-skip-tls-verify "true"
  run action
  [ "$status" -eq 1 ]
  grep -Eq "^::error::The OIDC token request to GitHub failed: .* \(UNABLE_TO_VERIFY_LEAF_SIGNATURE\)\.$" <<<"$output"
  [ "$(request_count)" -eq 0 ]
}

@test "sends the requests to https URLs through HTTPS_PROXY" {
  start_tls_mock
  start_proxy
  export ACTIONS_ID_TOKEN_REQUEST_URL="$MOCK_TLS_URL/oidc?api-version=2.0"
  input openbao-url "$MOCK_TLS_URL"
  input ca-certificate "$(cat "$TLS_DIR/ca.pem")"
  export NODE_EXTRA_CA_CERTS="$TLS_DIR/ca.pem"
  export HTTPS_PROXY="$PROXY_URL"
  run action
  [ "$status" -eq 0 ]
  [ "$(request_count)" -eq 3 ]
  # The mock closes the connection after each answer, so Node opens one tunnel for each request.
  [ "$(wc -l < "$PROXY_LOG")" -eq 3 ]
  [ "$(sort -u "$PROXY_LOG")" = "CONNECT 127.0.0.1:${MOCK_TLS_URL##*:}" ]
}

@test "does not use HTTPS_PROXY for a host in NO_PROXY" {
  start_tls_mock
  start_proxy
  export ACTIONS_ID_TOKEN_REQUEST_URL="$MOCK_TLS_URL/oidc?api-version=2.0"
  input openbao-url "$MOCK_TLS_URL"
  input ca-certificate "$(cat "$TLS_DIR/ca.pem")"
  export NODE_EXTRA_CA_CERTS="$TLS_DIR/ca.pem"
  export HTTPS_PROXY="$PROXY_URL"
  export NO_PROXY=127.0.0.1
  run action
  [ "$status" -eq 0 ]
  [ "$(request_count)" -eq 3 ]
  [ ! -s "$PROXY_LOG" ]
}

@test "verifies the certificate of OpenBao also through HTTPS_PROXY" {
  start_tls_mock
  start_proxy
  input openbao-url "$MOCK_TLS_URL"
  export HTTPS_PROXY="$PROXY_URL"
  run action
  [ "$status" -eq 1 ]
  grep -Eq "^::error::The login request to $MOCK_TLS_URL failed: .* \(UNABLE_TO_VERIFY_LEAF_SIGNATURE\)\.$" <<<"$output"
  [ "$(wc -l < "$PROXY_LOG")" -eq 1 ]
}

@test "does not send a plain http request through HTTP_PROXY" {
  start_proxy
  export HTTP_PROXY="$PROXY_URL"
  export http_proxy="$PROXY_URL"
  run action
  [ "$status" -eq 0 ]
  [ "$(request_count)" -eq 3 ]
}

@test "connects without a proxy when Node cannot use the proxy variables" {
  start_tls_mock
  input openbao-url "$MOCK_TLS_URL"
  input ca-certificate "$(cat "$TLS_DIR/ca.pem")"
  export ACTIONS_ID_TOKEN_REQUEST_URL="$MOCK_TLS_URL/oidc?api-version=2.0"
  export NODE_EXTRA_CA_CERTS="$TLS_DIR/ca.pem"
  export HTTPS_PROXY="proxy.invalid:3128"
  run action
  [ "$status" -eq 0 ]
  [ "$(request_count)" -eq 3 ]
  grep -qx "Node cannot use the proxy variables of the job. The action connects without a proxy." <<<"$output"
}

@test "rejects ca-certificate together with insecure-skip-tls-verify" {
  ca=$(cat "$TLS_DIR/ca.pem")
  input ca-certificate "$ca"
  input insecure-skip-tls-verify "true"
  run action
  [ "$status" -eq 1 ]
  grep -q "^::error::Set the input ca-certificate or the input insecure-skip-tls-verify. Do not set both, because kubectl does not accept a kubeconfig with both.$" <<<"$output"
  [ "$(request_count)" -eq 0 ]
}

@test "rejects a ca-certificate that is not one or more PEM certificates, and an insecure-skip-tls-verify value outside true and false" {
  input ca-certificate "$TLS_DIR/ca.pem"
  run action
  [ "$status" -eq 1 ]
  grep -q "^::error::The input ca-certificate is not valid. The value must be one or more PEM certificates, or empty.$" <<<"$output"

  input ca-certificate "$(cat "$TLS_DIR/ca.pem" "$TLS_DIR/server.key" "$TLS_DIR/ca.pem")"
  run action
  [ "$status" -eq 1 ]
  grep -q "^::error::The input ca-certificate is not valid." <<<"$output"

  input ca-certificate "$(tr '\n' ' ' < "$TLS_DIR/ca.pem")"
  run action
  [ "$status" -eq 1 ]
  grep -q "^::error::The input ca-certificate is not valid." <<<"$output"

  unset 'INPUTS[ca-certificate]'
  input insecure-skip-tls-verify "yes"
  run action
  [ "$status" -eq 1 ]
  grep -q "^::error::The input insecure-skip-tls-verify is not valid. The value must be true or false.$" <<<"$output"
  [ "$(request_count)" -eq 0 ]
}

@test "appends the audience to a request URL without a query" {
  export ACTIONS_ID_TOKEN_REQUEST_URL="$MOCK_URL/oidc"
  run action
  [ "$status" -eq 0 ]
  [ "$(request 1 | jq -r .query.audience)" = "$MOCK_URL" ]
}

@test "masks each token before the first line that contains it" {
  run action
  [ "$status" -eq 0 ]
  jwt=$(request 2 | jq -r .body.jwt)
  [ "$(first_line_with "$jwt")" = "::add-mask::$jwt" ]
  [ "$(first_line_with hvb.mock-client-token)" = "::add-mask::hvb.mock-client-token" ]
  [ "$(first_line_with "$SA_TOKEN")" = "::add-mask::$SA_TOKEN" ]
}

@test "gives the mode 0600 to a kubeconfig that exists before the run" {
  mkdir -p "$BATS_TEST_TMPDIR/custom"
  echo old > "$BATS_TEST_TMPDIR/custom/kubeconfig"
  chmod 644 "$BATS_TEST_TMPDIR/custom/kubeconfig"
  input kubeconfig "$BATS_TEST_TMPDIR/custom/kubeconfig"
  run action
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$BATS_TEST_TMPDIR/custom/kubeconfig")" = "600" ]
  [ "$(jq -r '.users[0].user.token' "$BATS_TEST_TMPDIR/custom/kubeconfig")" = "$SA_TOKEN" ]
}

@test "creates the missing directories of the kubeconfig path with the mode 0700" {
  input kubeconfig "$BATS_TEST_TMPDIR/new/dir/kubeconfig"
  run action
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$BATS_TEST_TMPDIR/new/dir/kubeconfig")" = "600" ]
  [ "$(stat -c %a "$BATS_TEST_TMPDIR/new/dir")" = "700" ]
}

@test "replaces a symlink at the kubeconfig path and does not change its target" {
  mkdir -p "$BATS_TEST_TMPDIR/custom"
  echo old > "$BATS_TEST_TMPDIR/custom/target"
  ln -s target "$BATS_TEST_TMPDIR/custom/link"
  input kubeconfig "$BATS_TEST_TMPDIR/custom/link"
  run action
  [ "$status" -eq 0 ]
  [ ! -L "$BATS_TEST_TMPDIR/custom/link" ]
  [ -f "$BATS_TEST_TMPDIR/custom/link" ]
  [ "$(cat "$BATS_TEST_TMPDIR/custom/target")" = "old" ]
}

@test "fails without the id-token permission" {
  unset ACTIONS_ID_TOKEN_REQUEST_URL
  run action
  [ "$status" -eq 1 ]
  grep -q "^::error::The job cannot request an OIDC token. Give the job the permission id-token: write.$" <<<"$output"
  [ "$(request_count)" -eq 0 ]
}

@test "fails with the error of GitHub when the OIDC request fails" {
  mock_config '{"oidc_status": 500}'
  run action
  [ "$status" -eq 1 ]
  grep -q "^::error::GitHub did not return an OIDC token (HTTP 500): the OIDC endpoint failed$" <<<"$output"
  [ "$(request_count)" -eq 1 ]
}

@test "does not print a part of a response that is not a JSON object" {
  mock_config '{"oidc_body": "eyJhbGciOiJub25lIn0.secret-part <html>"}'
  run action
  [ "$status" -eq 1 ]
  grep -q "^::error::The response of the request oidc is not a JSON object.$" <<<"$output"
  [[ "$output" != *secret-part* ]]
}

@test "fails when a response is not a JSON object" {
  mock_config '{"oidc_body": "<html>login</html>"}'
  run action
  [ "$status" -eq 1 ]
  grep -q "^::error::The response of the request oidc is not a JSON object.$" <<<"$output"
  [ "$(request_count)" -eq 1 ]
}

@test "fails with the cause when OpenBao does not answer" {
  input openbao-url "http://127.0.0.1:1"
  run action
  [ "$status" -eq 1 ]
  grep -q "^::error::The login request to http://127.0.0.1:1 failed: connect ECONNREFUSED 127.0.0.1:1.$" <<<"$output"
  [ "$(request_count)" -eq 1 ]
}

@test "fails when the OIDC response is larger than 1 MiB" {
  mock_config '{"oidc_padding": 1048577}'
  run action
  [ "$status" -eq 1 ]
  grep -q "^::error::The OIDC token request to GitHub failed: the response is larger than 1 MiB.$" <<<"$output"
  [ "$(request_count)" -eq 1 ]
}

@test "does not follow a redirect of the login response" {
  mock_config '{"login_redirect": "'"$MOCK_URL"'/v1/redirected"}'
  run action
  [ "$status" -eq 1 ]
  grep -q "^::error::OpenBao refused the login with the role c-m-4x2kq7bd_p-abc12_deploy-main at auth/jwt/github (HTTP 302):" <<<"$output"
  [ "$(request_count)" -eq 2 ]
}

@test "replaces each line break and each control character of an OpenBao error with a space" {
  mock_config '{"login_status": 403, "login_errors": ["bad\u001b[31m\n::add-mask::x"]}'
  run action
  [ "$status" -eq 1 ]
  [ "$(grep -c 'OpenBao refused the login' <<<"$output")" -eq 1 ]
  [ "$(grep -c '^::add-mask::x' <<<"$output")" -eq 0 ]
  [[ "$output" != *$'\033'* ]]
}

@test "fails with the error of OpenBao on one line when OpenBao refuses the login" {
  mock_config '{"login_status": 403}'
  run action
  [ "$status" -eq 1 ]
  grep -q "^::error::OpenBao refused the login with the role c-m-4x2kq7bd_p-abc12_deploy-main at auth/jwt/github (HTTP 403): 1 error occurred: \* permission denied$" <<<"$output"
  [ "$(request_count)" -eq 2 ]
  [ ! -s "$GITHUB_OUTPUT" ]
  [ ! -s "$GITHUB_ENV" ]
}

@test "fails with the error of OpenBao when OpenBao refuses the token request" {
  mock_config '{"creds_status": 400}'
  run action
  [ "$status" -eq 1 ]
  grep -q "^::error::OpenBao did not return a token of drover-c-m-4x2kq7bd-p-abc12/project-member (HTTP 400): the role does not exist$" <<<"$output"
  [ ! -s "$GITHUB_OUTPUT" ]
}

@test "rejects an OpenBao token with a character outside the token alphabet" {
  mock_config '{"client_token": "hvb.x\"\ndata-binary = \"@/etc/passwd\""}'
  run action
  [ "$status" -eq 1 ]
  grep -q "^::error::The OpenBao token is not one line of the characters A-Z, a-z, 0-9, '.', '_', and '-'.$" <<<"$output"
  [ "$(request_count)" -eq 2 ]
}

@test "rejects a lease duration that is not a number of seconds, and does not write the kubeconfig" {
  mock_config '{"lease_duration": "900\ninjected=1"}'
  run action
  [ "$status" -eq 1 ]
  grep -q "^::error::The lease duration of the token response is not a number of seconds.$" <<<"$output"
  [ ! -s "$GITHUB_OUTPUT" ]
  [ -z "$(find "$BATS_TEST_TMPDIR" -maxdepth 1 -name 'drover-kubeconfig.*')" ]
}

@test "rejects a ServiceAccount token with a line break" {
  mock_config '{"service_account_token": "eyJ.a\n::error::injected"}'
  run action
  [ "$status" -eq 1 ]
  grep -q "^::error::The ServiceAccount token is not one line of the characters A-Z, a-z, 0-9, '.', '_', and '-'.$" <<<"$output"
  [ "$(grep -c '^::error::injected' <<<"$output")" -eq 0 ]
  [ ! -s "$GITHUB_OUTPUT" ]
}

@test "rejects an OpenBao token with fewer than 16 characters" {
  mock_config '{"client_token": "hvb.short"}'
  run action
  [ "$status" -eq 1 ]
  grep -q "^::error::The OpenBao token contains fewer than 16 characters.$" <<<"$output"
  [ "$(grep -c '^::add-mask::hvb.short' <<<"$output")" -eq 0 ]
  [ "$(request_count)" -eq 2 ]
}

@test "fails when OpenBao answers the login request with the status 101" {
  mock_config '{"login_status": 101}'
  run action
  [ "$status" -eq 1 ]
  grep -qx "::error::The login request to $MOCK_URL failed: the server changed the protocol." <<<"$output"
}

@test "rejects a role outside the three project roles" {
  input role "admin"
  run action
  [ "$status" -eq 1 ]
  grep -q "^::error::The input role is not valid. The value must be project-owner, project-member, or read-only.$" <<<"$output"
  [ "$(request_count)" -eq 0 ]
}

@test "rejects a URL with a path" {
  input openbao-url "https://openbao.example.com/v1"
  run action
  [ "$status" -eq 1 ]
  grep -q "^::error::The input openbao-url is not valid. The value must be an https URL with a host and without a path.$" <<<"$output"
  [ "$(request_count)" -eq 0 ]
}

@test "rejects a plain http URL of a remote host" {
  input rancher-url "http://rancher.example.com"
  run action
  [ "$status" -eq 1 ]
  grep -q "^::error::The input rancher-url is not valid." <<<"$output"
  [ "$(request_count)" -eq 0 ]
}

@test "rejects a statement name with an uppercase letter" {
  input statement "Deploy"
  run action
  [ "$status" -eq 1 ]
  grep -q "^::error::The input statement is not valid." <<<"$output"
}

@test "rejects a relative kubeconfig path" {
  input kubeconfig "relative/kubeconfig"
  run action
  [ "$status" -eq 1 ]
  grep -q "^::error::The input kubeconfig is not valid. The value must be an absolute path, or empty.$" <<<"$output"
  [ "$(request_count)" -eq 0 ]
}

@test "rejects a kubeconfig path with a line break" {
  input kubeconfig $'/tmp/x\nserver=injected'
  run action
  [ "$status" -eq 1 ]
  grep -q "^::error::The input kubeconfig is not valid. The value must be an absolute path, or empty.$" <<<"$output"
  [ "$(request_count)" -eq 0 ]
}

@test "rejects a kubeconfig path that is a directory" {
  input kubeconfig "$BATS_TEST_TMPDIR"
  run action
  [ "$status" -eq 1 ]
  grep -q "^::error::The input kubeconfig is a directory.$" <<<"$output"
  [ "$(request_count)" -eq 0 ]
}

@test "fails when the login response does not contain a client token" {
  mock_config '{"client_token": ""}'
  run action
  [ "$status" -eq 1 ]
  grep -q "^::error::The login response does not contain a client token.$" <<<"$output"
  [ "$(request_count)" -eq 2 ]
}

@test "rejects a cluster id, a ttl, and an export-kubeconfig value outside their patterns" {
  input cluster 'c-m-4x2kq7bd"'
  run action
  [ "$status" -eq 1 ]
  grep -q "^::error::The input cluster is not valid." <<<"$output"

  input cluster "c-m-4x2kq7bd"
  input ttl "30 minutes"
  run action
  [ "$status" -eq 1 ]
  grep -q "^::error::The input ttl is not valid. The value must be a duration, for example 30m, or empty.$" <<<"$output"

  unset 'INPUTS[ttl]'
  input export-kubeconfig "yes"
  run action
  [ "$status" -eq 1 ]
  grep -q "^::error::The input export-kubeconfig is not valid. The value must be true or false.$" <<<"$output"
  [ "$(request_count)" -eq 0 ]
}

@test "fails without the OIDC request token" {
  unset ACTIONS_ID_TOKEN_REQUEST_TOKEN
  run action
  [ "$status" -eq 1 ]
  grep -q "^::error::The job cannot request an OIDC token. Give the job the permission id-token: write.$" <<<"$output"
  [ "$(request_count)" -eq 0 ]
}

@test "fails when the default directory of the kubeconfig cannot be created" {
  export RUNNER_TEMP="$BATS_TEST_TMPDIR/missing"
  run action
  [ "$status" -eq 1 ]
  grep -Eq "^::error::The action cannot write the kubeconfig: .*ENOENT" <<<"$output"
}

@test "fails when the file of GITHUB_OUTPUT cannot be written" {
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/missing/output"
  run action
  [ "$status" -eq 1 ]
  grep -qx "::error::The action cannot write to the file of GITHUB_OUTPUT." <<<"$output"
}

@test "fails without the variable GITHUB_OUTPUT" {
  unset GITHUB_OUTPUT
  run action
  [ "$status" -eq 1 ]
  grep -q "^::error::The variable GITHUB_OUTPUT is not set.$" <<<"$output"
}
