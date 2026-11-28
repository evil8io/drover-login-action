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

- Approve or rerun the `ci` run and the `pr-title` run of a release-please pull request before the merge. For a pull request from a workflow with `GITHUB_TOKEN`, the events "create workflow runs that require approval" (GitHub docs, page "Events that trigger workflows"). The required checks pass only after these runs.
- When the `ci` run of a release commit on `main` fails, rerun that run. release-please creates the release only after that run passes. Until then, release-please also does not open the next release pull request.
- Do not treat a failed run with zero jobs on a merged release pull request as a CI failure. When a release pull request is merged before the approval, GitHub ends its runs with `failure`.
