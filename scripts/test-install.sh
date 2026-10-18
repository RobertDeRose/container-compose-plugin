#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
export COMPOSE_STAGING_DIR="$root/stage/compose"
mkdir -p "$COMPOSE_STAGING_DIR/bin" "$COMPOSE_STAGING_DIR/resources"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$COMPOSE_STAGING_DIR/bin/compose"
chmod 0755 "$COMPOSE_STAGING_DIR/bin/compose"
printf '%s\n' 'fixture' > "$COMPOSE_STAGING_DIR/.container-compose-plugin"
printf '%s\n' 'abstract = "fixture"' > "$COMPOSE_STAGING_DIR/config.toml"
prefix="$root/prefix with spaces"
./scripts/install.sh --prefix "$prefix" >/dev/null
destination="$prefix/libexec/container-plugins/compose"
[[ -x "$destination/bin/compose" ]]
diff -r "$COMPOSE_STAGING_DIR" "$destination"
# Both upgrade entry points replace the complete payload, remove obsolete
# files, and leave other plugins alone. Paths with spaces must keep working.
sibling="${destination%/compose}/another-plugin"
mkdir -p "$sibling"
printf '%s\n' 'another plugin' > "$sibling/keep"
for version in new-version newer-version; do
    mkdir -p "$destination/obsolete-directory"
    printf '%s\n' 'obsolete' > "$destination/obsolete-directory/file"
    printf '%s\n' 'obsolete' > "$destination/resources/obsolete"
    printf '%s\n' '#!/bin/sh' "echo $version" > "$COMPOSE_STAGING_DIR/bin/compose"
    printf 'abstract = "%s"\n' "$version" > "$COMPOSE_STAGING_DIR/config.toml"
    printf '%s\n' "$version" > "$COMPOSE_STAGING_DIR/resources/version"
    install_args=(--prefix "$prefix")
    # --replace is still accepted from callers written for earlier installers.
    if [[ $version == newer-version ]]; then install_args+=(--replace); fi
    ./scripts/install.sh "${install_args[@]}" >/dev/null
    diff -r "$COMPOSE_STAGING_DIR" "$destination"
    [[ -x "$destination/bin/compose" && $("$destination/bin/compose") == "$version" ]]
    [[ $(cat "$sibling/keep") == 'another plugin' ]]
done

assert_install_refused() {
    local refused_destination=$1
    shift
    if ./scripts/install.sh "$@" >"$root/refusal.log" 2>&1; then
        echo "Installer overwrote $refused_destination." >&2; exit 1
    else
        [[ $? == 1 ]] || { cat "$root/refusal.log" >&2; exit 1; }
    fi
    [[ $(cat "$root/refusal.log") == "Refusing to overwrite $refused_destination:"* ]] || {
        cat "$root/refusal.log" >&2; exit 1;
    }
}

# Neither invocation may alter a foreign directory, a file, or a directory
# whose marker is not a regular file.
rm "$destination/.container-compose-plugin"
cp -R "$destination" "$root/foreign-original"
for kind in foreign-directory regular-file marker-directory; do
    refused_prefix="$root/$kind"
    refused_destination="$refused_prefix/libexec/container-plugins/compose"
    mkdir -p "${refused_destination%/compose}"
    case "$kind" in
        foreign-directory) cp -R "$root/foreign-original" "$refused_destination" ;;
        regular-file) printf '%s\n' 'foreign plugin file' > "$refused_destination" ;;
        marker-directory)
            cp -R "$root/foreign-original" "$refused_destination"
            mkdir "$refused_destination/.container-compose-plugin" ;;
    esac
    cp -R "$refused_destination" "$root/$kind-original"
    for mode in default legacy; do
        install_args=(--prefix "$refused_prefix")
        if [[ $mode == legacy ]]; then install_args+=(--replace); fi
        assert_install_refused "$refused_destination" "${install_args[@]}"
        diff -r "$root/$kind-original" "$refused_destination"
    done
done

