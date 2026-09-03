# App Store Connect metadata — NozzleCast

Draft copy for the App Store Connect listing form. Character counts noted
against Apple's actual field limits — trim before pasting if you edit.

## App name (30 char max)
```
NozzleCast
```
10/30.

## Subtitle (30 char max)
```
Bambuddy printer monitoring
```
28/30. Shows right under the name in search/on the product page.

## Promotional text (170 char max, editable anytime without a new build)
```
Live Activities for your Bambu printers — real progress, real ETA, and
HMS alerts on your Lock Screen, driven by your own self-hosted Bambuddy
server.
```
159/170.

## Description (4000 char max)
```
NozzleCast is a companion app for Bambuddy, the self-hosted management
server for Bambu Lab 3D printers. Connect it to your own Bambuddy
instance and monitor every printer on your farm — no cloud account,
no subscription, no data leaving your own network.

LIVE ACTIVITIES THAT ACTUALLY UPDATE
Start a print and NozzleCast puts a Live Activity on your Lock Screen
and in the Dynamic Island — even if the app isn't open and your phone
is locked. It shows real progress (not a rough estimate), a localized
finish time, live temperatures, and the cover image or camera snapshot
for the job, and keeps updating for the entire print.

KNOW WHEN SOMETHING NEEDS ATTENTION
A color-coded badge — yellow for a warning, red for an error — appears
the moment Bambuddy reports an HMS issue serious enough to matter,
matching the same severity Bambuddy's own dashboard shows. No more
guessing whether "Paused" means a filament runout or nothing at all.

YOUR WHOLE FARM AT A GLANCE
The Monitor tab shows every printer's state, job, progress, and AMS
filament colors at once. Tap in for full detail: temperatures, print
controls, and per-slot filament info.

FILAMENT INVENTORY, NOT GUESSWORK
Track every spool — material, color, brand, remaining weight, and
whether it's loaded in an AMS or sitting in storage. Scan a spool's
barcode or printed label with your camera to add it in seconds,
entirely on-device.

BUILT FOR SELF-HOSTERS
NozzleCast talks directly to your Bambuddy server's API. Live
Activity push updates go through a small relay you run yourself
(nozzlecast-relay, open source). There is no NozzleCast account and
no NozzleCast server in between — your printer data stays on your
own infrastructure.

Requires an existing Bambuddy server on your network. Live Activities
and Lock Screen push updates require the optional nozzlecast-relay
component.
```
~1,750/4000.

## Keywords (100 char max, comma-separated, no spaces needed but kept for readability)
```
bambu,3d printing,bambuddy,3d printer,filament,ams,print farm,live activity,x1c,p1s,a1,octoprint
```
97/100.

## What's New in This Version (4000 char max) — first release
```
Initial release: live printer monitoring, Lock Screen Live Activities
with real progress and ETA, HMS severity alerts, filament inventory
with camera scanning, and multi-printer support.
```

## Support URL
```
TODO — a page or repo README where users can file issues (e.g. the
nozzlecast-relay or NozzleCast GitHub repo's Issues tab)
```

## Marketing URL (optional)
```
TODO — leave blank if there's no landing page
```

## Privacy Policy URL
```
https://claude.ai/code/artifact/16b1e460-2126-40b9-804d-5095b41c16a7
```
Source lives at `privacy-policy.html` in this folder. To edit: change
that file, then republish it as an Artifact from this project to keep
the same URL live.

## Category
```
Primary: Utilities
Secondary: Productivity
```

## Age Rating
```
4+ — no objectionable content. Answer "No" to every content question
in App Store Connect's questionnaire.
```

## Copyright
```
© 2026 Victor Manuel
```
Confirm this is the legal name/entity you want on file — App Store
Connect uses this verbatim.

## App Privacy (Data Collection) questionnaire
Answer **"Data Not Collected"** for every category. NozzleCast has no
first-party server — everything it touches is either kept on-device
(Keychain) or sent only to servers the user configures themselves
(their Bambuddy instance, their nozzlecast-relay, their own Firebase
project). None of that is *collected by the developer*, which is what
this questionnaire asks about. See `privacy-policy.html` for the
full, precise breakdown if Apple's review team asks for detail.
