# 웹서버 로그 수집 파이프라인 작업 절차 설계 (nginx → apache)

작성일: 2026-10-15 (rev.2 — Nginx Proxy Manager 환경 반영) · 대상 스택: docker-elk (ELASTIC_VERSION=9.5.5)

## 0. 확정된 환경

| 항목 | 내용 |
|---|---|
| ELK | 192.168.219.126, docker-elk (Docker Compose) |
| 웹서버 | ELK와 **다른 호스트**의 Ubuntu 서버. 같은 네트워크에 있으며 8220·9200 포트에 접속 가능 |
| nginx | **Nginx Proxy Manager(NPM)** 컨테이너 (`jc21/nginx-proxy-manager`) |
| apache | 2차 확장 대상 (호스트 미정) |

## 1. 목표와 설계 원칙

- Elastic이 제공하는 **공식 Integration(nginx, apache)** 의 인덱스 템플릿·수집 파이프라인·대시보드를 그대로 사용한다.
- 모든 데이터는 **ECS** 필드(`source.ip`, `url.*`, `http.*`, `user_agent.*`, `host.*`, `container.*`, `event.*`)로 저장해 호스트·컨테이너 메트릭과 같은 키로 연결해 볼 수 있게 한다.
- ELK 쪽 `docker-compose.yml`은 수정하지 않는다. NPM 쪽도 compose 파일은 그대로 두고, NPM이 공식 지원하는 커스텀 설정 디렉터리(`/data/nginx/custom/`)만 사용한다.
- 버전 의존성을 최소화한다. 패키지는 `version: latest`로 받고, 인덱스 이름 대신 data stream 패턴(`logs-nginx.*`)을 쓰며, 수집 로직을 바꿀 때는 `@custom` 확장 지점만 사용한다.

## 2. 아키텍처

```
[Ubuntu 웹서버 호스트]                                   [ELK 서버 (Docker)]
 ┌ NPM 컨테이너 ───────────────────────────┐
 │ /data/logs/ecs_access.log  (신규, ECS용) │
 │ /data/logs/*_error.log                   │
 │ :80 /nginx_status (stub_status, 신규)    │
 └─────────── /data 볼륨(호스트 경로) ──────┘
          │ 파일 읽기 / HTTP
   Elastic Agent (호스트에 systemd 서비스로 설치)
     ├ nginx integration   ─────────────────:9200──▶ logs-nginx.access/error, metrics-nginx.stubstatus
     ├ system integration  (호스트 CPU/메모리/디스크) ─▶ metrics-system.*, logs-system.*
     └ docker integration  (NPM 컨테이너 리소스)     ─▶ metrics-docker.*
          └──────── 정책 수신 :8220 ──────────────▶ fleet-server (extensions/fleet)
```

Agent는 컨테이너가 아니라 **호스트에 직접 설치**한다. 호스트 메트릭, docker.sock, NPM 로그 볼륨에 모두 접근할 수 있고, NPM의 compose 파일을 건드리지 않아도 되기 때문이다.

### 방식 선택 근거

| 방식 | 판단 | 이유 |
|---|---|---|
| **Elastic Agent + Fleet + Integration** | **채택** | Elastic의 현재 권장 방식이다. ECS 매핑과 대시보드가 패키지에 포함되어 있고, 로그·메트릭·호스트·컨테이너 정보를 하나의 정책으로 수집한다. |
| Filebeat 모듈 | 대안 | 동작은 하지만 Integration으로 전환이 권장된다. |
| Logstash grok 직접 작성 | 비권장 | ECS 매핑을 직접 관리해야 하고 제공 대시보드와 필드가 어긋날 위험이 있다. 기존 `logstash.conf`는 그대로 둔다. |

## 3. NPM 환경의 핵심 이슈와 대응

