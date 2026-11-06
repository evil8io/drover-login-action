# Contributing

## Layout

```
action.yml              the composite action, which runs scripts/login.sh
scripts/login.sh        the login, the token request, and the kubeconfig
tests/login.bats        the bats tests of the script
tests/helpers.bash      the shared setup of the tests
tests/mock/server.py    a mock of the GitHub OIDC endpoint and of OpenBao
```

## Tools

Mise installs the tool versions in `mise.toml`. Run `mise install`. The tests also need `python3` for the mock server, `curl`, `openssl` for the test certificates, and the GNU coreutils.

## Checks

Run these checks before a commit:

1. `mise run lint`
2. `mise run test`

CI runs the same checks on every pull request. For a pull request from this repository, CI also runs the action itself in the job `action`, with a real OIDC token, against the mock server.

## Pull requests

Write the pull request title in the [Conventional Commits](https://www.conventionalcommits.org/) format. The workflow `pr-title` checks the title. Every pull request is squash-merged, and the title becomes the commit subject on `main`. Add a `!` after the type for a breaking change.

Per the ruleset on `main`, GitHub requires the checks `check`, `action`, and `lint`. You can merge a pull request after these checks pass.

## Releases

[release-please](https://github.com/googleapis/release-please) reads the commit subjects on `main` and opens a release pull request. After the maintainer merges that pull request, release-please creates a tag and a GitHub release. The repository does not have a 1.0 release yet. With the option `bump-minor-pre-major`, release-please thus raises the minor version for a breaking change.

GitHub does not run the required checks on the release pull request. The reason is in `CLAUDE.md`. The maintainer merges the release pull request with `gh pr merge --admin`.

The release workflow moves the tag `v0` to the newest release. You can thus use the action in a workflow as `evil8io/drover-login-action@v0`.
