#!/usr/bin/env bats
# bats sets the variables output and status in the function run. shellcheck reads a test body as
# a subshell.
# shellcheck disable=SC2030,SC2031,SC2154

load helpers

setup_file() {
  make_certificates
}

setup() {
  start_mock
  login_env
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/login.sh"
}

teardown() {
  stop_mock
}

@test "logs in, requests the token, and writes the kubeconfig" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]

  # The OIDC request contains the OpenBao URL as the audience, and the request token.
  [ "$(request 1 | jq -r .path)" = "/oidc" ]
  [ "$(request 1 | jq -r '.query["api-version"]')" = "2.0" ]
  [ "$(request 1 | jq -r .query.audience)" = "$MOCK_URL" ]
  [ "$(request 1 | jq -r .headers.authorization)" = "bearer request-token" ]

  # The login request contains the login role of the statement and the JWT from the OIDC response.
  [ "$(request 2 | jq -r .path)" = "/v1/auth/jwt/github/login" ]
  [ "$(request 2 | jq -r .body.role)" = "c-m-4x2kq7bd_p-abc12_deploy-main" ]
  [ "$(request 2 | jq -r .jwt_claims.aud)" = "$MOCK_URL" ]

  # The token request contains the client token, the path of the token role, and the account namespace.
  [ "$(request 3 | jq -r .path)" = "/v1/kubernetes/c-m-4x2kq7bd/creds/p-abc12-project-member" ]
  [ "$(request 3 | jq -r '.headers["x-vault-token"]')" = "hvb.mock-client-token" ]
  [ "$(request 3 | jq -r .body.kubernetes_namespace)" = "drover-c-m-4x2kq7bd-p-abc12" ]
  [ "$(request 3 | jq -r '.body | has("ttl")')" = "false" ]
  [ "$(request_count)" -eq 3 ]

  # The test checks the outputs, the kubeconfig, and the KUBECONFIG variable.
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

  # The log contains the progress lines and a mask for each token.
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

@test "passes the audience, the issuer, the ttl, the namespace, and the kubeconfig path" {
  export DROVER_AUDIENCE="https://broker.example.com"
  export DROVER_ISSUER="github-enterprise"
  export DROVER_TTL="30m"
  export DROVER_NAMESPACE="shop"
  export DROVER_KUBECONFIG="$BATS_TEST_TMPDIR/custom/kubeconfig"
  export DROVER_EXPORT_KUBECONFIG="false"
  run "$SCRIPT"
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
  export DROVER_OPENBAO_URL="$MOCK_TLS_URL"
  DROVER_CA_CERTIFICATE=$(cat "$TLS_DIR/ca.pem")
  export DROVER_CA_CERTIFICATE
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(request 2 | jq -r .path)" = "/v1/auth/jwt/github/login" ]
  [ "$(request 3 | jq -r .path)" = "/v1/kubernetes/c-m-4x2kq7bd/creds/p-abc12-project-member" ]
  [ "$(request_count)" -eq 3 ]
  kubeconfig=$(output_value kubeconfig)
  [ "$(jq -r '.clusters[0].cluster["certificate-authority-data"]' "$kubeconfig" | base64 -d)" = "$DROVER_CA_CERTIFICATE" ]
  [ "$(jq -r '.clusters[0].cluster | has("insecure-skip-tls-verify")' "$kubeconfig")" = "false" ]
}

@test "removes the CR characters and the white space around ca-certificate" {
  start_tls_mock
  export DROVER_OPENBAO_URL="$MOCK_TLS_URL"
  DROVER_CA_CERTIFICATE=$'\n  '"$(sed 's/$/\r/' "$TLS_DIR/ca.pem")"$'\r\n\n'
  export DROVER_CA_CERTIFICATE
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(request_count)" -eq 3 ]
  kubeconfig=$(output_value kubeconfig)
  [ "$(jq -r '.clusters[0].cluster["certificate-authority-data"]' "$kubeconfig" | base64 -d)" = "$(cat "$TLS_DIR/ca.pem")" ]
}

