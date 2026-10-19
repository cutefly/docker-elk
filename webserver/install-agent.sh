#!/usr/bin/env bash
#
# Elastic Agent standalone 설치·설정 스크립트 (Fleet 미사용)
#
#   nginx/apache 로그 → Elastic Agent → Logstash(5044) → Elasticsearch
#
# 사용법 (웹서버 호스트에서, 이 스크립트와 elastic-agent/ 폴더를 함께 복사한 뒤):
#   sudo ./install-agent.sh                                           # 기본 Logstash(192.168.219.131:5044), nginx/apache 자동 감지
#   sudo ./install-agent.sh --logstash 192.168.219.131:5044 --target nginx
#   sudo ./install-agent.sh --logstash 192.168.219.131:5044 --dry-run        # 설정 파일만 만들어 보기
#
# 옵션:
#   --logstash  HOST:PORT[,HOST:PORT]  Logstash 주소 (기본 192.168.219.131:5044, LOGSTASH 환경변수로도 지정)
#   --target    nginx|apache|both|auto (기본 auto: 로그 디렉터리로 감지)
#   --version   Agent 버전 (기본: ELASTIC_VERSION 환경변수 또는 9.5.5, ES 버전과 맞출 것)
#   --namespace data stream namespace (기본 default)
#   --dry-run   설치하지 않고 생성될 elastic-agent.yml만 출력
#
# 로그 경로를 바꾸려면 환경변수를 쓴다(기본값은 Ubuntu apt 패키지 기준):
#   NGINX_ACCESS_PATH  (/var/log/nginx/access.log*)
#   NGINX_ERROR_PATH   (/var/log/nginx/error.log*)
#   APACHE_ACCESS_PATH (/var/log/apache2/access.log*)
#   APACHE_ERROR_PATH  (/var/log/apache2/error.log*)
#   예) sudo NGINX_ACCESS_PATH='/srv/nginx/logs/access*.log' ./install-agent.sh ...

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TPL_DIR="${SCRIPT_DIR}/elastic-agent"

LOGSTASH="${LOGSTASH:-192.168.219.131:5044}"
TARGET="auto"
VERSION="${ELASTIC_VERSION:-9.5.5}"
NAMESPACE="default"
DRY_RUN=0

NGINX_ACCESS_PATH="${NGINX_ACCESS_PATH:-/var/log/nginx/access.log*}"
NGINX_ERROR_PATH="${NGINX_ERROR_PATH:-/var/log/nginx/error.log*}"
APACHE_ACCESS_PATH="${APACHE_ACCESS_PATH:-/var/log/apache2/access.log*}"
APACHE_ERROR_PATH="${APACHE_ERROR_PATH:-/var/log/apache2/error.log*}"

AGENT_HOME="/opt/Elastic/Agent"

# 메시지는 stderr로 보낸다(--dry-run 출력은 stdout에 YAML만 남도록).
info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
	case "$1" in
		--logstash)  LOGSTASH="${2:-}"; shift 2 ;;
		--target)    TARGET="${2:-}"; shift 2 ;;
		--version)   VERSION="${2:-}"; shift 2 ;;
		--namespace) NAMESPACE="${2:-}"; shift 2 ;;
		--dry-run)   DRY_RUN=1; shift ;;
		-h|--help)   sed -n '2,27p' "$0"; exit 0 ;;
		*)           fail "알 수 없는 옵션: $1 (--help 참고)" ;;
	esac
done

[[ -n "$LOGSTASH" ]] || fail "--logstash HOST:PORT 를 지정하세요."
[[ -d "$TPL_DIR" ]]  || fail "템플릿 폴더가 없습니다: $TPL_DIR (elastic-agent/ 폴더를 스크립트와 같이 복사하세요)"
[[ "$NAMESPACE" =~ ^[a-z0-9_]+$ ]] || fail "namespace는 소문자/숫자/_ 만 쓸 수 있습니다: $NAMESPACE"

# ---------------------------------------------------------------------------
# 1. 대상 결정
# ---------------------------------------------------------------------------
has_glob() { compgen -G "$1" > /dev/null; }