| 이슈 | 내용 | 대응 |
|---|---|---|
| **① 로그 포맷 비호환** | NPM의 proxy host 로그는 자체 `proxy` 포맷(`[$time_local] $upstream_cache_status ... [Client $remote_addr] ...`)을 쓴다. nginx Integration 파이프라인은 이 포맷을 파싱하지 못한다. | `/data/nginx/custom/`에 ECS 수집용 **combined 계열 access log를 별도로 추가**한다. 기존 NPM 로그는 NPM UI용으로 그대로 둔다. |
| **② 가상호스트 식별** | 순수 combined 포맷에는 요청 도메인(`$host`)이 없어서 여러 proxy host를 구분할 수 없다. | 맨 앞에 `$host`를 붙인다. nginx 파이프라인은 선택적 host 접두어를 `destination.domain`으로 파싱하도록 되어 있다. **적용 전에 `_simulate`로 반드시 검증**한다(Phase 2-4). |
| **③ stub_status 미제공** | NPM은 기본으로 status 엔드포인트를 노출하지 않는다. | `http.conf` 커스텀 include로 80 포트에 `127.0.0.1` 전용 server 블록을 추가한다. 포트를 따로 publish하지 않으므로 compose 수정이 필요 없다. |
| **④ 로그 경로** | 로그가 컨테이너 내부 `/data/logs/`에 있다. | 이 디렉터리에 연결된 호스트 경로(bind mount 또는 named volume)를 확인해 Integration 경로로 지정한다. |
| **⑤ 타임존** | access log의 `$time_local`에는 오프셋이 포함되지만 **error log에는 타임존이 없다**. Agent는 호스트 타임존으로 해석하므로, 컨테이너(기본 UTC)와 호스트(예: KST)의 타임존이 다르면 error 이벤트 시간이 최대 9시간 어긋난다. | 호스트와 NPM 컨테이너의 타임존을 일치시킨다(Phase 0에서 확인). |
| **⑥ 로그 로테이션** | NPM 내부의 logrotate가 `.gz`로 압축한다. | Integration 경로에서 `\.gz$`를 제외한다(기본값인지 확인). |

## 4. 작업 단계

### Phase 0. 사전 점검 (웹서버 호스트에서 실행)

```bash
# NPM 컨테이너 이름, 이미지, 포트
docker ps --format '{{.Names}}\t{{.Image}}\t{{.Ports}}'

# /data 볼륨의 호스트 경로 → 이하 <NPM_DATA>
docker inspect <npm> --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}'

# 현재 로그 포맷과 로그 파일 확인
docker exec <npm> grep -A2 'log_format' /etc/nginx/nginx.conf
ls -l <NPM_DATA>/logs/

# 타임존 비교 (컨테이너 vs 호스트)
docker exec <npm> date; date

# ELK 연결 확인
curl -s -u elastic:<pw> http://192.168.219.126:9200 | grep number
nc -zv 192.168.219.126 8220
```

이전 작업 잔여물(빈 폴더 `.local-work/`, `apache access log/`)은 사용자 확인 후 정리한다.

### Phase 1. ELK 측 준비 (`kibana/config/kibana.yml`만 변경)

1. **Kibana 암호화 키**: `docker compose up kibana-genkeys`로 키를 생성한 뒤 `xpack.encryptedSavedObjects.encryptionKey` 등 3개 키를 설정한다. Fleet 동작에 필수다.
2. **Fleet 외부 주소**: 기본값은 Docker 내부 DNS 이름이라 원격 Agent가 해석하지 못한다. ELK 서버의 외부 주소로 바꾼다.
   ```yaml
   xpack.fleet.agents.fleet_server.hosts: [ http://192.168.219.126:8220 ]
   xpack.fleet.outputs:
     - id: fleet-default-output
       name: default
       type: elasticsearch
       hosts: [ http://192.168.219.126:9200 ]
       is_default: true
       is_default_monitoring: true
   ```