@test "accepts a ca-certificate with two certificates" {
  start_tls_mock
  export DROVER_OPENBAO_URL="$MOCK_TLS_URL"
  DROVER_CA_CERTIFICATE=$(cat "$TLS_DIR/server.pem" "$TLS_DIR/ca.pem")
  export DROVER_CA_CERTIFICATE
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(request_count)" -eq 3 ]
}

@test "treats a ca-certificate of only white space as empty" {
  export DROVER_CA_CERTIFICATE=$'\n \n'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.clusters[0].cluster | keys' "$(output_value kubeconfig)")" = '["server"]' ]
}

@test "does not verify the certificate of OpenBao with insecure-skip-tls-verify, and writes the flag into the kubeconfig" {
  start_tls_mock
  export DROVER_OPENBAO_URL="$MOCK_TLS_URL"
  export DROVER_INSECURE_SKIP_TLS_VERIFY="true"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(request_count)" -eq 3 ]
  kubeconfig=$(output_value kubeconfig)
  jq -e '.clusters[0].cluster["insecure-skip-tls-verify"] == true' "$kubeconfig"
  [ "$(jq -r '.clusters[0].cluster | has("certificate-authority-data")' "$kubeconfig")" = "false" ]
}

@test "fails when OpenBao has a certificate of a CA that the runner does not trust" {
  start_tls_mock
  export DROVER_OPENBAO_URL="$MOCK_TLS_URL"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  grep -q "^::error::The login request to $MOCK_TLS_URL failed (curl exit code 60).$" <<<"$output"
  [ "$(request_count)" -eq 1 ]
}

@test "does not use ca-certificate or insecure-skip-tls-verify for the OIDC request" {
  start_tls_mock
  export ACTIONS_ID_TOKEN_REQUEST_URL="$MOCK_TLS_URL/oidc?api-version=2.0"
  DROVER_CA_CERTIFICATE=$(cat "$TLS_DIR/ca.pem")
  export DROVER_CA_CERTIFICATE
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  grep -q "^::error::The OIDC token request to GitHub failed (curl exit code 60).$" <<<"$output"

  unset DROVER_CA_CERTIFICATE
  export DROVER_INSECURE_SKIP_TLS_VERIFY="true"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  grep -q "^::error::The OIDC token request to GitHub failed (curl exit code 60).$" <<<"$output"
  [ "$(request_count)" -eq 0 ]
}

@test "rejects ca-certificate together with insecure-skip-tls-verify" {
  DROVER_CA_CERTIFICATE=$(cat "$TLS_DIR/ca.pem")
  export DROVER_CA_CERTIFICATE
  export DROVER_INSECURE_SKIP_TLS_VERIFY="true"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  grep -q "^::error::Set the input ca-certificate or the input insecure-skip-tls-verify, not both. kubectl does not accept a kubeconfig with both.$" <<<"$output"
  [ "$(request_count)" -eq 0 ]
}

@test "rejects a ca-certificate that is not PEM, and an insecure-skip-tls-verify value outside true and false" {
  export DROVER_CA_CERTIFICATE="$TLS_DIR/ca.pem"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  grep -q "^::error::The input ca-certificate is not valid. The value must be one or more PEM certificates, or empty.$" <<<"$output"

  DROVER_CA_CERTIFICATE="$(cat "$TLS_DIR/ca.pem" "$TLS_DIR/server.key" "$TLS_DIR/ca.pem")"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  grep -q "^::error::The input ca-certificate is not valid." <<<"$output"

  DROVER_CA_CERTIFICATE="$(tr '\n' ' ' < "$TLS_DIR/ca.pem")"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  grep -q "^::error::The input ca-certificate is not valid." <<<"$output"

  unset DROVER_CA_CERTIFICATE
  export DROVER_INSECURE_SKIP_TLS_VERIFY="yes"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  grep -q "^::error::The input insecure-skip-tls-verify is not valid. The value must be true or false.$" <<<"$output"
  [ "$(request_count)" -eq 0 ]
}

