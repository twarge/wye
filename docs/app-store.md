# App Store submission

How Wye gets from a commit to App Store review, for iOS (iPhone and iPad)
and macOS, and the answers App Store Connect asks for. The setup is the same
as Twarge's other apps: `.github/workflows/ci.yml` builds and tests every
push, and `.github/workflows/appstore.yml` archives, signs and uploads.

## Once: repository secrets

Settings ▸ Secrets and variables ▸ Actions, on the repository (or inherited
from the organization, where the other Twarge apps already have them):

| Secret | What it is |
| --- | --- |
| `ASC_KEY_ID` | App Store Connect API key ID (10 characters). |
| `ASC_ISSUER_ID` | App Store Connect issuer ID (a UUID). |
| `ASC_KEY_P8` | The contents of `AuthKey_<KEYID>.p8`, pasted as text, not base64. |
| `BUILD_CERTIFICATE_BASE64` | An Apple Development `.p12` for team 257KW9ZJFP, base64-encoded. |
| `P12_PASSWORD` | The password the `.p12` was exported with. |

The API key is made at App Store Connect ▸ Users and Access ▸ Integrations ▸
App Store Connect API, with the Admin role, which cloud signing needs. The
workflow checks the shape of each secret before using it and never prints
one.

Both workflows run on the `xcode-27` runner with Xcode 27.1 selected through
`DEVELOPER_DIR`; the repository must have access to that runner group.

## Once: the App Store Connect record

One app record serves both platforms (Universal Purchase), keyed on the
bundle ID both builds share.

1. Certificates, Identifiers & Profiles ▸ Identifiers: register the explicit
   App ID `com.twarge.app.wye`, and the identifiers its extensions need
   (next section). Cloud signing makes the profiles.
2. App Store Connect ▸ Apps ▸ New App: platforms **iOS** and **macOS**, name
   **Wye** (have a fallback such as "Wye Git" if the name is taken),
   primary language English (U.S.), bundle ID `com.twarge.app.wye`, a SKU
   such as `wye`, full access.
3. Pricing and Availability: free, all territories.
4. App Information: category **Developer Tools**, secondary
   **Productivity**. Content rights: the app shows no third-party content.
5. Fill in the answers below, the URLs, the description and the screenshots
   for each platform's version page.

## Once: extensions and the app group

The app carries four extensions, each with its own bundle ID under the app's:

| Target | Bundle ID | Platforms | What it is |
| --- | --- | --- | --- |
| WyeWidgets | `com.twarge.app.wye.widgets` | iOS, macOS | The Unpushed Changes and Repository widgets and the Fetch All control. |
| WyeShare | `com.twarge.app.wye.share` | iOS | Share sheet ▸ Clone in Wye. |
| WyeFiles | `com.twarge.app.wye.files` | iOS | The Wye location in the Files app (a File Provider extension). |
| WyeFinder | `com.twarge.app.wye.finder` | macOS | Badges on changed files and Open in Wye in the Finder (a Finder Sync extension). |

The app writes the repositories' status where the widget reads it, the
share extension leaves an address for the app, and the repositories shown
in the Files app live in the File Provider's storage, all through an app
group:

- iOS: `group.com.twarge.app.wye`, in `App/Wye-iOS.entitlements`,
  `Extensions/Widgets/Widgets-iOS.entitlements`,
  `Extensions/Share/Share.entitlements` and
  `Extensions/Files/Files.entitlements`. The Files extension also names it
  as `NSExtensionFileProviderDocumentGroup` in `Extensions/Files/Info.plist`:
  its storage is the group container's `File Provider Storage` folder.
- macOS: `257KW9ZJFP.com.twarge.app.wye`, the team-prefixed form, in
  `App/Wye.entitlements`, `Extensions/Widgets/Widgets-macOS.entitlements`
  and `Extensions/Finder/Finder.entitlements`.
  A sandboxed Mac app may use a group named after its team without a
  provisioning profile, which is what keeps `make build` working with no
  profile installed. (The `group.` form on the Mac needs a profile for every
  build, local ones included.) Both names are in
  `Sources/WyeShared/SharedContainer.swift`.

What the owner has to do once, in Certificates, Identifiers & Profiles:

1. Identifiers ▸ App Groups ▸ +: register `group.com.twarge.app.wye`
   (description "Wye").
