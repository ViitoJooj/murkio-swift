# Murkio identity for iOS and macOS

Murkio identity for apps written with SwiftUI (iOS 15+, macOS 12+). With **only the
publishable key** your app gets:

- `MurkioIdentityCanvas`: the login screen designed in the Murkio dashboard, drawn with
  native SwiftUI, running the whole sign-in (signup, email code, two-step verification,
  password reset, social sign-in);
- `MurkioIdentityEmailInput`, `MurkioIdentityPasswordInput`, `MurkioIdentityKeepLogged`,
  `MurkioIdentityLoginButton` and `MurkioIdentityRegisterButton`: the same sign-in with
  your own layout and style;
- the session: stored in the Keychain, refreshed on its own, and an access token ready
  for your API.

The package has no dependencies.

## Install

In Xcode: File › Add Package Dependencies, with the URL of this repository. In a
`Package.swift`:

```swift
.package(url: "https://github.com/ViitoJooj/murkio-swift.git", branch: "master")
```

## Quick start

Declare the key in your app's `Info.plist`:

```xml
<key>MurkioPublishableKey</key>
<string>pk_...</string>
```

and draw the canvas:

```swift
import MurkioIdentity
import SwiftUI

struct RootView: View {
    @StateObject private var auth = MurkioAuth()

    var body: some View {
        if auth.session == nil {
            ScrollView { MurkioIdentityCanvas() }
        } else {
            HomeView()
        }
    }
}
```

That is the whole integration. The SDK reads the key the first time it is used, restores
the session of the last run, and the canvas is whatever was published in the dashboard
(the default one until then).

To set it up in code instead, or to pass more options, call it when the app starts:

```swift
Murkio.configure(publishableKey: "pk_...", locale: "pt-BR")
```

## The canvas

```swift
MurkioIdentityCanvas(
    screen: .signIn,                  // or .signUp
    locale: "pt-BR",                  // default: the device's language
    onLogin: { session in },          // the user is signed in
    onError: { error in },            // error.code is the API code (rsb-00...)
    onStep: { step in },              // verify_email, mfa, mfa_enroll, recovery_codes, forgot, reset
    onLink: { href in }               // a link of the canvas was tapped
)
```

- It takes the width it is given and is as tall as its layout: put it in a `ScrollView`.
- The layout follows the **width of its container**, exactly like the web SDK: the
  desktop layout down to 75% of its width, then the mobile layout, then a stacked column.
  One canvas pixel is one point; boxes scale with the frame and fonts keep the size chosen
  in the editor.
- The canvas is validated again on the device before it is drawn. A published canvas that
  can no longer sign anybody in gives way to the default one.
- `preview: json` draws a canvas document without the API (editors, Xcode previews).
- A link to a site path (`/terms`) has no site to open in an app: handle it in `onLink`.
  Without `onLink`, https links open in the browser.

The email code, two-step verification, authenticator setup, recovery codes and password
reset screens are built in and follow the canvas colors and font.

## Your own form

```swift
VStack {
    MurkioIdentityEmailInput("Email")
        .textFieldStyle(.roundedBorder)
    MurkioIdentityPasswordInput("Password")
        .textFieldStyle(.roundedBorder)
    MurkioIdentityKeepLogged("Keep me signed in")
    MurkioIdentityError()
    MurkioIdentityLoginButton("Sign in", onLogin: { session in })
        .buttonStyle(.borderedProminent)
    MurkioIdentityRegisterButton { Label("Create account", systemImage: "person.badge.plus") }
}
```

They are the regular SwiftUI controls (`TextField`, `SecureField`, `Toggle`, `Button`), so
every modifier you already use styles them. The views of a screen share one form, so they
can sit anywhere in your layout, and the built-in screens (email code, 2FA, …) open in a
sheet painted with the canvas theme.

To drive the flow from your own controls, use the form directly:

```swift
@ObservedObject var form = MurkioForm.shared()

TextField("Email", text: $form.email)
SecureField("Password", text: $form.password)
Button("Sign in") { Task { await form.login() } }
    .disabled(form.state.busy)
    .murkioSteps(form)     // shows the built-in screens
```