@test "appends the audience to a request URL without a query" {
  export ACTIONS_ID_TOKEN_REQUEST_URL="$MOCK_URL/oidc"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(request 1 | jq -r .query.audience)" = "$MOCK_URL" ]
}

@test "keeps every token off the command lines of jq and curl" {
  guard_command_lines
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(request_count)" -eq 3 ]
}

@test "masks each token before the first line that contains it, also with xtrace on" {
  run env SHELLOPTS=xtrace "$SCRIPT"
  [ "$status" -eq 0 ]
  jwt=$(request 2 | jq -r .body.jwt)
  [ "$(first_line_with "$jwt")" = "::add-mask::$jwt" ]
  [ "$(first_line_with hvb.mock-client-token)" = "::add-mask::hvb.mock-client-token" ]
  [ "$(first_line_with "$SA_TOKEN")" = "::add-mask::$SA_TOKEN" ]
}

@test "does not read the curlrc of the runner" {
  echo "trace-ascii = \"$BATS_TEST_TMPDIR/trace.txt\"" > "$HOME/.curlrc"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/trace.txt" ]
}

@test "gives the mode 0600 to a kubeconfig that exists before the run" {
  mkdir -p "$BATS_TEST_TMPDIR/custom"
  echo old > "$BATS_TEST_TMPDIR/custom/kubeconfig"
  chmod 644 "$BATS_TEST_TMPDIR/custom/kubeconfig"
  export DROVER_KUBECONFIG="$BATS_TEST_TMPDIR/custom/kubeconfig"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$BATS_TEST_TMPDIR/custom/kubeconfig")" = "600" ]
  [ "$(jq -r '.users[0].user.token' "$BATS_TEST_TMPDIR/custom/kubeconfig")" = "$SA_TOKEN" ]
}

@test "replaces a symlink at the kubeconfig path and does not change its target" {
  mkdir -p "$BATS_TEST_TMPDIR/custom"
  echo old > "$BATS_TEST_TMPDIR/custom/target"
  ln -s target "$BATS_TEST_TMPDIR/custom/link"
  export DROVER_KUBECONFIG="$BATS_TEST_TMPDIR/custom/link"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -L "$BATS_TEST_TMPDIR/custom/link" ]
  [ -f "$BATS_TEST_TMPDIR/custom/link" ]
  [ "$(cat "$BATS_TEST_TMPDIR/custom/target")" = "old" ]
}

@test "removes the request files at exit" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$(find "$BATS_TEST_TMPDIR" -maxdepth 1 -name 'drover-login.*')" ]
}

@test "fails without the id-token permission" {
  unset ACTIONS_ID_TOKEN_REQUEST_URL
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  grep -q "^::error::The job cannot request an OIDC token. Give the job the permission id-token: write.$" <<<"$output"
  [ "$(request_count)" -eq 0 ]
}

@test "fails with the error of GitHub when the OIDC request fails" {
  mock_config '{"oidc_status": 500}'
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  grep -q "^::error::GitHub did not return an OIDC token (HTTP 500): the OIDC endpoint failed$" <<<"$output"
  [ "$(request_count)" -eq 1 ]
}

@test "fails when a response is not a JSON object" {
  mock_config '{"oidc_body": "<html>login</html>"}'
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  grep -q "^::error::The response of the request oidc is not a JSON object.$" <<<"$output"
  [ "$(request_count)" -eq 1 ]
}

@test "fails with the curl exit code when OpenBao does not answer" {
  export DROVER_OPENBAO_URL="http://127.0.0.1:1"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  grep -q "^::error::The login request to http://127.0.0.1:1 failed (curl exit code 7).$" <<<"$output"
  [ "$(request_count)" -eq 1 ]
  [ -z "$(find "$BATS_TEST_TMPDIR" -maxdepth 1 -name 'drover-login.*')" ]
}

