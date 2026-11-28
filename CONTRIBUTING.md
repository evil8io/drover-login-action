# Contributing

## Tools

Run `mise install`. The tests also need `python3`, `openssl`, and the GNU coreutils.

## Build

Run `mise run build`. Then commit `dist/` together with the change in `src/`.

## Pull requests

Write the pull request title in the [Conventional Commits](https://www.conventionalcommits.org/) format. GitHub squash-merges each pull request, so the title becomes the commit subject on `main`. release-please builds the version and the changelog from these subjects.
