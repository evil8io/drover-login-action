# CLAUDE.md

Add only a rule that the code does not show, with its reason. A copy of a code fact goes stale.

## Public repository

Do not write a customer name, an environment name, a private repository name, an internal tool name, or an issue tracker ID. Also keep them out of commit messages, branch names, and pull request text. This repository is public.

## Build

- Do not mark `dist/` as `linguist-generated` in a `.gitattributes` file. GitHub then hides the diff of `dist/` in a pull request. A reviewer must read that diff, because the author of the same pull request can also change the job `check`.
- Do not add a runtime dependency to `package.json`. Node runs the code of such a package in the process that has the tokens of the action.
- Add a development package only when the build needs it. With a bad release of a development package, an attacker can change `dist/`, the code that the runner starts.

## Wiring

- Pass each text from a server through `oneLine()` before the action prints it. With a line break, a server can add a workflow command to the log.
- Change the OpenBao paths, the login role, and the account namespace in `src/main.ts` only together with drover. drover uses the same paths and names. With other values, OpenBao refuses the login or the token request.

## Releases

- On a release-please pull request, GitHub shows a failed `ci` run and a failed `pr-title` run, each with zero jobs. The release-please bot is an outside actor. For this reason, GitHub gives the runs the status `action_required`. When the runs expire, GitHub changes the status to `failure`. Ignore these failed runs. The `ci` run on `main` must pass.
- The required checks of the ruleset `main` thus never pass on the release pull request. Merge the release pull request with `gh pr merge --admin`. GitHub lets the admin role bypass the ruleset for a pull request.
- Before 1.0, release-please bumps the minor version for a `feat!` commit, because it runs with `bump-minor-pre-major`. In the release workflow, `gh api` moves the tag `v0` to each release, also across a breaking change. The README contains a note about this for the users.
