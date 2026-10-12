# Security policy

## Reporting a vulnerability

Please report vulnerabilities privately through
[GitHub private vulnerability reporting](https://github.com/eldtechnologies/omarchy-plugin-govee/security/advisories/new),
not in a public issue.

Include the affected version or commit, what an attacker could do, and the
smallest reproduction you can. Leave out anything private: API keys, device
IDs, network addresses and light names.

We aim to acknowledge reports within a week. Fixes go to `main` and ship in
the next release.

## Supported versions

Only the latest release and `main` receive security fixes.

## Trust boundary

Omarchy plugins run as unsandboxed code inside the desktop shell, so review
the source before installing. In short, this plugin:

- talks only to `openapi.api.govee.com` over HTTPS with certificate checks,
  refuses redirects, caps the size of every answer, gives every run an
  overall time limit (rolling back a command that runs out of time), and
  sends the key nowhere else;
- talks to lights on your local network with Govee's LAN protocol, which has
  no authentication: anyone on your network can control those lights too,
  with or without this plugin, and can pretend to be a light. The plugin
  only accepts replies from a network this machine is directly on, one
  light per address; a light claimed from two addresses is not trusted on
  the LAN. Commands go only to the address a light replied from. It
  remembers at most 128 LAN-only lights, each for a month after it last
  answered, and at most 64 more from the scan in hand (`eld-govee forget`
  drops one, `--offline` all that are gone). It needs UDP port 4002 to
  itself: another program on it is reported as a local network error;
- never stores the API key in the shell: the panel hands it to the helper
  on stdin, which keeps it in your keyring. Only when the system has no
  keyring at all does it go to a file only you can read; a locked keyring
  or a dismissed prompt is an error, not a fallback. The key never appears
  on a command line;
- treats names and data from the cloud and the network as untrusted: IDs
  and models are validated before use, never used in a file path, and text
  is stripped of control characters and shown as plain text;
- writes only its own files under `~/.config/eld-govee` and
  `~/.local/state/eld-govee`, plus: the `~/.local/bin/eld-govee` link when
  installed with `install.sh` (never replacing a file that is not its own),
  and one Omarchy hook, `~/.config/omarchy/hooks/theme-set.d/eld-govee`,
  only while a light follows the theme. `uninstall.sh` removes both;
- installs no service or package and never uses `sudo`. When `ufw` blocks
  the lights' replies, it shows a firewall command for you to run.