if [[ "$TARGET" == "auto" ]]; then
	t=()
	{ has_glob "$NGINX_ACCESS_PATH"  || has_glob "$NGINX_ERROR_PATH";  } && t+=(nginx)
	{ has_glob "$APACHE_ACCESS_PATH" || has_glob "$APACHE_ERROR_PATH"; } && t+=(apache)
	case "${#t[@]}" in
		0) fail "nginx/apache 로그 파일을 찾지 못했습니다. --target 과 *_PATH 환경변수를 확인하세요." ;;
		2) TARGET="both" ;;
		*) TARGET="${t[0]}" ;;
	esac
	info "자동 감지된 대상: $TARGET"
fi

case "$TARGET" in
	nginx)  FRAGMENTS=(inputs-nginx.yml) ;;
	apache) FRAGMENTS=(inputs-apache.yml) ;;
	both)   FRAGMENTS=(inputs-nginx.yml inputs-apache.yml) ;;
	*)      fail "--target 은 nginx|apache|both|auto 중 하나여야 합니다: $TARGET" ;;
esac

# ---------------------------------------------------------------------------
# 2. elastic-agent.yml 생성
# ---------------------------------------------------------------------------
# "a:5044,b:5044" → "a:5044", "b:5044"
LS_HOSTS="$(printf '%s' "$LOGSTASH" | awk -F, '{for(i=1;i<=NF;i++){gsub(/ /,"",$i); printf "%s\"%s\"", (i>1?", ":""), $i}}')"

# sed 치환용 이스케이프(구분자 #, &, \ 처리)
esc() { printf '%s' "$1" | sed -e 's/[#&\\]/\\&/g'; }

render() {
	cat "$TPL_DIR/base.yml"
	for f in "${FRAGMENTS[@]}"; do cat "$TPL_DIR/$f"; done
}

GENERATED="$(render | sed \
	-e "s#__LOGSTASH_HOSTS__#$(esc "$LS_HOSTS")#g" \
	-e "s#__NAMESPACE__#$(esc "$NAMESPACE")#g" \
	-e "s#__NGINX_ACCESS_PATH__#$(esc "$NGINX_ACCESS_PATH")#g" \
	-e "s#__NGINX_ERROR_PATH__#$(esc "$NGINX_ERROR_PATH")#g" \
	-e "s#__APACHE_ACCESS_PATH__#$(esc "$APACHE_ACCESS_PATH")#g" \
	-e "s#__APACHE_ERROR_PATH__#$(esc "$APACHE_ERROR_PATH")#g")"

if grep -q '__[A-Z_]*__' <<< "$GENERATED"; then
	fail "치환되지 않은 값이 남아 있습니다: $(grep -o '__[A-Z_]*__' <<< "$GENERATED" | sort -u | tr '\n' ' ')"
fi

if [[ $DRY_RUN -eq 1 ]]; then
	info "dry-run: 생성될 elastic-agent.yml"
	printf '%s\n' "$GENERATED"
	exit 0
fi

# ---------------------------------------------------------------------------
# 3. 사전 점검
# ---------------------------------------------------------------------------
[[ $EUID -eq 0 ]] || fail "root 권한이 필요합니다 (sudo로 실행하세요)."

info "Logstash 연결 확인"
IFS=',' read -ra LS_LIST <<< "$LOGSTASH"
for hp in "${LS_LIST[@]}"; do
	hp="${hp// /}"
	h="${hp%:*}"; p="${hp##*:}"
	if timeout 3 bash -c "</dev/tcp/$h/$p" 2>/dev/null; then
		ok "$hp 연결 가능"
	else
		fail "$hp 에 연결할 수 없습니다. ELK 호스트의 5044 포트·방화벽을 확인하세요."
	fi
done

