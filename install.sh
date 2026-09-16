#!/bin/bash
# Agent Board public bootstrap. Requires Bash 3.2+, curl, tar and SHA-256 tools.
set -euo pipefail
umask 077
export LC_ALL=C

die() { printf 'Agent Board: %s\n' "$*" >&2; exit 1; }
catalog='claude-code codex gemini opencode droid qwen cursor vscode vscode-insiders copilot cline continue zed windsurf devin roo-code'
valid_host() { case " $catalog " in *" $1 "*) return 0;; *) return 1;; esac; }
original=("$@")
hosts='' yes=0 list=0 version=0 help=0
overrides=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --hosts|--hosts=*)
      [ -z "$hosts" ] || die '--hosts may only be supplied once'
      case "$1" in --hosts=*) hosts=${1#*=};; *) [ "$#" -ge 2 ] || die '--hosts requires a value'; shift; hosts=$1;; esac
      case "$hosts" in ''|,*|*,|*,,*) die 'Host selection cannot be empty';; esac
      IFS=',' read -r -a selected <<< "$hosts"
      for host in "${selected[@]}"; do valid_host "$host" || die "Unknown host: $host"; done
      ;;
    --config-path|--config-path=*)
      case "$1" in --config-path=*) value=${1#*=};; *) [ "$#" -ge 2 ] || die '--config-path requires a value'; shift; value=$1;; esac
      host=${value%%=*}; path=${value#*=}
      valid_host "$host" || die "Unknown host: $host"
      case "$path" in /*) ;; *) die '--config-path requires host=/absolute/path';; esac
      case "$path" in *$'\n'*|*$'\r'*) die 'Configuration path must be single-line';; esac
      for previous in ${overrides[@]+"${overrides[@]}"}; do [ "$previous" != "$host" ] || die 'Duplicate configuration override'; done
      overrides+=("$host")
      ;;
    --yes) yes=1;;
    --dry-run|--json) ;;
    --list-hosts) list=1;;
    --version) version=1;;
    --help) help=1;;
    *) die "Unknown installer option: $1";;
  esac
  shift
done
[ "$help" -eq 0 ] || { printf 'Usage: curl -fsSL INSTALL_URL | bash -s -- [--hosts codex,claude-code --yes] [--dry-run] [--json]\n'; exit 0; }
[ "$version" -eq 0 ] || { printf 'Agent Board installer 0.8.0 (protocol 1)\n'; exit 0; }
[ "$list" -eq 0 ] || { for host in $catalog; do printf '%s\n' "$host"; done; exit 0; }
for host in ${overrides[@]+"${overrides[@]}"}; do case ",$hosts," in *",$host,"*) ;; *) die '--config-path requires selecting its host with --hosts';; esac; done
if [ "$yes" -eq 1 ]; then
  [ -n "$hosts" ] || die '--yes requires an explicit --hosts selection'
else
  # The script may arrive on stdin. Prompts use the controlling terminal.
  if ! { exec 3<>/dev/tty; } 2>/dev/null; then die 'A terminal is required; use --hosts codex,claude-code --yes for automation'; fi
  [ -t 3 ] || die 'A terminal is required for keyboard selection'
fi
command -v curl >/dev/null || die 'curl is required'
command -v tar >/dev/null || die 'tar is required'
if command -v shasum >/dev/null; then sha=(shasum -a 256); elif command -v sha256sum >/dev/null; then sha=(sha256sum); else die 'A SHA-256 utility is required'; fi
at_least() { awk -v actual="$1" -v minimum="$2" 'BEGIN { split(actual,a,"."); split(minimum,b,"."); for(i=1;i<=3;i++){ if(a[i]+0>b[i]+0)exit 0; if(a[i]+0<b[i]+0)exit 1 } exit 0 }'; }
case "$(uname -s)" in
  Darwin) os=darwin; at_least "$(sw_vers -productVersion)" 13.5 || die 'macOS 13.5 or newer is required';;
  Linux)
    os=linux
    at_least "$(uname -r)" 5.15 || die 'Linux kernel 5.15 or newer is required'
    libc=$(getconf GNU_LIBC_VERSION 2>/dev/null) || die 'GNU libc 2.35 or newer is required; musl/Alpine is unsupported'
    case "$libc" in 'glibc '*) ;; *) die 'GNU libc is required';; esac
    at_least "${libc#glibc }" 2.35 || die 'GNU libc 2.35 or newer is required'
    ;;
  *) die 'This installer supports macOS and GNU/Linux, including Linux inside WSL';;
esac
case "$(uname -m)" in arm64|aarch64) arch=arm64;; x86_64|amd64) arch=x64;; *) die 'Only arm64 and x64 are supported';; esac
target="$os-$arch"
stage=$(mktemp -d "${TMPDIR:-/tmp}/agent-board-download.XXXXXXXX")
cleanup() { rm -rf -- "$stage"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
base='https://github.com/hatish2001/agent-board-releases/releases'
download() { curl --proto '=https' --proto-redir '=https' --tlsv1.2 --fail --silent --show-error --location --retry 2 --connect-timeout 15 --max-time 300 --max-filesize "$3" -o "$2" "$1"; }
download "$base/latest/download/manifest.tsv" "$stage/manifest.tsv" 65536
# Fixed seven-column format keeps bootstrap independent of Node, Python and jq.
awk -F '\t' -v target="$target" '
  NF != 7 || $1 != "1" || $2 !~ /^[0-9]+\.[0-9]+\.[0-9]+$/ || length($3)!=40 || $3 !~ /^[a-f0-9]+$/ || $4 !~ /^(darwin|linux)-(arm64|x64)$/ || $5 !~ /^https:\/\/github.com\/hatish2001\/agent-board-releases\/releases\/download\/v[0-9.]+\/agent-board-[0-9.]+-(darwin|linux)-(arm64|x64)\.tar\.gz$/ || $6 !~ /^[0-9]+$/ || $6<1 || $6>536870912 || length($7)!=64 || $7 !~ /^[a-f0-9]+$/ { bad=1 }
  seen[$4]++ { bad=1 }
  NR==1 { version=$2; commit=$3 }
  $2!=version || $3!=commit { bad=1 }
  $5 != "https://github.com/hatish2001/agent-board-releases/releases/download/v" $2 "/agent-board-" $2 "-" $4 ".tar.gz" { bad=1 }
  $4==target { row=$0; found++ }
  END { if(bad || found!=1) exit 1; print row }
' "$stage/manifest.tsv" > "$stage/selected.tsv" || die 'Invalid manifest or no verified release for this platform'
IFS=$'\t' read -r schema release commit selected_target url size checksum < "$stage/selected.tsv"
[ "$schema" = 1 ] && [ "$selected_target" = "$target" ] || die 'Manifest selection mismatch'
download "$url" "$stage/archive.tar.gz" "$size"
actual_size=$(wc -c < "$stage/archive.tar.gz" | tr -d ' ')
[ "$actual_size" = "$size" ] || die 'Archive size mismatch'
actual_sha=$("${sha[@]}" "$stage/archive.tar.gz" | awk '{print $1}')
[ "$actual_sha" = "$checksum" ] || die 'Archive checksum mismatch'
tar -tzf "$stage/archive.tar.gz" > "$stage/entries" || die 'Invalid archive'
awk '
  !/^agent-board(\/[a-zA-Z0-9@_.+\/-]+)?\/?$/ || /(^|\/)\.\.?($|\/)/ || /\/\// { bad=1 }
  { sub(/\/$/, ""); if(seen[$0]++) bad=1; count++ }
  END { if(bad || count<2 || count>100000) exit 1 }
' "$stage/entries" || die 'Unsafe archive paths'
tar -tvzf "$stage/archive.tar.gz" > "$stage/types" || die 'Invalid archive metadata'
awk 'substr($0,1,1)!="-" && substr($0,1,1)!="d" { bad=1 } END { exit bad }' "$stage/types" || die 'Unsafe archive entry type (links and special files are forbidden)'
mkdir "$stage/unpacked"
tar -xzf "$stage/archive.tar.gz" --no-same-owner --no-same-permissions -C "$stage/unpacked"
runtime="$stage/unpacked/agent-board"
[ -f "$runtime/bin/node" ] && [ -f "$runtime/app/src/cli.js" ] || die 'Incomplete runtime archive'
export AGENT_BOARD_STAGED_RUNTIME="$runtime"
export AGENT_BOARD_EXPECTED_VERSION="$release" AGENT_BOARD_EXPECTED_COMMIT="$commit" AGENT_BOARD_EXPECTED_TARGET="$target"
if [ "$yes" -eq 1 ]; then
  "$runtime/bin/node" "$runtime/app/src/cli.js" install "${original[@]}"
else
  "$runtime/bin/node" "$runtime/app/src/cli.js" install "${original[@]}" <&3
fi
