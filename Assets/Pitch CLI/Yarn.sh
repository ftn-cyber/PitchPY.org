#!/usr/bin/env bash
# Pitch Yarn — berbasis lockfile (versi dikunci), cache offline. Terpisah dari pitch.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${PITCH_CONF:-$SCRIPT_DIR/pitch.conf}"
# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"

NAME="yarn"
FALLBACK="${FALLBACK_REGISTRY_URL:-https://pypi.org/simple}"
REGISTRY="${YARN_REGISTRY_URL:-}"; [ -n "$REGISTRY" ] || REGISTRY="$FALLBACK"
VENV="${PITCH_VENV:-.pitch/venv}"
PY="${PITCH_PYTHON:-python3}"
LOCK="pitch.yarn.lock"
MANIFEST="pitch.json"; [ -f pitch.yarn.json ] && MANIFEST="pitch.yarn.json"; export MANIFEST
CACHE="${YARN_CACHE_DIR:-$HOME/.pitch/cache/yarn}"

log(){ printf '\033[1;35m[%s]\033[0m %s\n' "$NAME" "$*"; }
die(){ printf '\033[1;31m[%s] error:\033[0m %s\n' "$NAME" "$*" >&2; exit 1; }
command -v "$PY" >/dev/null 2>&1 || die "python3 tidak ditemukan"
mkdir -p "$CACHE"
FROM_MANIFEST=0
if [ -f "$MANIFEST" ]; then
  _r="$("$PY" -c 'import json,os;print((json.load(open(os.environ["MANIFEST"])).get("yarn") or {}).get("registry",""))' 2>/dev/null || true)"
  [ -z "$_r" ] || { REGISTRY="$_r"; FROM_MANIFEST=1; }
fi

vbin(){ if [ -d "$VENV/bin" ]; then echo "$VENV/bin"; else echo "$VENV/Scripts"; fi; }
ensure_venv(){ [ -d "$VENV" ] || { log "membuat venv di $VENV"; "$PY" -m venv "$VENV"; }; }
pip_run(){ "$(vbin)/python" -m pip --disable-pip-version-check "$@"; }
index_args(){
  INDEX=(--index-url "$REGISTRY")
  if [ "$REGISTRY" != "$FALLBACK" ] && [ "${YARN_USE_FALLBACK:-1}" = "1" ]; then
    INDEX+=(--extra-index-url "$FALLBACK"); fi
  case "$REGISTRY" in http://*) local h="${REGISTRY#http://}"; h="${h%%[/:]*}"; INDEX+=(--trusted-host "$h");; esac
}
parse_pkg(){
  local s="$1"
  if [[ "$s" == *@* ]]; then P_NAME="${s%%@*}"; P_REQ="${P_NAME}==${s#*@}"; else P_NAME="$s"; P_REQ="$s"; fi
  P_NAME="${P_NAME%%\[*}"; P_NAME="${P_NAME%%[<>=~!]*}"
}
installed_ver(){ pip_run show "$1" 2>/dev/null | awk '/^Version:/{print $2}'; }
write_lock(){ pip_run freeze --exclude pip --exclude setuptools --exclude wheel > "$LOCK" 2>/dev/null || true; log "lockfile ditulis: $LOCK"; }

deps(){ "$PY" - "$@" <<'PY'
import json,re,sys,os
prod="--production" in sys.argv[1:]
if not os.path.exists(os.environ["MANIFEST"]): sys.exit(0)
d=json.load(open(os.environ["MANIFEST"]))
def conv(n,v):
    v=str(v).strip()
    if v in ("","*","latest"): return n
    m=re.match(r"^\^(\d+)(?:\.(\d+))?(?:\.(\d+))?$",v)
    if m:
        a,b,c=m.group(1),m.group(2) or "0",m.group(3) or "0"
        return f"{n}>={a}.{b}.{c},<{int(a)+1}.0.0"
    m=re.match(r"^~(\d+)\.(\d+)(?:\.(\d+))?$",v)
    if m: return f"{n}~={m.group(1)}.{m.group(2)}.{m.group(3) or '0'}"
    if re.match(r"^\d",v): return f"{n}=={v}"
    return f"{n}{v}"
res=d.get("resolutions") or {}
seen=set()
for k in ["dependencies"]+([] if prod else ["devDependencies"]):
    for n,v in (d.get(k) or {}).items(): print(conv(n,res.get(n,v))); seen.add(n)
for n,v in res.items():
    if n not in seen: print(conv(n,v))
PY
}
json_edit(){ "$PY" - "$@" <<'PY'
import json,os,sys
action,name,ver,dev=sys.argv[1:5]
f=os.environ["MANIFEST"]
d=json.load(open(f)) if os.path.exists(f) else {"name":os.path.basename(os.getcwd()),"version":"1.0.0"}
if action=="add":
    d.setdefault("devDependencies" if dev=="1" else "dependencies",{})[name]=ver or "*"
else:
    for k in ("dependencies","devDependencies","optionalDependencies"): (d.get(k) or {}).pop(name,None)
json.dump(d,open(f,"w"),indent=2,ensure_ascii=False); open(f,"a").write("\n")
PY
}

