#!/usr/bin/env bash
# Merge every open pull request of the CFPA language package on top of main,
# pack all versions with the upstream Packer and write the packs plus MD5 files
# to $DIST_DIR using the same names as the upstream autobuild release.
set -euo pipefail

UPSTREAM="${UPSTREAM:-CFPAOrg/Minecraft-Mod-Language-Package}"
WORK_DIR="${WORK_DIR:-$PWD/work}"
DIST_DIR="${DIST_DIR:-$PWD/dist}"
PACKER_DIR="${PACKER_DIR:-$PWD/packer}"
LIMIT="${LIMIT:-0}"
FETCH_BATCH=100
AUTOBUILD_URL="https://github.com/$UPSTREAM/releases/download/autobuild"
STATIC_VERSIONS=("1.10.2")

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

# 1.20-fabric -> Minecraft-Mod-Language-Modpack-1-20-Fabric.zip
zip_name() {
    local version="$1"
    if [[ "$version" == "1.12.2" ]]; then
        echo "Minecraft-Mod-Language-Modpack.zip"
        return
    fi
    local name="${version//./-}"
    name="${name/-fabric/-Fabric}"
    echo "Minecraft-Mod-Language-Modpack-$name.zip"
}

write_md5() {
    local file="$1" target="$2"
    md5sum "$file" | cut -c1-32 | tr 'a-f' 'A-F' | tr -d '\n' > "$target"
}

# Prints the language JSON files that fail to parse now but parsed (or did not
# exist) on main, so pre-existing lenient files upstream are not blamed on a PR.
broken_json() {
    python3 - "$@" <<'PY'
import json, subprocess, sys

def parses(text):
    try:
        json.loads(text)
        return True
    except ValueError:
        return False

for path in sys.argv[1:]:
    try:
        with open(path, encoding="utf-8-sig") as f:
            current = f.read()
    except (FileNotFoundError, UnicodeDecodeError):
        continue
    if parses(current):
        continue
    base = subprocess.run(["git", "show", "origin/main:" + path],
                          capture_output=True)
    if base.returncode != 0 or parses(base.stdout.decode("utf-8-sig", "replace")):
        print(path)
PY
}

# Prints packer-policy.json files that are invalid or reference a missing source
# path, which crashes the Packer for every version that reaches them.
dangling_policies() {
    python3 - <<'PY'
import json, os

for root, _, files in os.walk("projects"):
    if "packer-policy.json" not in files:
        continue
    path = os.path.join(root, "packer-policy.json")
    try:
        with open(path, encoding="utf-8-sig") as f:
            policies = json.load(f)
    except ValueError:
        print(path)
        continue
    for policy in policies if isinstance(policies, list) else []:
        source = policy.get("source") if isinstance(policy, dict) else None
        if isinstance(source, str) and not os.path.exists(source):
            print(path + " -> " + source)
PY
}

rm -rf "$WORK_DIR" "$DIST_DIR" "$PACKER_DIR"
mkdir -p "$DIST_DIR"

log "Cloning $UPSTREAM"
git clone --quiet --single-branch --branch main "https://github.com/$UPSTREAM.git" "$WORK_DIR"
cd "$WORK_DIR"
git config user.name "automerge-bot"
git config user.email "automerge-bot@users.noreply.github.com"
BASE_SHA="$(git rev-parse HEAD)"

# Build the packer from clean main so pull requests never run their own code.
log "Building Packer"
dotnet publish src/Packer/Packer.csproj -c Release -r linux-x64 -o "$PACKER_DIR" -nologo -v quiet -clp:ErrorsOnly >&2

log "Listing open pull requests"
mapfile -t PRS < <(gh pr list -R "$UPSTREAM" --state open --limit 1000 \
    --json number,title,isDraft,author \
    --jq '[.[] | select(.isDraft | not)] | sort_by(-.number) | .[] | [.number, .author.login, .title] | @tsv')
