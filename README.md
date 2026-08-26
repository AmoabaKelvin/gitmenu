# GitMenu

A macOS menu bar app for GitHub notifications. Native Swift, no Electron.

- Inbox with unread first, a "For you" view for mentions, review requests and assignments, and live lists of issues assigned to you and pull requests waiting on your review.
- Polls GitHub every 5 seconds with conditional requests, so new activity shows up within seconds of GitHub recording it.
- Thread view with a timeline of comments, reviews and events, rendered markdown, and @mentions that open profiles.
- System notifications with Open and Mark done actions; one banner per thread that updates in place.
- Octocat in the menu bar with the unread count. Launch at login.

## Requirements

- macOS 14 or later
- Xcode 26 and [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) to build

## Build and install

```sh
xcodegen generate
xcodebuild -project GitMenu.xcodeproj -scheme GitMenu -configuration Debug -derivedDataPath build build
rm -rf /Applications/GitMenu.app && cp -R build/Build/Products/Debug/GitMenu.app /Applications/
open /Applications/GitMenu.app
```

The project signs with a local identity named "GitMenu Dev". Create one in Keychain Access (Certificate Assistant > Create a Certificate, type Code Signing) or change `CODE_SIGN_IDENTITY` in `project.yml` to `-` for ad-hoc signing. Ad-hoc builds prompt for Keychain access after every rebuild.

## Sign in

Use a classic personal access token with the `notifications` and `repo` scopes. Fine-grained tokens and GitHub App tokens cannot read notifications.

To enable "Sign in with GitHub" (OAuth device flow), register an OAuth App with Device Flow enabled and set its client id:

```sh
defaults write com.kelvinamoaba.GitMenu oauthClientId <client id>
```

## How syncing works

The research behind these choices is in `docs/research.md`.

- `GET /notifications?all=true` every 5 seconds with `If-Modified-Since`. GitHub answers 304 (free) or only the threads updated since, read or not. Backs off for two minutes on a 403 or 429.
- Every 10 minutes a full walk lists everything not yet done plus the unread list, so threads read or done on GitHub or in another client are reconciled.
- Also syncs on wake, on network return, when the panel opens, and after each local action. Holds a `ProcessInfo` activity so App Nap does not throttle the timer.
- Changed threads are enriched in batches of 50 through one GraphQL query: state, review decision, checks, labels, and the last 12 timeline items.
- Assigned issues and review requests come from one GraphQL search every 20 seconds.
- Banners fire only for unread threads with new activity; more than 20 in one sync are suppressed.

## Debugging

- Log: `~/Library/Application Support/GitMenu/app.log`
- Store: `~/Library/Application Support/GitMenu/state-v4.json`
- Render the views to PNG without a display: `GitMenu.app/Contents/MacOS/GitMenu --snapshot <dir>`
