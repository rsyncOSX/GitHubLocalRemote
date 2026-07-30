# Git Branch Status

A native macOS app that scans a folder of local projects and compares every
local branch with the corresponding branch on GitHub.

## What it shows

- **Local ahead** — the local branch contains commits not on GitHub.
- **In sync** — both references point to the same commit.
- **Remote ahead** — GitHub contains commits not in the local branch.
- **Diverged** — both sides contain unique commits and require a merge or rebase.

Branches that exist on only one side are included as local-ahead or
remote-ahead and clearly labeled as local-only or remote-only.

## How scanning works

1. Choose a folder containing project folders.
2. The app recursively checks every visible subfolder for a `.git` directory.
3. It keeps repositories with a `github.com` remote, preferring `origin`.
4. It runs `git fetch --prune` for that remote.
5. It compares local and remote branch commit graphs with
   `git rev-list --left-right --count`.

If fetching fails, the app displays a warning and uses the cached remote
references already present in the repository.

The app target explicitly sets `ENABLE_APP_SANDBOX = NO`.

## Build

Open `GitBranchStatus.xcodeproj` in Xcode, or run:

```sh
xcodebuild \
  -project GitBranchStatus.xcodeproj \
  -scheme GitBranchStatus \
  -configuration Debug \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  build
```

The built app will be at:

`build/Build/Products/Debug/GitBranchStatus.app`

Run tests with:

```sh
xcodebuild \
  -project GitBranchStatus.xcodeproj \
  -scheme GitBranchStatus \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  test
```
