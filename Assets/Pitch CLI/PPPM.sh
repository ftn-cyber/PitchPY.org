#!/usr/bin/env bash
# Pitch Performance Manager — cepat: download paralel + cache global. Terpisah dari pitch.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${PITCH_CONF:-$SCRIPT_DIR/pitch.conf}"
# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"

NAME="perf"
FALLBACK="${FALLBACK_REGISTRY_URL:-https://pypi.org/simple}"
REGISTRY="${PERF_REGISTRY_URL:-}"; [ -n "$REGISTRY" ] || REGISTRY="$FALLBACK"
VENV="${PITCH_VENV:-.pitch/venv}"
PY="${PITCH_PYTHON:-python3}"
LOCK="pitch.perf.lock"
MANIFEST="pitch.json"; [ -f pitch.perf.json ] && MANIFEST="pitch.perf.json"; export MANIFEST
FROM_MANIFEST=0
CACHE="${PERF_CACHE_DIR:-$HOME/.pitch/cache/perf}"
JOBS="${PERF_JOBS:-0}"
if ! [ "$JOBS" -gt 0 ] 2>/dev/null; then JOBS="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"; fi

log(){ printf '\033[1;36m[%s]\033[0m %s\n' "$NAME" "$*"; }
die(){ printf '\033[1;31m[%s] error:\033[0m %s\n' "$NAME" "$*" >&2; exit 1; }
command -v "$PY" >/dev/null 2>&1 || die "python3 tidak ditemukan"
manifest_settings(){ "$PY" - <<'PY'
import json,os,shlex
p=(json.load(open(os.environ["MANIFEST"])).get("perf") or {})
def out(k,v):
    if v not in (None,""): print(f"{k}={shlex.quote(str(v))}")
out("M_REGISTRY",p.get("registry")); out("M_JOBS",p.get("jobs"))
c=p.get("cacheFolder"); out("M_CACHE",os.path.expanduser(str(c)) if c else None)
if "useFallback" in p: out("M_FALLBACK","1" if p["useFallback"] else "0")
PY
}
if [ -f "$MANIFEST" ]; then
  eval "$(manifest_settings 2>/dev/null || true)"
  [ -z "${M_REGISTRY:-}" ] || { REGISTRY="$M_REGISTRY"; FROM_MANIFEST=1; }
  [ -z "${M_CACHE:-}" ] || CACHE="$M_CACHE"
  [ -z "${M_FALLBACK:-}" ] || PERF_USE_FALLBACK="$M_FALLBACK"
  if [ -n "${M_JOBS:-}" ] && [ "$M_JOBS" -gt 0 ] 2>/dev/null; then JOBS="$M_JOBS"; fi
fi
mkdir -p "$CACHE"