info "로그 파일 확인"
check_path() {
	local label="$1" pattern="$2"
	if has_glob "$pattern"; then
		for f in $pattern; do
			[[ -f "$f" ]] || continue
			local size; size=$(stat -c %s "$f")
			if [[ "$f" != *.gz && $size -lt 1024 ]]; then
				warn "$label $f : ${size}B. filestream은 앞부분 1KB로 파일을 식별하므로, 1KB가 쌓일 때까지 수집하지 않습니다."
			else
				ok "$label $f (${size}B)"
			fi
		done
	else
		warn "$label 경로에 파일이 없습니다: $pattern (파일이 생기면 자동으로 수집합니다)"
	fi
}
if [[ "$TARGET" == nginx || "$TARGET" == both ]]; then
	check_path "nginx access" "$NGINX_ACCESS_PATH"
	check_path "nginx error " "$NGINX_ERROR_PATH"
fi
if [[ "$TARGET" == apache || "$TARGET" == both ]]; then
	check_path "apache access" "$APACHE_ACCESS_PATH"
	check_path "apache error " "$APACHE_ERROR_PATH"
fi

# ---------------------------------------------------------------------------
# 4. 설치 또는 설정 교체
# ---------------------------------------------------------------------------
write_config() {
	local dest="$1"
	if [[ -f "$dest" ]]; then
		cp -p "$dest" "${dest}.bak.$(date +%Y%m%d%H%M%S)"
		info "기존 설정 백업: ${dest}.bak.*"
	fi
	printf '%s\n' "$GENERATED" > "$dest"
	chown root:root "$dest"
	chmod 600 "$dest"
}

if [[ -x "$AGENT_HOME/elastic-agent" ]] || command -v elastic-agent > /dev/null 2>&1; then
	warn "Elastic Agent가 이미 설치되어 있습니다. 설정만 교체하고 재시작합니다."
	warn "Fleet에 등록된 Agent라면 로컬 설정이 무시됩니다. 그 경우 'sudo elastic-agent uninstall' 후 다시 실행하세요."
	write_config "$AGENT_HOME/elastic-agent.yml"
	systemctl restart elastic-agent
else
	case "$(uname -m)" in
		x86_64)        ARCH="x86_64" ;;
		aarch64|arm64) ARCH="arm64" ;;
		*)             fail "지원하지 않는 아키텍처: $(uname -m)" ;;
	esac
	PKG="elastic-agent-${VERSION}-linux-${ARCH}"
	URL="https://artifacts.elastic.co/downloads/beats/elastic-agent/${PKG}.tar.gz"
	WORK="$(mktemp -d)"
	trap 'rm -rf "$WORK"' EXIT

	info "다운로드: $URL"
	curl -fsSL -o "$WORK/${PKG}.tar.gz"        "$URL"        || fail "다운로드 실패 (버전 ${VERSION} 확인)"
	curl -fsSL -o "$WORK/${PKG}.tar.gz.sha512" "${URL}.sha512" || fail "체크섬 다운로드 실패"
	( cd "$WORK" && sha512sum -c "${PKG}.tar.gz.sha512" > /dev/null ) || fail "체크섬 불일치"
	ok "체크섬 확인"

	tar -xzf "$WORK/${PKG}.tar.gz" -C "$WORK"
	# 설치 전에 설정을 넣어 두면 install이 그대로 복사한다.
	write_config "$WORK/${PKG}/elastic-agent.yml"

	info "standalone 모드로 설치 (Fleet 등록 안 함)"
	"$WORK/${PKG}/elastic-agent" install --non-interactive --force
fi

# ---------------------------------------------------------------------------
# 5. 상태 확인
# ---------------------------------------------------------------------------
info "Agent 상태 확인 (최대 60초 대기)"
for _ in $(seq 1 12); do
	if elastic-agent status 2>/dev/null | grep -qi 'healthy'; then
		break
	fi
	sleep 5
done
elastic-agent status || true

cat <<EOF

다음 단계:
  1) 웹 요청을 몇 번 보내 로그를 만든 뒤(1KB 이상), Kibana Dev Tools에서 verify-ingest.txt를 실행하세요.
  2) 상세 상태:   sudo elastic-agent status --output=full
  3) Agent 로그:  sudo ls $AGENT_HOME/data/elastic-agent-*/logs/
EOF
