# Local cutover

The new project is `orc.nvim`; its sole CLI is `orc`. The old source repository
is kept unchanged as historical source, without a runtime compatibility bridge.

1. Pass the offline suite, all three coverage gates, generated-agent freshness and
   formatting checks.
2. Confirm the CLI resolves its modules through a symlink and works from another
   directory without loading personal Neovim configuration.
3. Smoke-test Rex using a dedicated temporary session and harmless commands. Verify
   create, process exit, event/snapshot reads and ownership-safe cleanup. Live
   harness dialogs and model runs remain explicit checks.
4. Put the new absolute `bin` directory ahead of the npm-installed `orc` in PATH.
   Update fish wrappers/completions and load the local Neovim plugin checkout.
5. Replace the old enabled harness plugin with the new local plugin registration.
   Restart agent sessions and approve new/changed hooks through normal harness
   trust controls. Do not bypass hook trust.

The dotfiles removal includes semantic-search skills/routing and the Neovim
CocoIndex plugin, keymaps and statusline. Binary installations, private indexes,
cache files and external source checkouts are left alone. Ignore patterns that
protect private indexes remain in place.

Local installation must work before any remote repository exists. Publishing,
pushes and marketplace installation from GitHub are separate actions; do not
point an active configuration at a remote that has not been created.

Approved lessons and user documents are not rewritten during cutover. Old live
workers are not adopted automatically; finish or close those sessions explicitly.
