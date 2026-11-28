SA_TOKEN="eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJtb2NrIn0.mock-service-account-token"
export SA_TOKEN

# Starts the mock server in the background. bats waits for each background process that keeps
# file descriptor 3 open. For this reason, the function starts the server with that descriptor closed.
start_mock() {
  export MOCK_PORT_FILE="$BATS_TEST_TMPDIR/mock.port"
  export MOCK_LOG="$BATS_TEST_TMPDIR/mock.log"
  export MOCK_CONFIG="$BATS_TEST_TMPDIR/mock.json"
  python3 "$BATS_TEST_DIRNAME/mock/server.py" 3>&- &
  MOCK_PID=$!
  for _ in $(seq 1 50); do
    [[ -s "$MOCK_PORT_FILE" ]] && break
    sleep 0.1
  done
  [[ -s "$MOCK_PORT_FILE" ]] || {
    echo "the mock server did not start" >&2
    return 1
  }
  MOCK_URL="http://127.0.0.1:$(cat "$MOCK_PORT_FILE")"
  export MOCK_URL
}

# Starts a second mock server that answers over HTTPS. The server uses the log and the config that
# start_mock sets. Call start_mock first.
start_tls_mock() {
  local port_file="$BATS_TEST_TMPDIR/mock-tls.port"
  MOCK_PORT_FILE="$port_file" MOCK_TLS_CERT="$TLS_DIR/server.pem" MOCK_TLS_KEY="$TLS_DIR/server.key" \
    python3 "$BATS_TEST_DIRNAME/mock/server.py" 3>&- &
  MOCK_TLS_PID=$!
  for _ in $(seq 1 50); do
    [[ -s "$port_file" ]] && break
    sleep 0.1
  done
  [[ -s "$port_file" ]] || {
    echo "the TLS mock server did not start" >&2
    return 1
  }
  MOCK_TLS_URL="https://127.0.0.1:$(cat "$port_file")"
  export MOCK_TLS_URL
}

# Starts a forward proxy for CONNECT requests.
start_proxy() {
  local port_file="$BATS_TEST_TMPDIR/proxy.port"
  export PROXY_LOG="$BATS_TEST_TMPDIR/proxy.log"
  PROXY_PORT_FILE="$port_file" python3 "$BATS_TEST_DIRNAME/mock/proxy.py" 3>&- &
  PROXY_PID=$!
  for _ in $(seq 1 50); do
    [[ -s "$port_file" ]] && break
    sleep 0.1
  done
  [[ -s "$port_file" ]] || {
    echo "the proxy did not start" >&2
    return 1
  }
  PROXY_URL="http://127.0.0.1:$(cat "$port_file")"
  export PROXY_URL
}

stop_mock() {
  local pid
  for pid in "${MOCK_PID:-}" "${MOCK_TLS_PID:-}" "${PROXY_PID:-}"; do
    if [[ -n "$pid" ]]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
}

# Writes a test CA and a server certificate for 127.0.0.1, signed by that CA, to TLS_DIR.
make_certificates() {
  export TLS_DIR="$BATS_FILE_TMPDIR/tls"
  mkdir -p "$TLS_DIR"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 -subj /CN=test-ca \
    -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign \
    -keyout "$TLS_DIR/ca.key" -out "$TLS_DIR/ca.pem" 2>/dev/null
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj /CN=127.0.0.1 \
    -keyout "$TLS_DIR/server.key" -out "$TLS_DIR/server.csr" 2>/dev/null
  printf 'subjectAltName=IP:127.0.0.1\nbasicConstraints=CA:FALSE\n' > "$TLS_DIR/server.ext"
  openssl x509 -req -in "$TLS_DIR/server.csr" -CA "$TLS_DIR/ca.pem" -CAkey "$TLS_DIR/ca.key" \
    -set_serial 1 -days 1 -extfile "$TLS_DIR/server.ext" -out "$TLS_DIR/server.pem" 2>/dev/null
}

# Writes the mock config. The keys are in mock/server.py.
mock_config() {
  echo "$1" > "$MOCK_CONFIG"
}

# bats loads this file in a function. Without -g, bash makes INPUTS local to that function.
declare -gA INPUTS=()

input() {
  INPUTS["$1"]="$2"
}

# Runs the action as the runner does. The runner passes the input <name> as INPUT_<NAME> and keeps
# the dashes. Bash cannot export such a name, so the function uses env.
action() {
  local name args=()
  for name in "${!INPUTS[@]}"; do
    args+=("INPUT_${name^^}=${INPUTS[$name]}")
  done
  env "${args[@]}" "${ACTION_NODE:-node}" "$BATS_TEST_DIRNAME/../dist/main.js"
}

login_env() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  export RUNNER_TEMP="$BATS_TEST_TMPDIR"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/output"
  export GITHUB_ENV="$BATS_TEST_TMPDIR/env"
  : > "$GITHUB_OUTPUT"
  : > "$GITHUB_ENV"
  export ACTIONS_ID_TOKEN_REQUEST_URL="$MOCK_URL/oidc?api-version=2.0"
  export ACTIONS_ID_TOKEN_REQUEST_TOKEN="request-token"
  # A test result must not depend on the proxy variables of the developer's shell.
  unset HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy NODE_USE_ENV_PROXY
  INPUTS=()
  input openbao-url "$MOCK_URL"
  input rancher-url "https://rancher.example.com/"
  input cluster "c-m-4x2kq7bd"
  input project "p-abc12"
  input role "project-member"
  input statement "deploy-main"
  input issuer "github"
  input export-kubeconfig "true"
  input insecure-skip-tls-verify "false"
}

# request <n> prints the JSON of the n-th request in the mock log.
request() {
  sed -n "${1}p" "$MOCK_LOG"
}

request_count() {
  if [[ -e "$MOCK_LOG" ]]; then
    wc -l < "$MOCK_LOG"
  else
    echo 0
  fi
}

# output_value <name> prints the value of the output <name> in GITHUB_OUTPUT.
output_value() {
  sed -n "s/^$1=//p" "$GITHUB_OUTPUT"
}

# first_line_with <text> prints the first line of $output that contains the text. bats sets output
# in run.
# shellcheck disable=SC2154
first_line_with() {
  grep -F -m 1 -- "$1" <<<"$output"
}
