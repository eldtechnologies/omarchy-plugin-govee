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
  refuses redirects, and sends the key nowhere else;
- talks to lights on your local network with Govee's LAN protocol, which has
  no authentication: anyone on your network can control those lights too,
  with or without this plugin;
- keeps the API key out of the shell process, in your keyring (or a file only
  you can read when no keyring is available), and passes it on stdin, never
  on a command line;
- treats names and replies from the cloud and the network as untrusted:
  device IDs are validated, text is stripped of control characters, and
  commands only go to the address a light replied from;
- installs no service, runs no code at install time, and never uses `sudo`
  (it shows a firewall command for you to run).