# A symlink is refused even when its target carries this plugin's marker.
# A dangling symlink must also survive both attempts unchanged.
linked_plugin="$root/linked plugin"
cp -R "$COMPOSE_STAGING_DIR" "$linked_plugin"
for target in "$linked_plugin" "$root/missing plugin"; do
    link_prefix="$root/symlink prefix"
    link_destination="$link_prefix/libexec/container-plugins/compose"
    mkdir -p "${link_destination%/compose}"
    ln -s "$target" "$link_destination"
    for mode in default legacy; do
        install_args=(--prefix "$link_prefix")
        if [[ $mode == legacy ]]; then install_args+=(--replace); fi
        assert_install_refused "$link_destination" "${install_args[@]}"
        [[ -L "$link_destination" && $(readlink "$link_destination") == "$target" ]]
        diff -r "$COMPOSE_STAGING_DIR" "$linked_plugin"
        [[ ! -e "$root/missing plugin" ]]
    done
    rm "$link_destination"
done
if ./scripts/install.sh --prefix relative >/dev/null 2>&1; then
    echo 'Installer accepted a relative prefix.' >&2; exit 1
fi
# A stage created under a restrictive umask must still install readable
# directories, as the installer may copy it as root.
restricted="$root/restricted"
mkdir -p "$restricted"
(umask 077 && mkdir -p "$restricted/stage/compose/bin")
cp "$COMPOSE_STAGING_DIR/bin/compose" "$restricted/stage/compose/bin/compose"
cp "$COMPOSE_STAGING_DIR/config.toml" "$restricted/stage/compose/config.toml"
printf '%s\n' 'fixture' > "$restricted/stage/compose/.container-compose-plugin"
restricted_prefix="$restricted/prefix"
(umask 077 && COMPOSE_STAGING_DIR="$restricted/stage/compose" ./scripts/install.sh --prefix "$restricted_prefix" >/dev/null)
restricted_destination="$restricted_prefix/libexec/container-plugins/compose"
# The plugin's directories and the parents the installer created. `find
# -perm` is an exact match on both BSD and GNU find; `stat` differs.
for directory in "$restricted_prefix/libexec" "$restricted_prefix/libexec/container-plugins" \
    "$restricted_destination" "$restricted_destination/bin"; do
    [[ -n $(find "$directory" -maxdepth 0 -perm 0755) ]] || { echo "Installed directory $directory is not 0755." >&2; exit 1; }
done
# A release archive carries the installer, which then runs from the extracted
# directory without the repository or COMPOSE_STAGING_DIR.
extracted="$root/extracted/compose"
mkdir -p "$extracted/bin"
cp "$COMPOSE_STAGING_DIR/bin/compose" "$extracted/bin/compose"
cp "$COMPOSE_STAGING_DIR/config.toml" "$extracted/config.toml"
printf '%s\n' 'fixture' > "$extracted/.container-compose-plugin"
cp scripts/install.sh "$extracted/install.sh"
archive_prefix="$root/archive-prefix"
(cd "$root" && env -u COMPOSE_STAGING_DIR "$extracted/install.sh" --prefix "$archive_prefix" >/dev/null)
archive_destination="$archive_prefix/libexec/container-plugins/compose"
[[ -x "$archive_destination/bin/compose" && -f "$archive_destination/config.toml" ]]
[[ ! -e "$archive_destination/install.sh" ]] || { echo 'Installer copied itself into the plugin.' >&2; exit 1; }
# The extracted installer must also upgrade an existing release without the
# legacy flag, and must not leave its own copy or obsolete files installed.
printf '%s\n' '#!/bin/sh' 'echo archive-upgrade' > "$extracted/bin/compose"
printf '%s\n' 'obsolete' > "$archive_destination/obsolete"
(cd "$root" && env -u COMPOSE_STAGING_DIR "$extracted/install.sh" --prefix "$archive_prefix" >/dev/null)
[[ $("$archive_destination/bin/compose") == archive-upgrade ]]
cmp "$extracted/config.toml" "$archive_destination/config.toml"
[[ ! -e "$archive_destination/obsolete" && ! -e "$archive_destination/install.sh" ]]
printf '%s\n' 'Installer checks passed: spaces, install, upgrades, foreign-plugin and symlink refusal, prefix validation, umask, and release archive.'