3. **패키지 사전 설치**: `xpack.fleet.packages`에 `nginx`와 `apache`를 `version: latest`로 추가한다. `system`과 `docker`는 기존에 선언되어 있다.
4. **Fleet Server 기동**:
   ```bash
   docker compose -f docker-compose.yml -f extensions/fleet/fleet-compose.yml up -d
   ```
5. **Agent 정책은 Fleet UI에서 생성**한다. NPM 환경은 로그 경로 같은 입력 변수를 기본값에서 바꿔야 한다. 그런데 `kibana.yml` 사전 설정에서 쓰는 변수 키 이름은 패키지 버전에 따라 바뀔 수 있어 버전 독립 원칙에 맞지 않는다. 생성한 정책은 Fleet API(`GET /api/fleet/agent_policies/<id>/full`)로 내보내 `docs/`에 보관해 재현에 쓴다.

### Phase 2. NPM 설정 (NPM `/data` 볼륨에 파일 추가)

작성된 파일은 저장소의 `webserver/nginx-proxy-manager/custom/`에 있다. 웹서버의 `<NPM_DATA>/nginx/custom/`으로 복사한다. 파싱 테스트용 요청은 `webserver/nginx-proxy-manager/simulate-access.txt`에 있다.

1. **ECS 수집용 로그 포맷 정의**: `<NPM_DATA>/nginx/custom/http_top.conf` 파일을 만든다. 이 파일은 http 블록 상단에 include된다.
   ```nginx
   # Elastic nginx integration 호환: [$host ] + combined
   log_format ecs_combined '$host $remote_addr - $remote_user [$time_local] '
                           '"$request" $status $body_bytes_sent '
                           '"$http_referer" "$http_user_agent"';
   ```
2. **모든 proxy host에 추가 access log 지정**: `<NPM_DATA>/nginx/custom/server_proxy.conf` 파일을 만든다. 이 파일은 모든 proxy host의 server 블록에 include된다. 같은 블록에 `access_log`가 여러 개 있으면 nginx는 모두 기록하므로, 기존 NPM 로그는 그대로 유지된다.
   ```nginx
   access_log /data/logs/ecs_access.log ecs_combined;
   ```
   redirection host나 404 host까지 수집하려면 `server_redirect.conf`, `server_dead.conf`에도 같은 줄을 넣는다.
3. **stub_status 추가**: `<NPM_DATA>/nginx/custom/http.conf` 파일을 만든다.
   ```nginx
   server {
       listen 80;
       server_name 127.0.0.1 localhost;
       access_log off;
       location = /nginx_status {
           stub_status;
           allow 127.0.0.1;
           allow 172.16.0.0/12;   # 호스트→컨테이너 접근 시 보이는 docker bridge 대역
           deny all;
       }
   }
   ```
4. **적용 전 파싱 검증 (이슈 ②)**: ELK의 Kibana Dev Tools에서 실행한다.
   ```
   GET _ingest/pipeline/logs-nginx.access*        # 설치된 파이프라인 이름 확인
   POST _ingest/pipeline/<위에서 확인한 이름>/_simulate
   { "docs": [ { "_source": {
       "@timestamp": "2026-10-15T10:00:00.000+09:00",
       "message": "app.example.com 203.0.113.10 - - [15/Oct/2026:10:00:00 +0900] \"GET /index.html HTTP/1.1\" 200 512 \"-\" \"Mozilla/5.0\""
   } } ] }
   ```
   기대 결과는 `destination.domain`, `source.ip`, `http.response.status_code`, `user_agent.*`가 채워지고 `error.message`가 없는 것이다. **실패하면 대체안**을 적용한다. 포맷 맨 앞의 `$host`를 빼서 순수 combined로 만들고, 파일 이름을 `ecs_${server_name}_access.log`로 분리한다. 그런 다음 `logs-nginx.access@custom` 파이프라인에서 `log.file.path`로부터 도메인을 추출한다.
