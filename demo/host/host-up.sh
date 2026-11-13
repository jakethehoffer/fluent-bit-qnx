#!/usr/bin/env bash
# Download, verify, and start the pinned Loki and Grafana binaries.
# Loki listens on 0.0.0.0:3100. Grafana listens on 127.0.0.1:3000.
# Archives stay in $HOME/.cache/fluent-bit-qnx-demo and are not part of the repo.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
data="${FBQ_DEMO_DATA_ROOT:-$HOME/.local/share/fluent-bit-qnx-demo}"
cache="${FBQ_DEMO_CACHE:-$HOME/.cache/fluent-bit-qnx-demo}"
versions="$root/demo/host/versions.txt"
run="$data/run"
dash_url="http://127.0.0.1:3000/d/qnx-fleet/qnx-fleet"

declare -A pin_ver pin_file pin_sha

load_pins() {
  local name version filename sha
  while read -r name version filename sha _; do
    case "$name" in
      ''|\#*) continue ;;
    esac
    if [ -z "${sha:-}" ] || [ -z "${filename:-}" ] || [ -z "${version:-}" ]; then
      echo "versions.txt has an incomplete pin" >&2
      exit 1
    fi
    pin_ver["$name"]="$version"
    pin_file["$name"]="$filename"
    pin_sha["$name"]="$sha"
  done <"$versions"
  if [ -z "${pin_sha[loki]:-}" ] || [ -z "${pin_sha[grafana]:-}" ]; then
    echo "versions.txt must pin loki and grafana" >&2
    exit 1
  fi
}

sha256_of() {
  sha256sum "$1" | awk '{print $1}'
}

publisher_sha() {
  local name="$1"
  local dest tmp url got
  case "$name" in
    loki)
      dest="$cache/SHA256SUMS"
      url="https://github.com/grafana/loki/releases/download/v${pin_ver[loki]}/SHA256SUMS"
      ;;
    grafana)
      dest="$cache/${pin_file[grafana]}.sha256"
      url="https://dl.grafana.com/grafana/release/${pin_ver[grafana]}/${pin_file[grafana]}.sha256"
      ;;
    *)
      echo "unknown pin $name" >&2
      return 1
      ;;
  esac
  tmp="$dest.new"
  if curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 180 \
    -o "$tmp" "$url"; then
    mv -f "$tmp" "$dest"
  else
    rm -f "$tmp"
  fi
  if [ ! -f "$dest" ] && [ "$name" = grafana ] && [ -f "$cache/grafana.sha256" ]; then
    dest="$cache/grafana.sha256"
  fi
  if [ ! -f "$dest" ]; then
    echo "publisher checksum for $name is missing" >&2
    return 1
  fi
  if [ "$name" = loki ]; then
    got="$(awk -v file="${pin_file[loki]}" '
      $2 == file || $2 == "*" file { print $1; found = 1; exit }
      END { if (!found) exit 1 }
    ' "$dest")" || {
      echo "publisher checksum for loki does not list ${pin_file[loki]}" >&2
      return 1
    }
  else
    got="$(awk 'NF { print $1; exit }' "$dest")"
  fi
  printf '%s' "$got" | tr -d '[:space:]'
}

require_publisher_pin() {
  local name="$1"
  local published
  published="$(publisher_sha "$name" | tr '[:upper:]' '[:lower:]')"
  pinned="$(printf '%s' "${pin_sha[$name]}" | tr '[:upper:]' '[:lower:]')"
  if [ "$published" != "$pinned" ]; then
    echo "publisher checksum for $name does not match versions.txt" >&2
    exit 1
  fi
}

archive_url() {
  local name="$1"
  case "$name" in
    loki)
      printf 'https://github.com/grafana/loki/releases/download/v%s/%s\n' \
        "${pin_ver[loki]}" "${pin_file[loki]}"
      ;;
    grafana)
      printf 'https://dl.grafana.com/grafana/release/%s/%s\n' \
        "${pin_ver[grafana]}" "${pin_file[grafana]}"
      ;;
  esac
}

