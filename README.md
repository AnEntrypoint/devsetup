# devsetup

How to build a dev machine the way AnEntrypoint's machines are built: one btrfs data drive for everything installed on purpose, shared toolchains, and sandboxed webtop desktops that share tools and, where we chose to, logins and history.

- Guide: https://anentrypoint.github.io/devsetup/ (source: `docs/index.html`)
- `setup/devsetup.sh`: menu-driven setup for a new machine (graphical dialogs on a desktop, terminal menus otherwise). `setup/answers.example.env` shows the answers file for unattended runs.
- `sandbox/`: the sandbox image definition (`Dockerfile`) and its start and stop scripts (`launch.sh`, `stop.sh`).

No credentials are in this repository. Each machine and each sandbox signs in to `gh`, `gcloud` and Claude Code itself, or copies the shared login described in the guide.
