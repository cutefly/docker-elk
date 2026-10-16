# Ubuntu 호스트 nginx(apt 설치) 로그 수집 절차

작성일: 2026-10-16 · 기존 설계(`webserver-logging-plan.md`)의 방식(Elastic Agent + Fleet + nginx Integration, ECS)을 그대로 사용한다.

## 0. NPM과 다른 점

| 항목 | NPM (컨테이너) | Ubuntu 호스트 nginx |
|---|---|---|
| 기본 로그 포맷 | 자체 `proxy` 포맷 (Integration 파싱 불가) | **`combined`** (Integration이 그대로 파싱) |
| 로그 경로 | `<NPM_DATA>/logs/` (볼륨 경로 확인 필요) | `/var/log/nginx/` (Integration 기본값과 같음) |
| 설정 추가 위치 | `/data/nginx/custom/*.conf` | `/etc/nginx/conf.d/*.conf` |
| stub_status | docker gateway 대역 허용 필요 | loopback 전용 포트로 단순하게 구성 |
| 타임존 | 컨테이너와 호스트를 맞춰야 함 | **문제 없음** (nginx와 Agent가 같은 호스트 시간을 사용) |
| docker integration | 필요 (NPM 컨테이너 메트릭) | 불필요 (system integration만 사용) |

## 1. 구성 결정

### 1-1. 로그 포맷: 단일 사이트인가, 다중 vhost인가

| 경우 | 선택 | 작업량 |
|---|---|---|
| **사이트가 하나**이거나 도메인 구분이 필요 없음 | 기본 `combined` 그대로 사용 | nginx 설정 변경 없음 (stub_status만 추가) |
| **vhost가 여러 개**이고 도메인별 분석이 필요함 | `ecs_combined` (`$host` 접두어) 추가 | conf.d 파일 1개 추가. 포맷은 NPM과 같아서 이미 파싱 검증됨 |

NPM과 같은 기준(`destination.domain`)으로 함께 분석하려면 `ecs_combined`를 권장한다. 이하 절차는 `ecs_combined` 기준이다. 기본 포맷을 쓴다면 Step 2-1, 2-3을 건너뛰고, Step 4의 Access 경로를 `/var/log/nginx/access.log*`로 둔다.

### 1-2. 이 nginx가 어느 호스트에 있는가

| 경우 | 정책 구성 |
|---|---|
| **NPM과 다른 Ubuntu 서버** | 새 정책 `Nginx Host Policy`를 만들고 그 서버에 Agent를 새로 설치 |
| **NPM과 같은 서버** | 기존 `Webserver Policy`에 nginx Integration을 **하나 더 추가**한다(이름을 다르게). Agent 추가 설치는 필요 없다. 80/443은 NPM이 쓰고 있으므로 호스트 nginx의 리슨 포트가 겹치지 않는지 확인한다. |

Agent 정책 하나는 그 정책에 속한 모든 Agent에 같은 설정(로그 경로 등)을 내려보낸다. 그래서 경로가 다른 NPM 서버와 호스트 nginx 서버를 **같은 정책에 묶으면 안 된다**.

## Step 1. 사전 점검 (nginx 서버)

```bash
nginx -v
nginx -V 2>&1 | grep -o http_stub_status_module          # 출력되어야 stub_status 사용 가능
grep -n 'access_log\|include' /etc/nginx/nginx.conf       # conf.d include가 http {} 안에 있는지
grep -rn 'access_log' /etc/nginx/sites-enabled/ /etc/nginx/conf.d/   # vhost별 access_log 지정 여부
ls -l /var/log/nginx/
ss -ltnp | grep -E ':80 |:443 |:8080 '                    # 포트 사용 현황 (8080은 stub_status용)
timedatectl | grep 'Time zone'
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.219.126:9200   # 401이면 정상
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.219.126:8220/api/status   # 200이면 정상
```

## Step 2. nginx 설정 (`/etc/nginx/conf.d/`에 파일 추가)

저장소의 `webserver/nginx-host/conf.d/` 아래 파일 2개를 사용한다. 기존 `nginx.conf`와 사이트 설정은 원칙적으로 수정하지 않는다.

1. **로그 포맷과 추가 access log**: `ecs-logging.conf`를 `/etc/nginx/conf.d/`에 복사한다.
   - `ecs_combined` 포맷을 정의하고, http 레벨에 `/var/log/nginx/ecs_access.log`를 추가로 기록한다.
   - 기존 `access.log`는 그대로 유지된다. 같은 레벨에 `access_log`가 여러 개 있으면 nginx는 모두 기록한다.
2. **stub_status**: `nginx-status.conf`를 복사한다. `127.0.0.1:8080/nginx_status`로만 열린다. 8080이 이미 사용 중이면 다른 포트로 바꾼다.
3. **vhost별 access_log 확인**: Step 1에서 `sites-enabled/`에 자체 `access_log`를 지정한 server 블록이 있다면, 그 vhost는 http 레벨 설정을 **상속하지 않는다**. 해당 server 블록 안에 다음 한 줄을 추가한다.
   ```nginx
   access_log /var/log/nginx/ecs_access.log ecs_combined;
   ```