5. **반영**:
   ```bash
   docker exec <npm> nginx -t && docker exec <npm> nginx -s reload
   curl -s http://127.0.0.1/nginx_status          # Active connections ... 출력 확인
   tail -f <NPM_DATA>/logs/ecs_access.log          # 새 포맷으로 기록되는지 확인
   ```
   NPM UI에서 proxy host를 저장하면 설정이 재생성되지만, `custom/` 파일은 계속 include되므로 유지된다.
6. **타임존 정합 (이슈 ⑤)**: NPM 원본 compose 파일은 수정하지 않는다. 같은 디렉터리에 `docker-compose.override.yml`(`TZ` 환경변수와 `/etc/localtime` 마운트)을 두어 적용한다. 절차는 `docs/npm-timezone.md`를 따른다.

### Phase 3. Agent 설치 및 정책 구성

1. **Fleet UI에서 `Webserver Policy` 생성** (namespace 예: `prod`). 아래 Integration을 추가한다.

   | Integration | 설정 |
   |---|---|
   | nginx: access logs | 경로 `<NPM_DATA>/logs/ecs_access.log*`, `.gz` 제외 |
   | nginx: error logs | 경로 `<NPM_DATA>/logs/*_error.log*`, `.gz` 제외 |
   | nginx: stub status metrics | hosts `http://127.0.0.1:80`, path `/nginx_status` |
   | system | 기본값 (호스트 메트릭과 auth/syslog) |
   | docker | 기본값 (`unix:///var/run/docker.sock`). NPM 컨테이너의 CPU·메모리·네트워크 수집 |

2. **Agent 설치**: Ubuntu 호스트에서 root로 실행한다. Agent 버전은 `ELASTIC_VERSION`과 맞추고, Fleet Server보다 높은 버전을 쓰면 안 된다.
   ```bash
   VER=9.5.5
   curl -L -O https://artifacts.elastic.co/downloads/beats/elastic-agent/elastic-agent-${VER}-linux-x86_64.tar.gz
   tar xzf elastic-agent-${VER}-linux-x86_64.tar.gz && cd elastic-agent-${VER}-linux-x86_64
   sudo ./elastic-agent install --url=http://192.168.219.126:8220 \
        --enrollment-token=<Webserver Policy 토큰> --insecure
   ```
   CPU가 ARM이면 `linux-arm64` 패키지를 사용한다.

### Phase 4. 검증

| 항목 | 방법 | 기대 결과 |
|---|---|---|
| Agent 상태 | Fleet 화면의 Agents 목록 | Healthy, 모든 Integration Healthy |
| data stream 생성 | `GET _data_stream/logs-nginx.*,metrics-nginx.*,metrics-docker.*` | 생성됨 |
| 파싱 실패 | `GET logs-nginx.access-*/_search?q=error.message:*` | 0건 |
| ECS 필드 | Discover에서 `destination.domain`, `source.ip`, `source.geo.*`, `http.response.status_code`, `url.original`, `user_agent.name` 확인 | 값 존재 |
| 시간 정합 | 같은 요청을 Discover와 로그 파일에서 비교 (access와 error 모두) | 시간 일치 |
| 대시보드 | `[Logs Nginx] Access and error logs`, `[Metrics Nginx] Overview`, `[Metrics Docker] Overview`, `[Metrics System] Host overview` | 데이터 표시 |

### Phase 5. ECS 기반 상관분석