2. Identifiers ▸ App IDs: register `com.twarge.app.wye.widgets`,
   `com.twarge.app.wye.share`, `com.twarge.app.wye.files` and
   `com.twarge.app.wye.finder` as explicit App IDs (platform iOS, macOS
   checked too for the widgets one; for the share and files ones iOS is
   enough; the finder one is macOS only and needs no capability, since
   the Mac's group needs no registration).
3. On each of the four App IDs (`com.twarge.app.wye`, `.widgets`,
   `.share`, `.files`), enable **App Groups** and choose
   `group.com.twarge.app.wye`. The files one needs no other capability:
   a File Provider extension is an ordinary app extension.
   The Mac's team-prefixed group needs no registration.
4. Nothing else changes: the extensions are embedded in the app, ship in
   the same archive and upload, and need no App Store Connect record of
   their own. Cloud signing (`-allowProvisioningUpdates` with the API key)
   makes their profiles once the identifiers exist; if it reports that a
   profile does not include the App Groups entitlement, the step above was
   missed for that identifier.

Local builds need none of this: `make build` signs the Mac app and its
widget with the development certificate and the team-prefixed group (the
Files and share extensions are iOS only and are not in the Mac build), the
Simulator needs no profile, and CI builds with `CODE_SIGNING_ALLOWED=NO`.
Building for a real iPhone or iPad from Xcode does need the identifiers
above (Xcode's automatic signing can register them itself when signed in
to the team).

Siri, Shortcuts and Spotlight need no setup: the App Intents (Pull, Fetch,
Push, Open, Get Status, Commit, Check Out, Stash for a repository, and
Fetch All, Pull All, Find Unpushed, Clone) are in WyeUI and reach the app's
`Metadata.appintents` through `AppIntentsPackage`, with the App Shortcuts
phrases ("Pull Horizontal in Wye"). The intents behind the widgets' buttons
and the control are in WyeShared, which the app and the widget extension
both take in the same way.

Background work on iOS needs only what `App/Info-iOS.plist` already has:
`com.twarge.app.wye.transfer.*` under `BGTaskSchedulerPermittedIdentifiers`
for the continued processing tasks that carry a clone, fetch, pull or push
on in the background, and `processing` under `UIBackgroundModes`.

## iCloud

Two things use the user's iCloud, both off until the user turns them on.

- **SSH keys in iCloud Keychain** (Settings ▸ SSH Keys). Needs nothing
  from the developer account: the keys are ordinary Keychain items marked
  to sync.
- **Settings sync** (Settings ▸ iCloud), through iCloud's key-value
  store. It is switched on in the build by three things, which go
  together:

  1. Certificates, Identifiers & Profiles ▸ Identifiers ▸
     `com.twarge.app.wye`: **iCloud** enabled (no container is needed for
     the key-value store).
  2. `App/Wye.entitlements` and `App/Wye-iOS.entitlements` carry

     ```xml
     <key>com.apple.developer.ubiquity-kvstore-identifier</key>
     <string>$(TeamIdentifierPrefix)$(CFBundleIdentifier)</string>
     ```

  3. `WyeSyncsSettingsWithICloud` is true in `App/Info-iOS.plist` and
     `App/Info-macOS.plist`, which is what shows the setting.

  A signed build therefore needs a provisioning profile that includes
  iCloud: `make build` fails with "doesn't include the iCloud capability"
  until Xcode, signed in to the team, has made one (or pass
  `-allowProvisioningUpdates` through `XCODE_FLAGS`). Unsigned builds
  (`CODE_SIGNING_ALLOWED=NO`) are unaffected.

## Each release

1. Bump `MARKETING_VERSION` in `Wye.xcodeproj/project.pbxproj` (the
   project's two configurations, which every target inherits so the app and
   its extensions always carry the same version), or leave it and give the
   version when running.
2. Either push a tag, `git tag v0.2.0 && git push origin v0.2.0`, or run
   **App Store** from the Actions tab (Run workflow), optionally with a
   version.
3. The workflow runs CI first (tests, and Release builds for macOS and the
   iOS Simulator), then for iOS and then macOS: checks the version is higher
   than the last approved one (`scripts/check-appstore-version.swift`),
   archives with build number `<run>.<attempt>`, and exports with
   `destination: upload`, which sends the build to App Store Connect. The
   archive, with its dSYMs, is kept as a workflow artifact for 90 days.
4. When the builds finish processing, choose them on each platform's version
   page (or in TestFlight), and submit for review.

A release can be reproduced locally with the same flags, given the API key:

```bash
make archive upload PLATFORM=iOS \
  XCODE_FLAGS='-authenticationKeyPath /path/AuthKey.p8 -authenticationKeyID ABC123 -authenticationKeyIssuerID 1234-...'
```

## Review notes

Paste into App Review Information ▸ Notes (no sign-in is needed, so leave
the demo account empty):

> Wye is a git client: it shows and edits git repositories, the folders
> developers keep source code in under version control. It has no account
> of its own and needs no sign-in.
>
> The app reads and writes only folders the user chooses. On the Mac that
> is through the Open panel (the app is sandboxed, with the user-selected
> read-write entitlement and security-scoped bookmarks so the repository
> list survives a relaunch). On iPhone and iPad it is folders picked in the
> Files picker, and repositories cloned or created in the app, which are
> kept in the app's own storage and shown in the Files app as the "Wye"
> location through the app's File Provider extension, so other apps can
> open and edit them in place. (Repositories from earlier versions are in
> the app's Documents folder, which the Files app also shows.)
>
> To try it: choose Clone, enter a public HTTPS repository URL such as
> REPLACE-WITH-A-SMALL-PUBLIC-REPOSITORY, and open it. The history, a
> commit's changes and the working copy can all be explored without any
> credentials. Pushing to a remote needs the user's own access token for
> that host, which is stored in the Keychain and sent only to that host.
> SSH remotes log in with an SSH key the user creates or imports in
> Settings ▸ SSH Keys, also kept in the Keychain.
>
> The app connects only to the git remotes the user configures, over HTTPS
> or SSH.
> It collects no data and contains no analytics or advertising. It is free
> and open source under the Apache License 2.0.

## Export compliance

`ITSAppUsesNonExemptEncryption` is `false` in both Info.plists, so App Store
Connect does not ask. That answer was written when the only encryption was
HTTPS through the system TLS stack and the Keychain: libgit2 is built
against Secure Transport with no crypto library of its own, and its SHA-1
and SHA-256 hashing is not encryption.

**SSH changes this, and the answer needs the owner's decision before the
next upload.** What is in the app now:

- The SSH protocol (key exchange, encrypted transport, public-key login) is
  implemented inside the app by swift-nio-ssh, Apple's open-source Swift
  package. libgit2 is still built without SSH, libssh2 or OpenSSL.
- Every cryptographic primitive it uses comes from the operating system's
  CryptoKit, through swift-crypto (which on Apple platforms only forwards to
  CryptoKit; its BoringSSL copy is not compiled): AES-GCM, Curve25519 and
  NIST-curve ECDH, Ed25519 and ECDSA signatures, SHA-2.
- One algorithm is the app's own: bcrypt_pbkdf (on a small Blowfish), used
  only to decrypt a passphrase-protected private key file the user imports.
  AES-CTR for that comes from the system's CommonCrypto.
- All of it is standard, published algorithms in a standard protocol, in a
  free, open-source, mass-market app.

Apple's exemption for apps whose encryption is "limited to that within the
operating system" plainly covered HTTPS through the system. Whether an SSH
implementation in the app, built on the system's primitives, still falls
under it is not clear-cut, so this was left unchanged rather than decided
here. To re-check in App Store Connect (App Information ▸ App Encryption
Documentation, or the questions it asks when the key is removed):

1. "Does your app use encryption?" — yes, now beyond HTTPS.
2. Whether it qualifies for an exemption: either the operating-system one,
   or, if not, the one for standard encryption in a mass-market product;
   open-source publication may also bear on it. If the answer is that it
   is exempt, `false` can stay; if not, set the key to `true` and file
   what App Store Connect asks for (and check whether the French
   declaration applies for distribution in France).

This is not legal advice; Apple's "Complying with Encryption Export
Regulations" page and the BIS rules are the references.

## App Privacy

App Store Connect ▸ App Privacy: **Data Not Collected**. Wye has no server;
what it reads stays on the device except what the user pushes to their own
remotes, which is the app's function and not collection. No tracking.

`App/Resources/PrivacyInfo.xcprivacy`, in both bundles, says the same and
declares the required-reason APIs the app and its compiled-in libgit2 use:

| Category | Reason | Why |
| --- | --- | --- |
| File timestamp | 3B52.1, C617.1 | libgit2 compares working-tree files' times with the index; files are in user-chosen folders or the app container. |
| System boot time | 35F9.1 | libgit2's monotonic clock (`mach_absolute_time`) times progress and seeds its random numbers. |
| User defaults | CA92.1 | SwiftUI scene storage and the app's own preferences. |

A privacy policy URL is still required: a short page saying the above.

## Age rating

Answer **None** or **No** to every question: no violence, mature themes,
gambling, contests, unrestricted web access, user-generated content shared
between users, or messaging. The result is 4+ (and the equivalent on every
platform).

## Still needed

- **App Privacy**: with settings sync or SSH keys in iCloud Keychain
  turned on, the user's own data goes to the user's own iCloud. Neither
  reaches the developer, so the answers above stand; say so in the review
  notes if asked.
- **Apple Intelligence**: drafting a commit message runs on the device
  with the system's model and sends nothing anywhere.

- **Screenshots**, made from the app:
  - iPhone 6.9" display: 1320 × 2868 (or 1290 × 2796), portrait, 1–10.
  - iPad 13" display: 2064 × 2752 (or 2048 × 2732), 1–10.
    `docs/images/ipad-history.png` is a start.
  - Mac: 16:10, 2880 × 1800 (or 2560 × 1600, 1440 × 900, 1280 × 800), 1–10.
- **Description, keywords, promotional text** for each platform.
- **Support URL** and **privacy policy URL**; a marketing URL is optional.
- **Copyright** line: "2026 Twarge LLC".
- A small public repository to name in the review notes.