4. **반영 및 확인**:
   ```bash
   sudo nginx -t && sudo systemctl reload nginx
   curl -s http://127.0.0.1:8080/nginx_status          # Active connections ... 출력 확인
   curl -s -o /dev/null -H 'Host: <서비스 도메인>' http://127.0.0.1/
   tail -n2 /var/log/nginx/ecs_access.log              # "<도메인> <IP> - - [..+0900] ..." 형태
   ```
5. **로그 로테이션**: Ubuntu 기본 `/etc/logrotate.d/nginx`가 `/var/log/nginx/*.log`를 처리하므로 `ecs_access.log`도 자동으로 로테이션된다. 압축 파일(`.gz`)은 Integration 경로에서 제외한다.

## Step 3. Fleet 정책 (Kibana UI)

### A. 다른 서버인 경우 — 새 정책

1. **Fleet → Agent policies → Create agent policy**
   - Name: `Nginx Host Policy`
   - Collect system logs and metrics: **체크**
   - Default namespace: `Webserver Policy`와 같은 값 (`default` 또는 `prod`)
2. **Add integration → Nginx**: Integration name은 `nginx-host`로 하고, 정책은 `Nginx Host Policy`를 선택한다.

### B. NPM과 같은 서버인 경우 — 기존 정책에 추가

- **Webserver Policy → Add integration → Nginx**: Integration name은 `nginx-host`로 한다. 기존 `nginx-npm`과 다른 이름이어야 한다.
- docker와 system Integration은 이미 있으므로 추가하지 않는다.

### 공통 nginx Integration 입력값

| 항목 | 값 |
|---|---|
| Access logs Paths | `/var/log/nginx/ecs_access.log*` (기본 포맷을 쓰면 `/var/log/nginx/access.log*`) |
| Error logs Paths | `/var/log/nginx/error.log*` |
| Exclude files | `\.gz$` 포함 여부 확인 |
| Metrics Hosts | `http://127.0.0.1:8080` |
| Server status path | `/nginx_status` |
| Tags (access, error 각각) | `nginx-host` (NPM 쪽은 `nginx-npm` 태그를 권장) |

> **같은 dataset 구분**: NPM과 호스트 nginx의 데이터는 모두 `logs-nginx.access-<ns>`로 들어간다. 서버가 다르면 `host.name`으로 구분된다. 같은 서버라면 **tags**나 `log.file.path`로 구분한다.

정책을 만든 뒤에는 JSON으로 내보내 `docs/`에 보관한다(`GET kbn:/api/fleet/agent_policies/<id>/full`).

## Step 4. Agent 설치 (A. 다른 서버인 경우만)

**권장**: 호스트 nginx 전용 스크립트 `webserver/nginx-host/install-agent-nginx-host.sh`를 사용한다. 이 스크립트는 Step 1의 사전 점검과 설치를 함께 수행한다.

```bash
sudo ./install-agent-nginx-host.sh --check-only                 # 점검만
sudo ./install-agent-nginx-host.sh --token <Nginx Host Policy 토큰>   # 점검 후 설치
```

수동으로 설치하려면 아래와 같이 한다. NPM용 `install-agent.sh`는 NPM 전용 점검이 들어 있어서 여기서는 쓰지 않는다.

```bash
VER=9.5.5                       # docker-elk .env 의 ELASTIC_VERSION
ARCH=$(uname -m | sed 's/aarch64/arm64/')
PKG=elastic-agent-${VER}-linux-${ARCH}
curl -fL -O https://artifacts.elastic.co/downloads/beats/elastic-agent/${PKG}.tar.gz
curl -fL -O https://artifacts.elastic.co/downloads/beats/elastic-agent/${PKG}.tar.gz.sha512
sha512sum -c ${PKG}.tar.gz.sha512
tar xzf ${PKG}.tar.gz
sudo ./${PKG}/elastic-agent install --non-interactive \
     --url=http://192.168.219.126:8220 \
     --enrollment-token=<Nginx Host Policy의 enrollment token> --insecure
```

**토큰은 반드시 `Nginx Host Policy`의 것을 사용한다.** 이전에 정책을 만들지 않은 채 다른 정책의 토큰으로 등록되어 nginx 수집이 빠졌던 문제가 있었다. Fleet → Enrollment tokens에서 Policy 열을 확인한다.

Agent는 root로 동작하므로 `/var/log/nginx/`(소유 `www-data:adm`, 권한 640)를 읽을 수 있다. `--unprivileged` 옵션으로 설치했다면 Agent 사용자를 `adm` 그룹에 추가해야 한다.

## Step 5. 검증

```bash
# nginx 서버
sudo elastic-agent status --output=full | grep -iA3 nginx      # nginx 컴포넌트 HEALTHY
stat -c 'size=%s' /var/log/nginx/ecs_access.log                # 1KB 미만이면 요청을 더 보낸다
```

Kibana Dev Tools에서는 `webserver/nginx-proxy-manager/verify-ingest.txt`의 쿼리를 그대로 쓴다. 이 서버의 데이터만 보려면 각 쿼리의 `query`에 `host.name` 조건을 추가한다.