ensure_archive() {
  local name="$1"
  local dest="$cache/${pin_file[$name]}"
  local url
  require_publisher_pin "$name"
  if [ -f "$dest" ] && [ "$(sha256_of "$dest")" = "${pin_sha[$name]}" ]; then
    return 0
  fi
  rm -f "$dest"
  url="$(archive_url "$name")"
  echo "downloading $name" >&2
  if ! curl -fsSL --retry 8 --retry-delay 2 --retry-all-errors -C - \
    -o "$dest.partial" "$url"; then
    echo "download failed for $name" >&2
    exit 1
  fi
  mv -f "$dest.partial" "$dest"
  if [ "$(sha256_of "$dest")" != "${pin_sha[$name]}" ]; then
    echo "checksum mismatch for $name" >&2
    rm -f "$dest"
    exit 1
  fi
}

extract_loki() {
  local bin="$cache/loki-linux-amd64"
  local stamp="$cache/loki-linux-amd64.sha"
  if [ -x "$bin" ] && [ "$(cat "$stamp" 2>/dev/null || true)" = "${pin_sha[loki]}" ]; then
    return 0
  fi
  python3 - "$cache/${pin_file[loki]}" "$bin" <<'PY'
import pathlib
import sys
import zipfile

archive = sys.argv[1]
dest = pathlib.Path(sys.argv[2])
with zipfile.ZipFile(archive) as zf:
    names = [
        name for name in zf.namelist()
        if name.endswith("loki-linux-amd64") and ".." not in name.split("/")
    ]
    if len(names) != 1:
        sys.stderr.write("loki archive layout is unexpected\n")
        raise SystemExit(1)
    dest.write_bytes(zf.read(names[0]))
dest.chmod(0o755)
PY
  printf '%s\n' "${pin_sha[loki]}" >"$stamp"
}

extract_grafana() {
  local dest="$cache/grafana"
  local stamp="$cache/grafana.sha"
  local home
  if { [ -x "$dest/bin/grafana-server" ] || [ -x "$dest/bin/grafana" ]; } \
    && [ "$(cat "$stamp" 2>/dev/null || true)" = "${pin_sha[grafana]}" ]; then
    return 0
  fi
  rm -rf "$cache/grafana-unpack" "$dest"
  mkdir -p "$cache/grafana-unpack"
  tar -xzf "$cache/${pin_file[grafana]}" -C "$cache/grafana-unpack"
  home="$(find "$cache/grafana-unpack" -type f \( -path '*/bin/grafana-server' -o -path '*/bin/grafana' \) -printf '%h\n' | head -1)"
  home="$(dirname "$home")"
  if [ ! -x "$home/bin/grafana-server" ] && [ ! -x "$home/bin/grafana" ]; then
    echo "grafana archive layout is unexpected" >&2
    exit 1
  fi
  mv "$home" "$dest"
  rm -rf "$cache/grafana-unpack"
  printf '%s\n' "${pin_sha[grafana]}" >"$stamp"
}

pid_alive() {
  local file="$1"
  local pid cmd
  [ -f "$file" ] || return 1
  pid="$(cat "$file" 2>/dev/null || true)"
  [ -n "${pid:-}" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  cmd="$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)"
  case "$cmd" in
    *loki-linux-amd64*|*grafana-server*|*bin/grafana*) return 0 ;;
    *) return 1 ;;
  esac
}

http_ok() {
  curl -fsS --connect-timeout 2 --max-time 5 -o /dev/null "$1" 2>/dev/null
}

prepare_grafana() {
  local prov="$data/grafana/provisioning"
  local dash="$root/demo/host/grafana/dashboards"
  rm -rf "$prov"
  mkdir -p "$prov/datasources" "$prov/dashboards" "$data/grafana/data"
  cp "$root/demo/host/grafana/provisioning/datasources/loki.yaml" \
    "$prov/datasources/loki.yaml"
  sed "s|__DASHBOARD_DIR__|${dash}|g" \
    "$root/demo/host/grafana/provisioning/dashboards/dashboards.yaml" \
    >"$prov/dashboards/dashboards.yaml"
  if grep -q '__DASHBOARD_DIR__' "$prov/dashboards/dashboards.yaml"; then
    echo "dashboard path was not written" >&2
    exit 1
  fi
}

