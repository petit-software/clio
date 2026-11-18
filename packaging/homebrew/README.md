# Homebrew

`clio.rb` is the cask for the current release, written by
`scripts/generate-cask.sh` from the notarized DMG in `dist/`.

It is not published from here. Homebrew installs casks from a tap — a
repository named `homebrew-<something>` — so to offer
`brew install --cask petit-software/tap/clio`:

1. Create the public repository `petit-software/homebrew-tap`, once.
2. After each release (and after the GitHub release exists, as with the
   appcast), run `scripts/generate-cask.sh` and copy `clio.rb` to
   `Casks/clio.rb` in the tap; commit and push.

Check a cask before pushing it:

```sh
brew audit --cask --new packaging/homebrew/clio.rb
brew install --cask ./packaging/homebrew/clio.rb
```

`auto_updates true` tells Homebrew that Clio updates itself (Sparkle), so
`brew upgrade` leaves it alone unless asked with `--greedy`.
