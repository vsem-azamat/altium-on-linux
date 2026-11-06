#!/usr/bin/env bash
# Create the Wine prefix for the "prefix" backend: Altium in a plain Wine prefix run with
# the host's libraries, without Bottles or Flatpak. It sets up what Bottles' "Gaming"
# environment would (README "Without Flatpak"): the soda runner, DXVK, vkd3d-proton and
# the same dependencies, all pinned to the versions the Bottles setup was tested with.
# Then run scripts/install.sh as for a bottle.
#
#   scripts/setup-prefix.sh [--no-deps]
#
#   --no-deps   skip the winetricks dependencies (d3dx9, d3dcompiler_43/47, msls31, fonts)
#
# Everything goes into $ALTIUM_PREFIX_HOME (default ~/.local/share/altium-on-linux):
# runners/, components/, cache/ (downloads) and prefix/ (the Wine prefix). Safe to re-run:
# finished steps are skipped.
set -euo pipefail

# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

DEPS=1
while [ $# -gt 0 ]; do
    case $1 in
        --no-deps) DEPS=0; shift ;;
        -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done

# Pinned downloads: name, URL, SHA-256. The versions are the ones of the tested Bottles
# setup (README "Tested on"); the checksums are those GitHub publishes for the release
# assets, and for winetricks of the file at that tag.
RUNNER=soda-11.0-7
RUNNER_URL=https://github.com/bottlesdevs/wine/releases/download/soda-11.0-7/soda-11.0-7-x86_64.tar.xz
RUNNER_SHA256=4b231c4fd7087e5f6d762093f2a486b0b3011da9b963e4879a1c6dbfe0b2b69f
DXVK=dxvk-3.1
DXVK_URL=https://github.com/doitsujin/dxvk/releases/download/v3.1/dxvk-3.1.tar.gz
DXVK_SHA256=30f9cc326874be344285582275446968cfa4c069db31ce56df312d6644179154
VKD3D=vkd3d-proton-3.0.1
VKD3D_URL=https://github.com/HansKristian-Work/vkd3d-proton/releases/download/v3.0.1/vkd3d-proton-3.0.1.tar.zst
VKD3D_SHA256=3cf2315522af5e43605ef6d3c41dad91387040bf97199934f3f7ab76caaa2f0c
WINETRICKS_URL=https://raw.githubusercontent.com/Winetricks/winetricks/20260125/src/winetricks
WINETRICKS_SHA256=431f82fc74000e6c864409f1d8fb495d696c03928808e3e8acffc45179312a7b
# Bottles' "Gaming" environment (Bottles 67.0, samples.py) installs these; Wine Mono comes
# with the runner, and Gecko is left out (nothing in Altium's setup uses Wine's mshtml).
WINETRICKS_VERBS=(d3dx9 msls31 arial times courier d3dcompiler_43 d3dcompiler_47)

PREFIX=$PREFIX_HOME/prefix
CACHE=$PREFIX_HOME/cache
RUNNER_DIR=$PREFIX_HOME/runners/$RUNNER
COMPONENTS=$PREFIX_HOME/components

need() { command -v "$1" >/dev/null || die "missing $1 ($2)"; }
need curl "Arch: pacman -S curl"
need tar "Arch: pacman -S tar"
need xz "Arch: pacman -S xz"
need zstd "Arch: pacman -S zstd"
[ "$DEPS" = 0 ] || need cabextract "winetricks needs it; Arch: pacman -S cabextract"
# The runner's 32-bit half (the installer is 32-bit) runs on the host's 32-bit libraries.
[ -e /usr/lib32/libX11.so.6 ] || [ -e /usr/lib/i386-linux-gnu/libX11.so.6 ] \
    || die "no 32-bit X11 libraries (Arch: enable [multilib], pacman -S lib32-libx11 lib32-mesa lib32-vulkan-driver lib32-gnutls)"

# fetch URL SHA256: download into CACHE (once) and check it; prints the file's path.
fetch() {
    local file=$CACHE/$(basename "$1")
    mkdir -p "$CACHE"
    if [ ! -f "$file" ]; then
        say "Downloading $(basename "$1")"
        if [ -t 2 ]; then progress=--progress-bar; else progress=-sS; fi
        curl -fL "$progress" -o "$file.part" "$1"
        mv "$file.part" "$file"
    fi
    echo "$2  $file" | sha256sum -c --quiet - >&2 || { rm -f "$file"; die "checksum mismatch for $(basename "$1")"; }
    echo "$file"
}

