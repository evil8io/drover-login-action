# CLAUDE.md

drover-login-action is a composite GitHub action. `README.md` is for human readers. This file contains only what the code does not show: rules, invariants, gotchas, external constraints, and wiring.

Write a rule in the imperative. Give the reason for the rule. Delete a line when it is no longer useful.

## Public repository

This repository is public. Do not write these names or IDs anywhere:

- a customer name
- an environment name
- the name of a private repository
- the name of an internal tool
- an issue tracker ID

This rule applies to code, comments, tests, commit messages, branch names, and pull request text. Link the issue to the pull request by hand, from the tracker side. The pull request text then does not contain the issue tracker ID.

## Wiring

- Keep the logic in `scripts/login.sh`. The runner does not set `INPUT_*` variables for a composite action (GitHub docs, page "Metadata syntax for GitHub Actions"). We thus pass each input to the script as a `DROVER_*` variable, in the `env` block of `action.yml`. shellcheck and bats check the script. Neither tool checks a `run` block of `action.yml`.
- Put every token in a curl config file or in a request body file. Do not put a token on the command line of a process, because `ps` on a shared runner shows the command line of every process. In a jq call, read a token from the response file. Do not pass a token to jq with `--arg`. bats checks this rule in the test "keeps every token off the command lines of jq and curl", with a wrapper for jq and a wrapper for curl.
- Check each token against the token alphabet before you write the token into a curl config file. The token alphabet is A-Z, a-z, 0-9, `.`, `_`, and `-`. When a token from a bad server contains a `"` or a newline, the server can add an option to the curl config file, for example a `data-binary` option with the environment of the process.
- Mask each token with `::add-mask::` before the first line of the log that can contain the token. Turn xtrace off in the first command of the script. A caller can turn xtrace on through `SHELLOPTS` or `BASH_ENV`. Bash then prints a token in the trace before the mask line of the token.
- Call curl with `-q` as the first argument, so that curl does not read a curlrc of the runner. On a persistent runner, an earlier job can write a curlrc with a trace option. curl then writes every request, with the tokens, to a file.
- Write the work files of the script under `umask 077`, in a directory that the trap of the script removes at exit, because the files contain the tokens. Write the kubeconfig to a new file. Then move the new file onto the path of the kubeconfig. When bash redirects output onto an existing file, bash keeps the mode of that file. Bash also follows a symlink at that path.
- Write the kubeconfig as JSON with jq, so that a value does not need YAML quoting. kubectl and helm read a JSON kubeconfig.
- Use the inputs `ca-certificate` and `insecure-skip-tls-verify` only for the requests to OpenBao and for the cluster of the kubeconfig. The OIDC token endpoint belongs to GitHub, not to the platform of OpenBao and Rancher. With `cacert`, curl uses the private CA instead of its default CA file (curl man page, option `--cacert`), so the request to GitHub can fail. With `insecure`, curl sends the request token of the job without a check of the certificate of GitHub.
- Remove every CR character from `ca-certificate` before the check. Also remove the white space at the start and at the end of the value. When kubectl decodes PEM data, it removes a CR only before a newline (`getLine` in `encoding/pem/pem.go` of Go). When the value ends with a CR after the last END line, kubectl thus refuses the kubeconfig. A caller can pass an empty variable in a YAML block scalar, and the input is then one newline.
- Fail when the caller sets both `ca-certificate` and `insecure-skip-tls-verify`. kubectl and helm refuse a kubeconfig with both. The error `specifying a root certificates file with the insecure flag is not allowed` is in `transport/transport.go` of `kubernetes/client-go`. Without the check, the action writes a kubeconfig that kubectl refuses at the first command of the job.
- Do not add a `post` step to the action. On the GitHub docs page "Metadata syntax for GitHub Actions", `runs.post` is in the section for JavaScript actions only. A single ServiceAccount token from a TokenRequest cannot be revoked, so a post step cannot clean up the token. To revoke every token of a ServiceAccount, an admin deletes the ServiceAccount (drover, `docs/project-sync.md`).
- Use curl in the script for the login and for the token request. OpenBao accepts only POST on the creds endpoint of the Kubernetes secrets engine. For a GET, OpenBao returns HTTP 405 `unsupported operation`. We verified this on OpenBao 2.7. `src/secrets.js` of `hashicorp/vault-action` contains only `client.get` calls, so that action cannot request the token.
- These paths and names are conventions of drover. When the action and drover use different values, OpenBao refuses the login or the token request. Change them only together with drover:
  - the auth path `auth/jwt/<issuer>`,
  - the login role `<cluster>_<project>_<statement>`,
  - the mount prefix `kubernetes`, the default of the drover flag `--openbao-mount-prefix`,
  - the token role `<project>-<role>`,
  - the account namespace `drover-<cluster>-<project>`.

## Tests

- `tests/mock/server.py` is the specification of the requests. When you change a request path, a header, or a body, also change the mock and the bats tests.
- To change the answers of the mock after the server start, write the file `MOCK_CONFIG` in the test. The mock server reads `MOCK_CONFIG` at each request.
- In the tests, give Rancher a different host from OpenBao. A test then fails when the script mixes up the two URLs. The script does not contain a request to Rancher.
- The CI job `action` runs the action with a real OIDC token. GitHub does not give an OIDC token to a workflow run for a pull request from a fork, so the job runs for a pull request from this repository only. The mock server records the claims of the JWT. The step "Check the outputs" then compares the `aud` claim and the `repository` claim with the expected values.

## Releases

- On a release-please pull request, GitHub shows a failed `ci` run and a failed `pr-title` run, each with zero jobs. The release-please bot is an outside actor. For this reason, GitHub gives the runs the status `action_required`. When the runs expire, GitHub changes the status to `failure`. Ignore these failed runs. The `ci` run on `main` must pass.
- The required checks of the ruleset `main` thus never pass on the release pull request. Merge the release pull request with `gh pr merge --admin`. GitHub lets the admin role bypass the ruleset for a pull request.
- Before 1.0, release-please bumps the minor version for a `feat!` commit, because it runs with `bump-minor-pre-major`. In the release workflow, `gh api` moves the tag `v0` to each release, also across a breaking change. The README contains a note about this for the users.