# install dari file requirement; $1=file $2=offline(0/1) $3=extra flag (mis. --no-deps)
do_install(){
  local file="$1" offline="$2" extra="${3:-}"
  if [ "$offline" != "1" ]; then
    index_args; log "mengisi cache dari $REGISTRY"
    # shellcheck disable=SC2086
    pip_run download --quiet -d "$CACHE" "${INDEX[@]}" $extra -r "$file"
  fi
  # shellcheck disable=SC2086
  pip_run install --quiet --no-index --find-links "$CACHE" $extra -r "$file"
}

cmd_init(){
  MANIFEST="pitch.yarn.json"; export MANIFEST
  [ -f "$MANIFEST" ] && { log "$MANIFEST sudah ada"; return 0; }
  json_edit init x x 0; log "$MANIFEST dibuat"
}
cmd_install(){
  local frozen=0 offline=0 prod="" pk=() a
  for a in "$@"; do case "$a" in
    --frozen-lockfile) frozen=1;; --offline) offline=1;; --production) prod="--production";;
    -*) ;; *) pk+=("$a");; esac; done
  if [ "${#pk[@]}" -gt 0 ]; then cmd_add "$@"; return; fi
  ensure_venv
  if [ -s "$LOCK" ]; then
    log "install dari $LOCK (versi dikunci)"; do_install "$LOCK" "$offline" "--no-deps"
  else
    [ "$frozen" = "1" ] && die "--frozen-lockfile: $LOCK tidak ada"
    local tmp; tmp="$(mktemp)"; deps $prod > "$tmp"
    if [ ! -s "$tmp" ]; then log "tidak ada dependency di $MANIFEST"; rm -f "$tmp"; return 0; fi
    do_install "$tmp" "$offline"; rm -f "$tmp"; write_lock
  fi
  log "selesai"
}
cmd_add(){
  local dev=0 list=() a pin v tmp
  for a in "$@"; do case "$a" in --dev|-D) dev=1;; -*) ;; *) list+=("$a");; esac; done
  [ "${#list[@]}" -gt 0 ] || die "sebutkan nama package"
  ensure_venv; tmp="$(mktemp)"
  for a in "${list[@]}"; do parse_pkg "$a"; echo "$P_REQ" >> "$tmp"; done
  do_install "$tmp" 0; rm -f "$tmp"
  for a in "${list[@]}"; do
    parse_pkg "$a"; pin=""; [[ "$a" == *@* ]] && pin="${a#*@}"
    v="$(installed_ver "$P_NAME")"; json_edit add "$P_NAME" "${pin:-${v:+^$v}}" "$dev"
  done
  write_lock
}
cmd_remove(){
  [ "$#" -gt 0 ] || die "sebutkan nama package"; ensure_venv
  for a in "$@"; do parse_pkg "$a"; pip_run uninstall -y "$P_NAME" || true; json_edit remove "$P_NAME" "" 0; done
  write_lock
}
cmd_upgrade(){
  ensure_venv; index_args
  if [ "$#" -gt 0 ]; then
    for a in "$@"; do parse_pkg "$a"; pip_run install --upgrade "${INDEX[@]}" "$P_NAME"; done
  else
    local tmp; tmp="$(mktemp)"; deps > "$tmp"; [ -s "$tmp" ] && pip_run install --upgrade "${INDEX[@]}" -r "$tmp"; rm -f "$tmp"
  fi
  write_lock
}
cmd_list(){ ensure_venv; pip_run list; }
cmd_registry(){ echo "$NAME registry : $REGISTRY"; echo "cache         : $CACHE"; if [ "$FROM_MANIFEST" = 1 ]; then echo "(link dari yarn.registry di $MANIFEST)"; elif [ -z "${YARN_REGISTRY_URL:-}" ]; then echo "(YARN_REGISTRY_URL kosong -> pakai fallback)"; fi; }
cmd_cache(){ case "${1:-dir}" in dir) echo "$CACHE";; size) du -sh "$CACHE" 2>/dev/null || true;; clean) rm -rf "$CACHE"; mkdir -p "$CACHE"; log "cache dibersihkan";; *) die "cache dir|size|clean";; esac; }
help(){ cat <<H
Pitch Yarn — lockfile ($LOCK) + cache offline
  install [--frozen-lockfile] [--offline] [--production]
  add pkg[@ver] [--dev]    remove pkg    upgrade [pkg...]
  list | registry | init | manifest | cache dir|size|clean
H
}
c="${1:-help}"; [ "$#" -gt 0 ] && shift || true
case "$c" in
  install|i) cmd_install "$@";; add) cmd_add "$@";; remove|rm|uninstall) cmd_remove "$@";;
  upgrade|update) cmd_upgrade "$@";; list|ls) cmd_list;; registry) cmd_registry;;
  cache) cmd_cache "$@";; manifest) echo "manifest: $MANIFEST"; echo "registry: $REGISTRY"; deps "$@";; init) cmd_init;; help|-h|--help) help;; *) die "perintah tidak dikenal: $c";;
esac
