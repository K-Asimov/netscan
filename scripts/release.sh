#!/bin/bash
# release.sh — Bump version, update CHANGELOG, tag, and push.
#
# Usage:  ./scripts/release.sh <version>
# Example: ./scripts/release.sh 1.0.1

set -e

VERSION=$1
if [ -z "$VERSION" ]; then
  echo "Usage: $0 <version>"
  echo "Example: $0 1.0.1"
  exit 1
fi

if ! [[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Error: Version must be semver (e.g. 1.0.0)"
  exit 1
fi

TAG="v$VERSION"
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "Error: Tag $TAG already exists locally"
  exit 1
fi

if [ "$CURRENT_BRANCH" = "HEAD" ]; then
  echo "Error: Detached HEAD state. Checkout a branch first."
  exit 1
fi

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Error: Uncommitted changes. Commit or stash first."
  exit 1
fi

echo "==> Releasing $TAG"

# 1. Update version in project.pbxproj
PBXPROJ="NetScan.xcodeproj/project.pbxproj"
sed -i '' "s/MARKETING_VERSION = [0-9.]*;/MARKETING_VERSION = $VERSION;/g" "$PBXPROJ"
sed -i '' "s/CURRENT_PROJECT_VERSION = [0-9]*;/CURRENT_PROJECT_VERSION = $VERSION;/g" "$PBXPROJ"
echo "    Updated $PBXPROJ"

# 2. Update CHANGELOG.md
DATE=$(date +%Y-%m-%d)
CHANGELOG="CHANGELOG.md"
PREV_TAG=$(git describe --tags --abbrev=0 2>/dev/null || true)

if [ ! -f "$CHANGELOG" ]; then
  printf "# Changelog\n\nAll notable changes to this project will be documented in this file.\n\n" > "$CHANGELOG"
fi

TEMP=$(mktemp)
ENTRY=$(mktemp)
ADDED_ITEMS=$(mktemp)
FIXED_ITEMS=$(mktemp)
CHANGED_ITEMS=$(mktemp)
COMMIT_LOG_ITEMS=$(mktemp)
trap 'rm -f "$TEMP" "$ENTRY" "$ADDED_ITEMS" "$FIXED_ITEMS" "$CHANGED_ITEMS" "$COMMIT_LOG_ITEMS"' EXIT

LOG_RANGE="${PREV_TAG:+$PREV_TAG..}HEAD"
echo "    Collecting commits: $LOG_RANGE"

while IFS= read -r line; do
  subject="${line#*$'\t'}"
  [ -z "$subject" ] && continue
  cleaned=$(echo "$subject" | sed -E 's/^(feat|fix|chore|docs|refactor|perf|test|build|ci|style)(\([^)]+\))?!?:[[:space:]]*//')
  lower=$(echo "$subject" | tr '[:upper:]' '[:lower:]')
  printf -- "- %s\n" "$subject" >> "$COMMIT_LOG_ITEMS"
  case "$lower" in
    feat*|add*) printf -- "- %s\n" "$cleaned" >> "$ADDED_ITEMS" ;;
    fix*|bugfix*|hotfix*) printf -- "- %s\n" "$cleaned" >> "$FIXED_ITEMS" ;;
    *) printf -- "- %s\n" "$cleaned" >> "$CHANGED_ITEMS" ;;
  esac
done < <(git log --pretty=format:'%h%x09%s' "$LOG_RANGE")

[ ! -s "$CHANGED_ITEMS" ] && [ ! -s "$ADDED_ITEMS" ] && [ ! -s "$FIXED_ITEMS" ] && \
  printf -- "- No user-facing changes recorded\n" >> "$CHANGED_ITEMS"

{
  echo ""
  echo "## [$VERSION] - $DATE"
  echo ""
  if [ -s "$ADDED_ITEMS" ]; then echo "### Added"; cat "$ADDED_ITEMS"; echo ""; fi
  if [ -s "$FIXED_ITEMS" ]; then echo "### Fixed"; cat "$FIXED_ITEMS"; echo ""; fi
  if [ -s "$CHANGED_ITEMS" ]; then echo "### Changed"; cat "$CHANGED_ITEMS"; echo ""; fi
} > "$ENTRY"

awk -v entry_file="$ENTRY" '
BEGIN { while ((getline line < entry_file) > 0) entry = entry line ORS; close(entry_file); inserted=0 }
{ if (!inserted && $0 ~ /^## \[/) { printf "%s", entry; inserted=1 } print }
END { if (!inserted) printf "%s", entry }
' "$CHANGELOG" > "$TEMP"
mv "$TEMP" "$CHANGELOG"
echo "    Updated $CHANGELOG"

# 3. Commit
git add "$PBXPROJ" "$CHANGELOG"
git commit -m "$(cat <<EOF
chore: release $TAG

Release $TAG ($DATE)
EOF
)"
echo "    Committed changes"

# 4. Tag
git tag -a "$TAG" -m "Release $TAG ($DATE)"
echo "    Created tag $TAG"

# 5. Push
git push origin "$CURRENT_BRANCH"
git push origin "$TAG"
echo "    Pushed to origin"

echo ""
echo "Done! Release $TAG complete."
echo "Run ./scripts/build-dmg.sh $VERSION to build the DMG."