# unpack ARCHIVE DEST: extract an archive with a single top-level folder as DEST.
unpack() {
    local tmp
    tmp=$(mktemp -d "$(dirname "$2")/.unpack.XXXXXX")
    tar -xf "$1" -C "$tmp"
    mv "$tmp"/* "$2"
    rmdir "$tmp"
}

w() { WINEPREFIX=$PREFIX WINEDEBUG=-all WINEDLLOVERRIDES="mshtml=d;winemenubuilder.exe=d" "$RUNNER_DIR/bin/wine" "$@"; }
wait_server() { WINEPREFIX=$PREFIX "$RUNNER_DIR/bin/wineserver" -w; }

if [ ! -x "$RUNNER_DIR/bin/wine" ]; then
    archive=$(fetch "$RUNNER_URL" "$RUNNER_SHA256")
    say "Unpacking $RUNNER"
    mkdir -p "$(dirname "$RUNNER_DIR")"
    unpack "$archive" "$RUNNER_DIR"
fi
for c in "$DXVK $DXVK_URL $DXVK_SHA256" "$VKD3D $VKD3D_URL $VKD3D_SHA256"; do
    read -r name url sum <<< "$c"
    if [ ! -d "$COMPONENTS/$name" ]; then
        archive=$(fetch "$url" "$sum")
        say "Unpacking $name"
        mkdir -p "$COMPONENTS"
        unpack "$archive" "$COMPONENTS/$name"
    fi
done

if [ ! -f "$PREFIX/system.reg" ]; then
    say "Creating the Wine prefix in $PREFIX"
    mkdir -p "$PREFIX"
    WINEARCH=win64 w wineboot --init
    wait_server
    # Like Bottles: the user folders (Documents, Desktop, ...) are folders of the prefix,
    # not links into your home (Wine's default); your files are on drive Z:.
    for link in "$PREFIX/drive_c/users/$USER"/*; do
        if [ -L "$link" ]; then rm "$link"; mkdir "$link"; fi
    done
fi

# DXVK and vkd3d-proton, as Bottles installs them (dlls/dll.py): 64-bit DLLs into system32,
# 32-bit ones into syswow64, and native-then-builtin overrides.
say "Installing $DXVK and $VKD3D"
cp "$COMPONENTS/$DXVK"/x64/*.dll "$PREFIX/drive_c/windows/system32/"
cp "$COMPONENTS/$DXVK"/x32/*.dll "$PREFIX/drive_c/windows/syswow64/"
cp "$COMPONENTS/$VKD3D"/x64/*.dll "$PREFIX/drive_c/windows/system32/"
cp "$COMPONENTS/$VKD3D"/x86/*.dll "$PREFIX/drive_c/windows/syswow64/"
reg=$CACHE/components.reg
{
    printf 'Windows Registry Editor Version 5.00\n\n[HKEY_CURRENT_USER\\Software\\Wine\\DllOverrides]\n'
    for dll in d3d8 d3d9 d3d10core d3d11 dxgi d3d12 d3d12core; do printf '"%s"="native,builtin"\n' "$dll"; done
    # Bottles keeps Wine from writing .desktop files and menu entries for the prefix.
    printf '"winemenubuilder.exe"=""\n'
} > "$reg"
w regedit /S "$(winpath "$reg")"
wait_server

if [ "$DEPS" = 1 ]; then
    winetricks=$(fetch "$WINETRICKS_URL" "$WINETRICKS_SHA256")
    chmod +x "$winetricks"
    # winetricks records what it installed in winetricks.log and skips those.
    missing=()
    for verb in "${WINETRICKS_VERBS[@]}"; do
        grep -qx "$verb" "$PREFIX/winetricks.log" 2>/dev/null || missing+=("$verb")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        say "Installing dependencies with winetricks: ${missing[*]}"
        WINEPREFIX=$PREFIX WINE=$RUNNER_DIR/bin/wine WINESERVER=$RUNNER_DIR/bin/wineserver WINEDEBUG=-all \
            WINEDLLOVERRIDES="mshtml=d;winemenubuilder.exe=d" "$winetricks" -q --unattended "${missing[@]}"
        wait_server
    fi
fi

printf 'RUNNER=%s\nDXVK=%s\nVKD3D=%s\n' "$RUNNER" "$DXVK" "$VKD3D" > "$PREFIX/prefix.conf"
touch "$PREFIX/altium.env"

echo
echo "The prefix is ready: $PREFIX"
echo "Next: scripts/install.sh (it uses the prefix when there is no Bottles bottle; set"
echo "ALTIUM_BACKEND=prefix if you have both), then scripts/run.sh exe <installer>."