vbin(){ if [ -d "$VENV/bin" ]; then echo "$VENV/bin"; else echo "$VENV/Scripts"; fi; }
ensure_venv(){ [ -d "$VENV" ] || { log "membuat venv di $VENV"; "$PY" -m venv "$VENV"; }; }
pip_run(){ "$(vbin)/python" -m pip --disable-pip-version-check "$@"; }
index_args(){
  INDEX=(--index-url "$REGISTRY")
  if [ "$REGISTRY" != "$FALLBACK" ] && [ "${PERF_USE_FALLBACK:-1}" = "1" ]; then
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
opt="--optional" in sys.argv[1:]
keys=["optionalDependencies"] if opt else ["dependencies"]+([] if prod else ["devDependencies"])
for k in keys:
    for n,v in (d.get(k) or {}).items(): print(conv(n,res.get(n,v))); seen.add(n)
if not opt:
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

# --- inti performa: coba cache dulu, kalau kurang baru download paralel ---
fetch_parallel(){
  sed '/^$/d' "$1" | tr '\n' '\0' | xargs -0 -n1 -P "$JOBS" \
    "$(vbin)/python" -m pip --disable-pip-version-check download --quiet --progress-bar off -d "$CACHE" "${INDEX[@]}"
}
fast_install(){
  if pip_run install --quiet --no-index --find-links "$CACHE" -r "$1" 2>/dev/null; then log "dipasang dari cache"; return 0; fi
  log "download paralel ($JOBS job) dari $REGISTRY"
  fetch_parallel "$1"
  pip_run install --quiet --no-index --find-links "$CACHE" -r "$1"
}

cmd_init(){
  MANIFEST="pitch.perf.json"; export MANIFEST
  [ -f "$MANIFEST" ] && { log "$MANIFEST sudah ada"; return 0; }
  json_edit init x x 0; log "$MANIFEST dibuat"
}
optional_install(){
  local tmp r; tmp="$(mktemp)"; deps --optional > "$tmp"
  [ -s "$tmp" ] || { rm -f "$tmp"; return 0; }
  log "optional dependencies (kegagalan diabaikan)"
  fetch_parallel "$tmp" 2>/dev/null || true
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    pip_run install --quiet --no-index --find-links "$CACHE" "$r" 2>/dev/null || log "dilewati: $r"
  done < "$tmp"
  rm -f "$tmp"
}
cmd_install(){
  local pk=() a no_opt=0
  for a in "$@"; do case "$a" in --no-optional) no_opt=1;; -*) ;; *) pk+=("$a");; esac; done
  if [ "${#pk[@]}" -gt 0 ]; then cmd_add "$@"; return; fi
  ensure_venv; index_args
  local tmp; tmp="$(mktemp)"; deps "$@" > "$tmp"
  if [ ! -s "$tmp" ]; then log "tidak ada dependency di $MANIFEST"; rm -f "$tmp"; return 0; fi
  fast_install "$tmp"; rm -f "$tmp"; [ "$no_opt" = 1 ] || optional_install; write_lock; log "selesai"
}
cmd_add(){
  local dev=0 list=() a pin v tmp
  for a in "$@"; do case "$a" in --dev|-D) dev=1;; -*) ;; *) list+=("$a");; esac; done
  [ "${#list[@]}" -gt 0 ] || die "sebutkan nama package"
  ensure_venv; index_args; tmp="$(mktemp)"
  for a in "${list[@]}"; do parse_pkg "$a"; echo "$P_REQ" >> "$tmp"; done
  fast_install "$tmp"; rm -f "$tmp"
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
cmd_update(){
  ensure_venv; index_args
  local tmp; tmp="$(mktemp)"; deps > "$tmp"
  if [ -s "$tmp" ]; then fetch_parallel "$tmp"; pip_run install --quiet --upgrade --no-index --find-links "$CACHE" -r "$tmp"; fi
  rm -f "$tmp"; write_lock
}
cmd_list(){ ensure_venv; pip_run list; }
cmd_registry(){ echo "$NAME registry : $REGISTRY"; echo "cache         : $CACHE"; echo "jobs          : $JOBS"; if [ "$FROM_MANIFEST" = 1 ]; then echo "(link dari perf.registry di $MANIFEST)"; elif [ -z "${PERF_REGISTRY_URL:-}" ]; then echo "(PERF_REGISTRY_URL kosong -> pakai fallback)"; fi; }
cmd_cache(){ case "${1:-dir}" in dir) echo "$CACHE";; size) du -sh "$CACHE" 2>/dev/null || true;; clean) rm -rf "$CACHE"; mkdir -p "$CACHE"; log "cache dibersihkan";; *) die "cache dir|size|clean";; esac; }
help(){ cat <<H
Pitch Performance Manager — download paralel + cache global
  install [pkg...] [--production]
  add pkg[@ver] [--dev]    remove pkg    update
  list | registry | init | manifest | cache dir|size|clean
  install --no-optional   lewati optionalDependencies
H
}
c="${1:-help}"; [ "$#" -gt 0 ] && shift || true
case "$c" in
  install|i) cmd_install "$@";; add) cmd_add "$@";; remove|rm|uninstall) cmd_remove "$@";;
  update|upgrade) cmd_update "$@";; list|ls) cmd_list;; registry) cmd_registry;;
  cache) cmd_cache "$@";; manifest) echo "manifest: $MANIFEST"; echo "registry: $REGISTRY  jobs: $JOBS"; deps "$@"; echo "# optional:"; deps --optional;; init) cmd_init;; help|-h|--help) help;; *) die "perintah tidak dikenal: $c";;
esac
