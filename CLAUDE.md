# CLAUDE.md

Orientation for Claude working on revtunnel. Read this first.

## What this is

TODO: what the project does, its main parts, and how they fit together.

## Layout

TODO: the important folders and files, one line each.

## Workflow

1. Start from the latest: pull before changing anything.
2. Make the change with tests.
3. **Update the docs in the same commit.** Every change updates the docs it
   affects:
   - README.md: setup and usage
   - CHANGELOG.md: an entry under *Unreleased*
   - DEPLOY.md: when deploying or running it live changes
   - SECURITY.md: when secrets, access or permissions change
   - this file: when the layout, workflow or conventions change
4. Run the checks (TODO: the lint and test commands), then commit.

## Conventions

TODO: coding style, naming, anything a newcomer would get wrong.

## Don't

- Commit secrets (`.env`, keys, tokens).
