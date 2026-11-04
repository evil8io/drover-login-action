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

stop_mock() {
  if [[ -n "${MOCK_PID:-}" ]]; then
    kill "$MOCK_PID" 2>/dev/null || true
    wait "$MOCK_PID" 2>/dev/null || true
  fi
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
  unset DROVER_ISSUER DROVER_AUDIENCE DROVER_TTL DROVER_NAMESPACE DROVER_KUBECONFIG DROVER_EXPORT_KUBECONFIG
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