start_loki() {
  if pid_alive "$run/loki.pid"; then
    return 0
  fi
  if http_ok "http://127.0.0.1:3100/ready"; then
    echo "port 3100 is already in use" >&2
    exit 1
  fi
  export FBQ_DEMO_DATA="$data/loki"
  mkdir -p "$FBQ_DEMO_DATA"
  : >"$run/loki.log"
  nohup "$cache/loki-linux-amd64" \
    -config.file="$root/demo/host/loki.yaml" \
    -config.expand-env=true \
    >>"$run/loki.log" 2>&1 &
  echo $! >"$run/loki.pid"
  disown || true
}

start_grafana() {
  local home="$cache/grafana"
  if pid_alive "$run/grafana.pid"; then
    return 0
  fi
  if http_ok "http://127.0.0.1:3000/api/health"; then
    echo "port 3000 is already in use" >&2
    exit 1
  fi
  prepare_grafana
  : >"$run/grafana.log"
  (
    cd "$home"
    export GF_SERVER_HTTP_ADDR=127.0.0.1
    export GF_SERVER_HTTP_PORT=3000
    export GF_SERVER_ROOT_URL="http://127.0.0.1:3000"
    export GF_AUTH_ANONYMOUS_ENABLED=true
    export GF_AUTH_ANONYMOUS_ORG_ROLE=Viewer
    export GF_AUTH_ANONYMOUS_ORG_NAME="Main Org."
    export GF_USERS_ALLOW_SIGN_UP=false
    export GF_USERS_DEFAULT_THEME=dark
    export GF_ANALYTICS_REPORTING_ENABLED=false
    export GF_ANALYTICS_CHECK_FOR_UPDATES=false
    export GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES=false
    export GF_LOG_LEVEL=warn
    export GF_PATHS_HOME="$home"
    export GF_PATHS_DATA="$data/grafana/data"
    export GF_PATHS_LOGS="$run"
    export GF_PATHS_PROVISIONING="$data/grafana/provisioning"
    export GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH="$root/demo/host/grafana/dashboards/qnx-fleet.json"
    if [ -x "$home/bin/grafana-server" ]; then
      nohup "$home/bin/grafana-server" --homepath="$home" \
        >>"$run/grafana.log" 2>&1 &
    else
      nohup "$home/bin/grafana" server --homepath="$home" \
        >>"$run/grafana.log" 2>&1 &
    fi
    echo $! >"$run/grafana.pid"
    disown || true
  )
}

wait_http() {
  local url="$1"
  local label="$2"
  local pidfile="$3"
  local logfile="$4"
  local i
  for i in $(seq 1 90); do
    if http_ok "$url"; then
      return 0
    fi
    if ! pid_alive "$pidfile"; then
      echo "$label stopped" >&2
      tail -n 40 "$logfile" >&2 || true
      exit 1
    fi
    sleep 1
  done
  echo "$label did not answer" >&2
  tail -n 40 "$logfile" >&2 || true
  exit 1
}

wait_dashboard() {
  local i body
  for i in $(seq 1 40); do
    body="$(curl -fsS --connect-timeout 2 --max-time 5 \
      "http://127.0.0.1:3000/api/search?type=dash-db" 2>/dev/null || true)"
    if printf '%s\n' "$body" | grep -q 'qnx-fleet'; then
      return 0
    fi
    sleep 1
  done
  echo "dashboard was not provisioned" >&2
  tail -n 40 "$run/grafana.log" >&2 || true
  exit 1
}

mkdir -p "$cache" "$run"
load_pins
ensure_archive loki
ensure_archive grafana
extract_loki
extract_grafana
start_loki
start_grafana
wait_http "http://127.0.0.1:3100/ready" Loki "$run/loki.pid" "$run/loki.log"
wait_http "http://127.0.0.1:3000/api/health" Grafana "$run/grafana.pid" "$run/grafana.log"
wait_dashboard
printf '%s\n' "$dash_url"