`MurkioIdentityForm { form in … }` gives a group its own form (two forms on one screen,
or `onLogin` / `onError` in one place).

## The session

```swift
let client = Murkio.client

client.isSignedIn                          // right now
client.observeSession { session in }       // sign-ins, sign-outs and refreshes
let token = try await client.getToken()    // a valid access token, or nil
let user = try await client.getUser()      // email, roles, 2FA (cached for a minute)
await client.signOut()
```

Send the token to your API as `Authorization: Bearer <token>`; your backend verifies it
with a Murkio server SDK.

- The tokens live in the Keychain, one item per publishable key, readable after the first
  unlock of the device and never leaving it (no iCloud sync, no restore on another phone).
- The access token is renewed 90 seconds before it expires while the app is in the
  foreground, when the app comes back to it, and by `getToken()` whenever needed. Calls
  that happen at the same time share one request, and that request is not cancelled with
  its caller: the refresh token rotates on every use, and losing the answer would end the
  session.
- Offline, the session is kept and `getToken()` throws a `MurkioError` with the code
  `network`. Only the API saying the session is over signs the user out.
- **"Keep me signed in" off** means the session ends with the app: the next start logs it
  out. A canvas (or form) **without** that control keeps the session, which is what people
  expect from an app.

## Social sign-in

A provider sends the user back to an **https** link registered in the application's
redirect URLs. In an app that link is a
[Universal Link](https://developer.apple.com/documentation/xcode/supporting-universal-links-in-your-app)
that opens your app:

```xml
<key>MurkioOAuthRedirectURL</key>
<string>https://app.example.com/auth/callback</string>
```

and the app gives the link to the SDK:

```swift
WindowGroup {
    RootView()
        .onOpenURL { url in Task { await Murkio.client.handleRedirect(url) } }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            if let url = activity.webpageURL { Task { await Murkio.client.handleRedirect(url) } }
        }
}
```

`handleRedirect` returns `false` for a link that is not the answer to a sign-in this app
started. Without the redirect URL the canvas hides the social buttons: a button with
nowhere to come back to is not shown.

## Errors and languages

Every failure is a `MurkioError`: `code` is the API code (`rsb-00`, `rag-06`…), `network`
when there was no answer, `unknown` otherwise. `error.localized("pt-BR")` is the message
for the user; the canvas and `MurkioIdentityError` already show it. English and Brazilian
Portuguese are built in; any other language falls back to English, and the texts of the
canvas itself come translated from the dashboard.

## Options

| `Info.plist` | `Murkio.configure` | |
|---|---|---|
| `MurkioPublishableKey` | `publishableKey` | the application's `pk_...` key (required) |
| `MurkioAPIURL` | `apiURL` | the identity API, when it is not the default |
| `MurkioOAuthRedirectURL` | `oauthRedirectURL` | the Universal Link of the social sign-in |
| | `locale` | language of the built-in screens |
| | `storage` | a `MurkioStorage` of your own |
| | `transport` | a `MurkioTransport` of your own (a test double…) |

## Developing

This repository is a git submodule of the Murkio identity service
(`libs/external/swift`), and the commands below run from that checkout.

```sh
swift build
swift test
```

Everything except the SwiftUI views and the Keychain also builds and runs on Linux, which
is where the core is tested on every change: it runs the vectors and fixtures in
`libs/spec` that every Murkio client SDK shares (the web SDK runs the same ones), so the
canvas is laid out and the flows behave like on the web. On macOS the tests also lay the
canvas out in a real SwiftUI pass and compare every box, and exercise the Keychain.
`Generated/Spec.swift` comes from `node libs/scripts/sync-client-spec.mjs`. Set
`MURKIO_LIVE_API`, `MURKIO_LIVE_PK`, `MURKIO_LIVE_EMAIL` and `MURKIO_LIVE_PASSWORD` to also
run `LiveTests` against a real API, and `MURKIO_SCREENSHOTS=<dir>` (macOS) to render the
canvas to a PNG.