if (( LIMIT > 0 )) && (( ${#PRS[@]} > LIMIT )); then
    PRS=("${PRS[@]:0:LIMIT}")
fi
log "Found ${#PRS[@]} pull requests"

declare -A TITLE AUTHOR
NUMBERS=()
for line in "${PRS[@]}"; do
    IFS=$'\t' read -r number author title <<< "$line"
    NUMBERS+=("$number")
    AUTHOR[$number]="$author"
    TITLE[$number]="$title"
done

log "Fetching pull request heads"
for (( i = 0; i < ${#NUMBERS[@]}; i += FETCH_BATCH )); do
    specs=()
    for number in "${NUMBERS[@]:i:FETCH_BATCH}"; do
        specs+=("+pull/$number/head:refs/pr/$number")
    done
    if ! git fetch --quiet --no-tags origin "${specs[@]}"; then
        log "Batch fetch failed, fetching one by one"
        for spec in "${specs[@]}"; do
            git fetch --quiet --no-tags origin "$spec" || log "Fetch failed: $spec"
        done
    fi
done

# Dangling references already on main are not blamed on any pull request
BASELINE_POLICIES="$(dangling_policies | sort)"

MERGED=()
CONFLICTED=()
INVALID=()
for number in "${NUMBERS[@]}"; do
    if ! git rev-parse --quiet --verify "refs/pr/$number" > /dev/null; then
        CONFLICTED+=("$number")
        continue
    fi
    if ! git merge --quiet --no-ff --no-edit -m "Merge #$number" "refs/pr/$number" > /dev/null 2>&1; then
        git merge --abort > /dev/null 2>&1 || git reset --quiet --hard HEAD
        CONFLICTED+=("$number")
        continue
    fi
    mapfile -t changed < <(git diff --name-only --diff-filter=AM HEAD^1 HEAD -- ':(glob)projects/**/lang/*.json')
    if (( ${#changed[@]} > 0 )) && [[ -n "$(broken_json "${changed[@]}")" ]]; then
        git reset --quiet --hard HEAD^1
        INVALID+=("$number")
        continue
    fi
    if [[ -n "$(comm -13 <(echo "$BASELINE_POLICIES") <(dangling_policies | sort))" ]]; then
        git reset --quiet --hard HEAD^1
        INVALID+=("$number")
        continue
    fi
    MERGED+=("$number")
done
log "Merged ${#MERGED[@]}, conflicted ${#CONFLICTED[@]}, invalid ${#INVALID[@]}"

FALLBACK=()
mapfile -t VERSIONS < <(find config/packer -maxdepth 1 -name '*.json' \
    ! -name 'namespace-discriminator.json' ! -name 'packer-example.json' \
    -printf '%f\n' | sed 's/\.json$//' | sort -V)
for version in "${VERSIONS[@]}"; do
    name="$(zip_name "$version")"
    log "Packing $version -> $name"
    rm -f "Minecraft-Mod-Language-Modpack-$version.zip"
    if "$PACKER_DIR/Packer" --version="$version" --flattened > "$DIST_DIR/.packer-$version.log" 2>&1 \
        && [[ -s "Minecraft-Mod-Language-Modpack-$version.zip" ]]; then
        mv "Minecraft-Mod-Language-Modpack-$version.zip" "$DIST_DIR/$name"
    else
        log "Packer failed for $version, falling back to autobuild"
        tail -n 20 "$DIST_DIR/.packer-$version.log" >&2 || true
        curl -fsSL --retry 3 -o "$DIST_DIR/$name" "$AUTOBUILD_URL/$name"
        FALLBACK+=("$version")
    fi
    write_md5 "$DIST_DIR/$name" "$DIST_DIR/$version.md5"
done
rm -f "$DIST_DIR"/.packer-*.log

for version in "${STATIC_VERSIONS[@]}"; do
    name="$(zip_name "$version")"
    log "Copying static $version from autobuild"
    curl -fsSL --retry 3 -o "$DIST_DIR/$name" "$AUTOBUILD_URL/$name"
    write_md5 "$DIST_DIR/$name" "$DIST_DIR/$version.md5"
done

pr_line() { echo "- #$1 ${TITLE[$1]} @${AUTHOR[$1]}"; }
{
    echo "上游 main：$UPSTREAM@${BASE_SHA:0:7}"
    echo
    echo "生成时间：$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M') (UTC+8)"
    echo
    echo "合并 ${#MERGED[@]} 个，冲突跳过 ${#CONFLICTED[@]} 个，内容无效跳过 ${#INVALID[@]} 个"
    if (( ${#FALLBACK[@]} > 0 )); then
        echo
        echo "打包失败并回退到 autobuild 的版本：${FALLBACK[*]}"
    fi
    echo
    echo "<details><summary>已合并</summary>"
    echo
    for number in "${MERGED[@]}"; do pr_line "$number"; done
    echo
    echo "</details>"
    echo
    echo "<details><summary>冲突跳过</summary>"
    echo
    for number in "${CONFLICTED[@]}"; do pr_line "$number"; done
    echo
    echo "</details>"
    if (( ${#INVALID[@]} > 0 )); then
        echo
        echo "<details><summary>内容无效跳过（语言 JSON 无法解析或 packer-policy 引用了不存在的路径）</summary>"
        echo
        for number in "${INVALID[@]}"; do pr_line "$number"; done
        echo
        echo "</details>"
    fi
} > "$DIST_DIR/notes.md"

log "Done: $(find "$DIST_DIR" -name '*.zip' | wc -l) packs in $DIST_DIR"
