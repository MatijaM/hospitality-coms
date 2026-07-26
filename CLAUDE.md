# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Status: empty repository

As of the initial commit, this repo contains only `README.md` and `.gitignore`. There is no `mix.exs`, no source, no tests, and no build tooling yet.

Do not infer commands or architecture from this file — there is nothing here to infer them from. Read the actual tree before acting.

## What is known

- **Purpose** (from README): a communications platform for hospitality businesses.
- **Intended stack**: Elixir. The `.gitignore` is the unmodified output of `mix new` (`/_build`, `/deps`, `/doc`, `/.fetch`, `*.beam`, `*.ez`, `/config/*.secret.exs`, `.elixir_ls/`). Notably it does *not* include the Phoenix additions (`/priv/static/assets/`, `/assets/node_modules/`), so a plain Mix project is the closer match to what was set up — confirm with the user before assuming Phoenix.
- **Secrets convention**: `config/*.secret.exs` is git-ignored, so runtime secrets are expected to live there (or in env vars) rather than in tracked config.

## When the project is scaffolded

Regenerate this file once `mix.exs` and a source tree exist. At that point it should document the real build/test/lint commands (including how to run a single test), the OTP application and supervision tree layout, and whatever domain boundaries the code actually establishes.
