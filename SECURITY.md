# Security Policy

## Reporting a vulnerability

Please report security issues privately through GitHub's
[private vulnerability reporting](https://github.com/hibikipr/NozzleCast/security/advisories/new)
rather than opening a public issue.

Include what you found, how to reproduce it, and which app version it affects (shown at the bottom of Settings).
You should get an acknowledgement within a few days.

## Scope

NozzleCast talks only to servers you configure — your own Bambuddy server and, optionally, your
own ntfy/Firebase push setup. Issues in the app itself are in scope, for example:

- API keys or server URLs leaking out of the Keychain (into logs, UserDefaults, backups, or
  notification payloads).
- The app or its extensions trusting data from a server or push payload in an unsafe way.

Vulnerabilities in Bambuddy, ntfy, or Firebase themselves should be reported to those projects.
For the push relay, see [nozzlecast-relay](https://github.com/hibikipr/nozzlecast-relay).

## Supported versions

Only the latest App Store release receives fixes.