1. **호스트 기준**: nginx 로그, system 메트릭, docker 메트릭이 모두 같은 `host.name`으로 수집된다. 대시보드에서 `host.name` 필터 하나로 트래픽 급증과 CPU·메모리 사용량 변화를 함께 볼 수 있다.
2. **컨테이너 기준**: docker 메트릭의 `container.name`(NPM 컨테이너)으로 프록시 자체의 자원 사용량을 추적한다.
3. **서비스 기준**: `destination.domain`(proxy host 도메인)으로 서비스별 요청 수, 에러율, 클라이언트 분포를 분석한다. 필요하면 `logs-nginx.access@custom` 파이프라인에서 도메인을 `service.name`으로 매핑한다.
4. **환경 구분**: `data_stream.namespace`(prod, stg)를 사용한다.
5. **확장 필드** (선택): `$request_time`이나 `$upstream_response_time`이 필요하면 포맷에 추가하기 전에 Phase 2-4의 `_simulate`로 파싱 여부를 먼저 검증한다. 변환이 필요하면 `@custom` 파이프라인에서만 처리한다. 예: `$request_time`을 `event.duration`(ns)으로 변환.
6. Integration이 관리하는 기본 파이프라인과 템플릿은 직접 수정하지 않는다. 패키지 업그레이드 시 덮어써지기 때문이다.

### Phase 6. apache 확장

1. 로그 포맷은 `combined`(`CustomLog ... combined`)로 하고, `mod_status`(`ExtendedStatus On`, `/server-status`, `Require local`)를 활성화한다.
2. apache가 같은 호스트에 있으면 Webserver Policy에 apache Integration을 추가하고, 다른 호스트면 별도 정책을 만들어 Agent를 설치한다. apache도 컨테이너라면 Phase 2와 같은 방식(로그 볼륨 경로, 타임존 점검)을 적용한다.
3. 검증 대상은 `logs-apache.access/error`, `metrics-apache.status` data stream과 `[Logs Apache] Access and error logs`, `[Metrics Apache] Overview` 대시보드다.
4. nginx와 apache가 같은 ECS 필드에 저장되므로 `event.dataset : (nginx.access or apache.access)`로 두 웹서버를 함께 분석할 수 있다.

### Phase 7. 운영 고려사항

- **보안**: fleet extension의 `elastic` 슈퍼유저 자동 등록을 Fleet Server 서비스 토큰으로 바꾸고, TLS 적용(`--insecure` 제거)을 검토한다. `.env`의 `changeme` 비밀번호도 변경한다.
- **디스크**: 추가한 `ecs_access.log`로 NPM 로그 용량이 늘어난다. NPM 내부의 logrotate가 `/data/logs/*.log`를 처리하는지 확인한다.
- **보존 기간과 업그레이드**: 보존 기간은 `@custom` component template으로 조정한다. 스택을 업그레이드한 뒤에는 Integrations 화면에서 패키지를, Fleet에서 Agent를 순서대로 업그레이드한다.

## 5. 변경 대상 요약

| 위치 | 파일 | 내용 |
|---|---|---|
| ELK | `kibana/config/kibana.yml` | 암호화 키, Fleet 외부 주소, nginx/apache 패키지 |
| ELK | `docker-compose.yml` | **변경 없음** (`-f extensions/fleet/fleet-compose.yml`) |
| NPM | `<NPM_DATA>/nginx/custom/http_top.conf` | `ecs_combined` 로그 포맷 정의 |
| NPM | `<NPM_DATA>/nginx/custom/server_proxy.conf` | 추가 access log |
| NPM | `<NPM_DATA>/nginx/custom/http.conf` | stub_status 엔드포인트 |
| 웹서버 호스트 | Elastic Agent | Fleet 등록 |
| ELK | `docs/` | Fleet 정책 export, (선택) `@custom` 파이프라인 정의 |

## 6. 남은 확인 사항

1. ~~ELK 주소~~ → 192.168.219.126 (확정)
2. Phase 0의 점검 결과: NPM `/data`의 호스트 경로, 현재 로그 파일 목록, 컨테이너와 호스트의 타임존, CPU 아키텍처.
3. NPM 앞단에 다른 프록시나 로드밸런서가 있는지. 있으면 `$remote_addr` 대신 실제 클라이언트 IP 처리(real_ip 설정)가 필요하다.
4. apache 서버의 위치와 형태(호스트 설치인지 컨테이너인지).
