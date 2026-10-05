#!/usr/bin/env bash
# PPM — Pitch Package Manager (normal). Berdiri sendiri, terpisah dari pitch.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${PITCH_CONF:-$SCRIPT_DIR/pitch.conf}"
# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"

NAME="ppm"
FALLBACK="${FALLBACK_REGISTRY_URL:-https://pypi.org/simple}"
REGISTRY="${PPM_REGISTRY_URL:-}"; [ -n "$REGISTRY" ] || REGISTRY="$FALLBACK"
VENV="${PITCH_VENV:-.pitch/venv}"
PY="${PITCH_PYTHON:-python3}"
LOCK="pitch.lock"

log(){ printf '\033[1;33m[%s]\033[0m %s\n' "$NAME" "$*"; }
die(){ printf '\033[1;31m[%s] error:\033[0m %s\n' "$NAME" "$*" >&2; exit 1; }
command -v "$PY" >/dev/null 2>&1 || die "python3 tidak ditemukan"

vbin(){ if [ -d "$VENV/bin" ]; then echo "$VENV/bin"; else echo "$VENV/Scripts"; fi; }
ensure_venv(){ [ -d "$VENV" ] || { log "membuat venv di $VENV"; "$PY" -m venv "$VENV"; }; }
pip_run(){ "$(vbin)/python" -m pip --disable-pip-version-check "$@"; }
index_args(){
  INDEX=(--index-url "$REGISTRY")
  if [ "$REGISTRY" != "$FALLBACK" ] && [ "${PPM_USE_FALLBACK:-1}" = "1" ]; then
    INDEX+=(--extra-index-url "$FALLBACK"); fi
  case "$REGISTRY" in http://*) local h="${REGISTRY#http://}"; h="${h%%[/:]*}"; INDEX+=(--trusted-host "$h");; esac
}
parse_pkg(){
  local s="$1"
  if [[ "$s" == *@* ]]; then P_NAME="${s%%@*}"; P_REQ="${P_NAME}==${s#*@}"; else P_NAME="$s"; P_REQ="$s"; fi
  P_NAME="${P_NAME%%\[*}"; P_NAME="${P_NAME%%[<>=~!]*}"
}
installed_ver(){ pip_run show "$1" 2>/dev/null | awk '/^Version:/{print $2}'; }
write_lock(){ pip_run freeze --exclude pip --exclude setuptools --exclude wheel > "$LOCK" 2>/dev/null || true; }

deps(){ "$PY" - "$@" <<'PY'
import json,re,sys,os
prod="--production" in sys.argv[1:]
if not os.path.exists("pitch.json"): sys.exit(0)
d=json.load(open("pitch.json"))
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
for k in ["dependencies"]+([] if prod else ["devDependencies"]):
    for n,v in (d.get(k) or {}).items(): print(conv(n,v))
PY
}
json_edit(){ "$PY" - "$@" <<'PY'
import json,os,sys
action,name,ver,dev=sys.argv[1:5]
f="pitch.json"
d=json.load(open(f)) if os.path.exists(f) else {"name":os.path.basename(os.getcwd()),"version":"1.0.0"}
if action=="add":
    d.setdefault("devDependencies" if dev=="1" else "dependencies",{})[name]=ver or "*"
else:
    for k in ("dependencies","devDependencies","optionalDependencies"): (d.get(k) or {}).pop(name,None)
json.dump(d,open(f,"w"),indent=2,ensure_ascii=False); open(f,"a").write("\n")
PY
}

cmd_init(){
  [ -f pitch.json ] && { log "pitch.json sudah ada"; return 0; }
  json_edit init x x 0; log "pitch.json dibuat"
}
cmd_install(){
  local pk=() a
  for a in "$@"; do case "$a" in --production) ;; -*) ;; *) pk+=("$a");; esac; done
  if [ "${#pk[@]}" -gt 0 ]; then cmd_add "$@"; return; fi
  ensure_venv; index_args
  local tmp; tmp="$(mktemp)"; deps "$@" > "$tmp"
  if [ ! -s "$tmp" ]; then log "tidak ada dependency di pitch.json"; rm -f "$tmp"; return 0; fi
  log "registry: $REGISTRY"
  pip_run install "${INDEX[@]}" -r "$tmp"
  rm -f "$tmp"; write_lock; log "selesai"
}
cmd_add(){
  local dev=0 list=() a pin v
  for a in "$@"; do case "$a" in --dev|-D) dev=1;; -*) ;; *) list+=("$a");; esac; done
  [ "${#list[@]}" -gt 0 ] || die "sebutkan nama package"
  ensure_venv; index_args
  for a in "${list[@]}"; do
    parse_pkg "$a"; log "add $P_REQ"
    pip_run install "${INDEX[@]}" "$P_REQ"
    pin=""; [[ "$a" == *@* ]] && pin="${a#*@}"
    v="$(installed_ver "$P_NAME")"
    json_edit add "$P_NAME" "${pin:-${v:+^$v}}" "$dev"
  done
  write_lock
}
cmd_remove(){
  [ "$#" -gt 0 ] || die "sebutkan nama package"
  ensure_venv
  for a in "$@"; do parse_pkg "$a"; pip_run uninstall -y "$P_NAME" || true; json_edit remove "$P_NAME" "" 0; done
  write_lock
}
cmd_update(){
  ensure_venv; index_args
  local tmp; tmp="$(mktemp)"; deps > "$tmp"
  [ -s "$tmp" ] && pip_run install --upgrade "${INDEX[@]}" -r "$tmp"
  rm -f "$tmp"; write_lock
}
cmd_list(){ ensure_venv; pip_run list; }
cmd_registry(){ echo "$NAME registry : $REGISTRY"; [ -n "${PPM_REGISTRY_URL:-}" ] || echo "(PPM_REGISTRY_URL kosong -> pakai fallback)"; }
cmd_cache(){ ensure_venv; case "${1:-dir}" in dir) pip_run cache dir;; clean) pip_run cache purge;; *) die "cache dir|clean";; esac; }
help(){ cat <<H
PPM — Pitch Package Manager (normal)
  install [pkg...] [--production]   install dari pitch.json / package tertentu
  add pkg[@ver] [--dev]             tambah package + catat ke pitch.json
  remove pkg                        hapus package
  update                            upgrade semua dependency
  list | registry | cache | init
H
}
c="${1:-help}"; [ "$#" -gt 0 ] && shift || true
case "$c" in
  install|i) cmd_install "$@";; add) cmd_add "$@";; remove|rm|uninstall) cmd_remove "$@";;
  update|upgrade) cmd_update "$@";; list|ls) cmd_list;; registry) cmd_registry;;
  cache) cmd_cache "$@";; init) cmd_init;; help|-h|--help) help;; *) die "perintah tidak dikenal: $c";;
esac