```
GET logs-nginx.access-*/_search?filter_path=hits.hits._source
{
  "size": 1,
  "sort": [ { "@timestamp": "desc" } ],
  "query": { "term": { "host.name": "<nginx 서버 hostname>" } },
  "_source": [ "@timestamp", "host.name", "tags", "destination.domain", "source.ip",
               "http.response.status_code", "url.original", "user_agent.name" ]
}
```

대시보드 `[Logs Nginx] Access and error logs`, `[Metrics Nginx] Overview`, `[Metrics System] Host overview`에서 `host.name` 필터로 이 서버의 데이터가 보이는지 확인한다.

## 부록. NPM → nginx 구조에서 실제 사용자 IP 기록

사용자 → NPM → 이 nginx 순서로 요청이 들어오므로, 이 nginx의 `$remote_addr`는 NPM 서버 IP가 된다. 그러면 ELK의 `source.ip`와 GeoIP도 전부 NPM 주소로 기록된다. NPM이 기본으로 전달하는 `X-Forwarded-For`, `X-Real-IP` 헤더를 realip 모듈로 복원한다.

1. **NPM이 실제 IP를 보고 있는지 먼저 확인** (NPM 서버):
   `tail <NPM_DATA>/logs/ecs_access.log` 결과의 두 번째 필드가 외부 사용자 IP여야 한다. 여기에 `172.x.x.x`(Docker gateway)나 공유기 IP만 찍힌다면, NPM 앞단(공유기 NAT, docker-proxy 등)에서 이미 IP가 사라진 것이다. 이 경우 그 단계를 먼저 해결해야 한다.
2. **신뢰할 프록시 주소 확인** (이 nginx 서버): `tail -n3 /var/log/nginx/ecs_access.log`의 두 번째 필드가 현재 NPM 서버 IP다. 보통 NPM 서버의 LAN IP다.
3. **realip 모듈 확인**: `nginx -V 2>&1 | grep -o http_realip_module`. Ubuntu 패키지에는 기본으로 포함되어 있다.
4. **설정 적용**: `webserver/nginx-host/conf.d/real-ip.conf`의 `<NPM_SERVER_IP>`를 2번에서 확인한 IP로 바꾼다. 그다음 `/etc/nginx/conf.d/`에 복사하고 `sudo nginx -t && sudo systemctl reload nginx`로 반영한다.
5. **검증**:
   - 외부망(모바일 등)에서 접속한 뒤 `tail /var/log/nginx/ecs_access.log`를 보면 두 번째 필드에 실제 공인 IP가 찍혀야 한다.
   - 위조 방지 확인: `curl -H 'X-Forwarded-For: 1.2.3.4' https://<도메인>/`으로 요청했을 때 `1.2.3.4`가 아니라 실제 IP가 찍혀야 한다.
   - Kibana에서 `host.name : <nginx 서버>` 조건으로 `source.ip`와 `source.geo.*`를 확인한다.

**주의**

- **신뢰 대상:** `set_real_ip_from`에는 NPM 서버 IP만 넣는다. 넓은 대역을 넣으면 누구나 헤더로 IP를 위조할 수 있다.
- **이중 집계:** 같은 요청이 NPM 로그와 이 nginx 로그에 **두 번** 기록된다. 두 서버를 합쳐서 요청 수를 세면 두 배가 되므로, 대시보드에서는 `host.name`이나 tags(`nginx-npm` / `nginx-host`)로 한쪽을 골라서 본다. 일반적으로 외부 트래픽 분석은 NPM 기준, 백엔드 처리 분석은 이 nginx 기준으로 본다.
- **직접 접속 차단 (선택):** 방화벽으로 이 nginx의 80/443 포트를 NPM 서버에서만 접근하게 막으면, NPM을 우회한 직접 접속을 차단할 수 있다.

## 문제 해결

| 증상 | 확인 |
|---|---|
| `elastic-agent status`에 nginx 없음 | Agent에 할당된 정책 확인 (Fleet → Agents → Agent policy 열) |
| access 0건 | `ecs_access.log`가 1KB 이상인지, 정책 경로에 오타가 없는지, vhost별 `access_log` 상속 문제(Step 2-3)가 아닌지 확인 |
| stubstatus 오류 | `curl http://127.0.0.1:8080/nginx_status` 확인, Integration의 Hosts 포트가 맞는지 확인 |
| `/nginx_status` 404 | ① Integration Hosts가 NPM 값(`:80`)으로 남아 있어 기본 사이트가 응답 → `http://127.0.0.1:8080`으로 수정 ② `nginx -T`에 `nginx_status`가 없음 → conf.d 미적용 ③ 8080을 다른 프로세스가 점유(`ss -ltnp`) → reload 시 bind 실패, 포트 변경 ④ 응답 본문이 `nginx-status server: unknown path`면 경로 오타(`/nginx_status/` 등) |
| `error.message` 발생 | 해당 vhost가 다른 log_format을 쓰는지 확인 (`grep -rn log_format /etc/nginx/`) |
