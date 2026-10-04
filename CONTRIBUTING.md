# Contributing

NozzleCast is an iOS companion app for one specific stack — a self-hosted
[Bambuddy](https://github.com/karliky/bambuddy) server, optionally with push delivered through
[nozzlecast-relay](https://github.com/hibikipr/nozzlecast-relay). It's shared publicly in case
it's useful to others running the same setup, so PRs that add config surface or backends this
project doesn't target are likely to be declined in favor of keeping it simple — but bug fixes,
docs improvements, and features that fit the existing scope are welcome.

For anything bigger than a small fix, open an issue first so we can agree on the approach before
you spend time on it.

## Before you start

Read [ARCHITECTURE.md](ARCHITECTURE.md) first — it covers how the app, the notification service
extension, and the widget extension talk to each other, and the reasoning behind the app's design
decisions (including deliberate non-features listed in the [README](README.md#notable-non-features)).

## Setup

- Xcode with the iOS 26 SDK (the app's deployment target is iOS 26.0).
- Open `NozzleCast.xcodeproj` and run the `NozzleCast` scheme. You'll need to pick your own
  development team under Signing & Capabilities for each of the three targets.
- No Bambuddy server is required to run the app — without one configured it shows demo data. To
  test against a real server, see the README's [Getting started](README.md#getting-started).

## Tests

Shared logic lives in the `NozzleCastShared` Swift package and is unit-tested there:

```bash
cd NozzleCastShared
swift test
```

The App Store Connect metadata tooling under `fastlane/` has its own Ruby tests:

```bash
cd fastlane
bundle install
bundle exec rake
```

## Making a change

- Add or update tests in `NozzleCastShared/Tests/` for any behavior change in shared logic.
- Keep changes scoped: a bug fix doesn't need a refactor alongside it.
- If a change affects how the targets interact, the push/Live Activity flow, or a documented
  design decision, update [ARCHITECTURE.md](ARCHITECTURE.md) in the same PR — it's meant to stay
  accurate, not drift from the code.
- Server URLs, API keys, and `GoogleService-Info.plist` are entered in the app at runtime and
  stored in the Keychain. Never commit real credentials, hostnames, API keys, `.p8` keys, or
  Firebase config files.
- Don't change files under `fastlane/metadata_config/` — that's the App Store listing, and
  changes there are pushed to App Store Connect on merge.

## Pull requests

- Branch from `main` and open the PR against `main`. Direct pushes to `main` are blocked.
- Describe what changed and why, and how you tested it (device/simulator, iOS version, Bambuddy
  version if relevant). Screenshots help for any UI change.

## Reporting security issues

Please don't open a public issue for a vulnerability — see [SECURITY.md](SECURITY.md).

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