@test "fails with the error of OpenBao on one line when OpenBao refuses the login" {
  mock_config '{"login_status": 403}'
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  grep -q "^::error::OpenBao refused the login with the role c-m-4x2kq7bd_p-abc12_deploy-main at auth/jwt/github (HTTP 403): 1 error occurred: \* permission denied$" <<<"$output"
  [ "$(request_count)" -eq 2 ]
  [ ! -s "$GITHUB_OUTPUT" ]
  [ ! -s "$GITHUB_ENV" ]
}

@test "fails with the error of OpenBao when OpenBao refuses the token request" {
  mock_config '{"creds_status": 400}'
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  grep -q "^::error::OpenBao did not return a token of drover-c-m-4x2kq7bd-p-abc12/project-member (HTTP 400): the role does not exist$" <<<"$output"
  [ ! -s "$GITHUB_OUTPUT" ]
}

@test "rejects an OpenBao token with a character outside the token alphabet" {
  mock_config '{"client_token": "hvb.x\"\ndata-binary = \"@/etc/passwd\""}'
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  grep -q "^::error::The OpenBao token is not one line of the characters A-Z, a-z, 0-9, '.', '_', and '-'.$" <<<"$output"
  [ "$(request_count)" -eq 2 ]
}

@test "rejects a role outside the three project roles" {
  export DROVER_ROLE="admin"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  grep -q "^::error::The input role is not valid. The value must be project-owner, project-member, or read-only.$" <<<"$output"
  [ "$(request_count)" -eq 0 ]
}

@test "rejects a URL with a path" {
  export DROVER_OPENBAO_URL="https://openbao.example.com/v1"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  grep -q "^::error::The input openbao-url is not valid. The value must be an https URL with a host and without a path.$" <<<"$output"
  [ "$(request_count)" -eq 0 ]
}

@test "rejects a plain http URL of a remote host" {
  export DROVER_RANCHER_URL="http://rancher.example.com"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  grep -q "^::error::The input rancher-url is not valid." <<<"$output"
  [ "$(request_count)" -eq 0 ]
}

@test "rejects a statement name with an uppercase letter" {
  export DROVER_STATEMENT="Deploy"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  grep -q "^::error::The input statement is not valid." <<<"$output"
}

@test "rejects a relative kubeconfig path" {
  export DROVER_KUBECONFIG="relative/kubeconfig"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  grep -q "^::error::The input kubeconfig is not valid. The value must be an absolute path, or empty.$" <<<"$output"
  [ "$(request_count)" -eq 0 ]
}

@test "rejects a kubeconfig path that is a directory" {
  export DROVER_KUBECONFIG="$BATS_TEST_TMPDIR"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  grep -q "^::error::The input kubeconfig is a directory.$" <<<"$output"
  [ "$(request_count)" -eq 0 ]
}

@test "fails when the login response does not contain a client token" {
  mock_config '{"client_token": ""}'
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  grep -q "^::error::The login response does not contain a client token.$" <<<"$output"
  [ "$(request_count)" -eq 2 ]
}

@test "rejects a cluster id, a ttl, and an export-kubeconfig value outside their patterns" {
  export DROVER_CLUSTER='c-m-4x2kq7bd"'
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  grep -q "^::error::The input cluster is not valid." <<<"$output"

  export DROVER_CLUSTER="c-m-4x2kq7bd"
  export DROVER_TTL="30 minutes"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  grep -q "^::error::The input ttl is not valid. The value must be a duration, for example 30m, or empty.$" <<<"$output"

  unset DROVER_TTL
  export DROVER_EXPORT_KUBECONFIG="yes"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  grep -q "^::error::The input export-kubeconfig is not valid. The value must be true or false.$" <<<"$output"
  [ "$(request_count)" -eq 0 ]
}

@test "fails without the OIDC request token" {
  unset ACTIONS_ID_TOKEN_REQUEST_TOKEN
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  grep -q "^::error::The job cannot request an OIDC token. Give the job the permission id-token: write.$" <<<"$output"
  [ "$(request_count)" -eq 0 ]
}
