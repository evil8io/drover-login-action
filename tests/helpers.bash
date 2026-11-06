# This file contains the shared setup of the bats tests.

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

# Starts a second mock server that answers HTTPS, with the certificate of make_certificates. The
# server writes to the same log as the server of start_mock.
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

stop_mock() {
  local pid
  for pid in "${MOCK_PID:-}" "${MOCK_TLS_PID:-}"; do
    if [[ -n "$pid" ]]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
}

# Writes a test CA and a server certificate for 127.0.0.1, signed by that CA, to the directory
# TLS_DIR. The files are ca.pem, server.pem, and server.key.
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

# Writes the mock config. The argument is a JSON document.
mock_config() {
  echo "$1" > "$MOCK_CONFIG"
}

# Prepares the environment of a run of the script, as in a composite step of the action.
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
  export DROVER_OPENBAO_URL="$MOCK_URL"
  export DROVER_RANCHER_URL="https://rancher.example.com/"
  export DROVER_CLUSTER="c-m-4x2kq7bd"
  export DROVER_PROJECT="p-abc12"
  export DROVER_ROLE="project-member"
  export DROVER_STATEMENT="deploy-main"
  unset DROVER_ISSUER DROVER_AUDIENCE DROVER_TTL DROVER_NAMESPACE DROVER_KUBECONFIG DROVER_EXPORT_KUBECONFIG \
    DROVER_CA_CERTIFICATE DROVER_INSECURE_SKIP_TLS_VERIFY
}

# Puts a jq wrapper and a curl wrapper in front of PATH. Each wrapper fails when an argument
# contains a token. The mock JWT and the ServiceAccount token start with eyJ. The OpenBao token
# starts with hvb.
guard_command_lines() {
  local dir="$BATS_TEST_TMPDIR/bin" tool real
  mkdir -p "$dir"
  for tool in jq curl; do
    real=$(command -v "$tool")
    cat > "$dir/$tool" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    *eyJ* | *hvb.*)
      echo "a token is on the command line of $tool" >&2
      exit 99
      ;;
  esac
done
exec "$real" "\$@"
EOF
    chmod +x "$dir/$tool"
  done
  export PATH="$dir:$PATH"
}

# request <n> prints the JSON of the n-th request in the mock log.
request() {
  sed -n "${1}p" "$MOCK_LOG"
}

# request_count prints the number of requests in the mock log.
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
