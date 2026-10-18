# Ubuntu 호스트 apache2(apt 설치) 로그 수집 절차

작성일: 2026-10-16 · 전제: **NPM·nginx와 다른 Ubuntu 서버**, apt로 설치한 apache2, **NPM 뒤에 있음**.
방식은 nginx와 같다: Elastic Agent + Fleet + apache Integration, ECS. 순서는 `work-summary.md` 6장 공통 패턴(P1~P9)을 따른다.

## 0. nginx-host와 다른 점

| 항목 | 호스트 nginx | 호스트 apache2 |
|---|---|---|
| 설정 추가 위치 | `/etc/nginx/conf.d/*.conf` | `/etc/apache2/conf-available/*.conf` → `a2enconf` |
| vhost 상속 문제 (P2) | vhost에 `access_log`가 있으면 직접 추가 | **`GlobalLog`(2.4.19+)로 해결.** 자체 `CustomLog`가 있는 vhost도 모두 기록되므로 사이트 파일을 수정하지 않는다 |
| 실제 IP (P3) | `realip` 모듈 | `mod_remoteip` (`a2enmod remoteip`), 로그는 `%h` 대신 `%a` |
| 상태 엔드포인트 (P4) | `127.0.0.1:8080/nginx_status` | `127.0.0.1:8080/server-status` (전용 VirtualHost) |
| 로그 경로 | `/var/log/nginx/` | `/var/log/apache2/` (소유 `root:adm`, 640) |
| data stream | `logs-nginx.*`, `metrics-nginx.stubstatus` | `logs-apache.access/error`, `metrics-apache.status` |

## 산출물 (`webserver/apache-host/`)

| 파일 | 설치 위치 / 용도 |
|---|---|
| `conf-available/ecs-logging.conf` | 수집용 포맷 3종 정의, `GlobalLog`로 `ecs_access.log` 기록, server-status 폴링 제외 |
| `conf-available/ecs-real-ip.conf` | `mod_remoteip`, 신뢰 대상은 NPM 서버 IP 하나 |
| `conf-available/ecs-server-status.conf` | `Listen 127.0.0.1:8080` + `/server-status` 전용 VirtualHost, `ExtendedStatus On` |
| `simulate-access.txt` | P1 파싱 검증 (Kibana Dev Tools) |
| `install-agent-apache-host.sh` | 점검 + Agent 설치 |
| `verify-ingest.txt` | P8 수집 검증 1~8단계 (Kibana Dev Tools) |

## Step 1. 파싱 검증 먼저 (P1 · Kibana Dev Tools)

apache Integration은 `kibana.yml`에 사전 설치로 선언되어 있으므로 파이프라인이 이미 있다. `simulate-access.txt`를 실행한다.

| 결과 | 조치 |
|---|---|
| doc[0](`%v:%p %a ...`) 통과 | 기본값(`ecs_vhost_combined`) 그대로 사용 |
| doc[0] 실패, doc[1](`%v %a ...`) 통과 | `ecs-logging.conf`의 `GlobalLog` 포맷을 `ecs_combined_noport`로 변경 |
| 둘 다 실패 | `ecs_combined` 사용. 도메인 구분은 포기하고 `host.name`/tags로 구분 |

**검증 결과 (2026-10-16, 패키지 3.0.2): 통과 → `ecs_vhost_combined` 확정**

| 문서 | 결과 |
|---|---|
| doc[0] `%v:%p %a` | `destination.domain`=app.example.com, `destination.port`=443, `url.domain`, `source.ip`, `http.*`, `user_agent.name`=Chrome. error 없음 |
| doc[1] `%v %a` | 도메인이 `destination.domain`으로 정상 분리됨. 포트만 없음 |
| doc[2] `%a` (combined) | 정상. 도메인 필드 없음 |
| doc[3] IPv6, 바이트 `-` | `source.ip`=2001:db8::1, `destination.port`=80, `body.bytes` 생략. error 없음 |
| error 2건 | `log.level`(error/notice), `message` 정상. client가 있는 줄은 `source.ip`·`source.port`까지 추출 |

패키지를 업그레이드한 뒤에는 이 테스트를 다시 실행한다(파이프라인 이름의 버전이 바뀐다).

## Step 2. 사전 점검 (apache 서버)

```bash
apache2 -v                                     # 2.4.19 이상이어야 GlobalLog 사용 가능 (Ubuntu 20.04+ 는 해당)
apache2ctl -M | grep -E 'status|remoteip|logio|setenvif'
apache2ctl -S                                  # vhost 목록, 기본 vhost 확인
grep -rn 'CustomLog\|ErrorLog' /etc/apache2/sites-enabled/
ss -ltnp | grep -E ':80 |:443 |:8080 '
tail -n3 /var/log/apache2/access.log           # 첫 필드 = 현재 apache가 보는 클라이언트 IP (= NPM 서버 IP)
timedatectl | grep 'Time zone'
```

`install-agent-apache-host.sh --check-only`로 한 번에 점검해도 된다.

## Step 3. apache 설정 적용

```bash
# 1) 파일 복사
sudo cp conf-available/ecs-*.conf /etc/apache2/conf-available/

# 2) 실제 IP: <NPM_SERVER_IP>를 Step 2의 access.log 첫 필드 값(NPM 서버 LAN IP)으로 바꾼다
sudo sed -i 's/<NPM_SERVER_IP>/192.168.x.x/' /etc/apache2/conf-available/ecs-real-ip.conf

# 3) 모듈·설정 활성화 (status, setenvif, logio는 Ubuntu 기본 활성)
sudo a2enmod remoteip status
sudo a2enconf ecs-logging ecs-real-ip ecs-server-status

# 4) 반영
sudo apache2ctl configtest && sudo systemctl reload apache2

# 5) 확인
curl -s 'http://127.0.0.1:8080/server-status?auto' | head -5     # ServerVersion, Total Accesses, BusyWorkers ...
curl -s -o /dev/null -H 'Host: <서비스 도메인>' http://127.0.0.1/
tail -n2 /var/log/apache2/ecs_access.log                         # "<도메인>:80 <IP> - - [..+0900] ..." 형태
```

**참고 사항**

- `GlobalLog`는 main server와 모든 vhost에 적용되며, 각 vhost의 기존 `CustomLog`(`access.log` 등)는 그대로 유지된다.
- Step 3-5의 로컬 curl은 NPM을 거치지 않으므로 `127.0.0.1`이 찍히는 것이 정상이다. 실제 IP 확인은 Step 6에서 한다.
- 8080을 다른 프로세스가 쓰고 있으면 `ecs-server-status.conf`의 `Listen`과 `VirtualHost` 포트를 함께 바꾼다. Fleet 입력값도 같은 포트로 맞춘다.
- 로그 로테이션은 Ubuntu 기본 `/etc/logrotate.d/apache2`(`/var/log/apache2/*.log`)가 `ecs_access.log`도 처리한다. `.gz`는 Integration 경로에서 제외한다.

## Step 4. Fleet 정책 (Kibana UI, 토큰 발급보다 먼저 · P6)

1. **Fleet → Agent policies → Create agent policy**
   - Name: `Apache Host Policy`
   - Collect system logs and metrics: **체크**
   - Default namespace: 다른 웹서버 정책과 같은 값
2. **Add integration → Apache HTTP Server**: Integration name은 `apache-host`, 정책은 `Apache Host Policy`를 선택한다.

| 항목 | 값 |
|---|---|
| Access logs Paths | `/var/log/apache2/ecs_access.log*` |
| Error logs Paths | `/var/log/apache2/error.log*` (vhost별 `ErrorLog`가 따로 있다면 함께 추가) |
| Exclude files | `\.gz$` 포함 여부 확인 |
| Metrics Hosts | `http://127.0.0.1:8080` |
| Server status path | `/server-status` (Integration이 `?auto`를 붙여 호출) |
| Tags (access, error 각각) | `apache-host` |

정책을 만든 뒤 JSON으로 내보내 `docs/`에 보관한다(`GET kbn:/api/fleet/agent_policies/<id>/full`, P9).

## Step 5. Agent 설치 (P7)

```bash
sudo ./install-agent-apache-host.sh --check-only
sudo ./install-agent-apache-host.sh --token <Apache Host Policy 토큰>
```

**토큰은 반드시 `Apache Host Policy`의 것을 사용한다** (NPM에서 다른 정책 토큰으로 등록해 수집이 빠진 사례가 있었다). 스크립트는 FAIL 항목이 있으면 설치하지 않는다. Agent는 root로 동작하므로 `/var/log/apache2/`(`root:adm` 640)를 읽을 수 있다.

## Step 6. 검증 (P8)

```bash
# apache 서버
sudo elastic-agent status --output=full | grep -iA3 apache     # apache 컴포넌트 HEALTHY
stat -c 'size=%s' /var/log/apache2/ecs_access.log              # 1KB 미만이면 요청을 더 보낸다
```

**실제 IP와 위조 방지** (외부망 또는 NPM 경유)

- 모바일 등 외부망에서 서비스 도메인에 접속한 뒤 `tail /var/log/apache2/ecs_access.log`를 확인한다. 두 번째 필드가 실제 공인 IP여야 한다.
- `curl -H 'X-Forwarded-For: 1.2.3.4' https://<도메인>/`로 요청했을 때 `1.2.3.4`가 아니라 실제 IP가 찍혀야 한다.

이후 Kibana Dev Tools에서 `webserver/apache-host/verify-ingest.txt` 1~8단계를 실행한다. 대시보드는 `[Logs Apache] Access and error logs`, `[Metrics Apache] Overview`, `[Metrics System] Host overview`에서 `host.name` 필터로 확인한다.

## 이중 집계 주의

같은 요청이 NPM 로그(`logs-nginx.access`, tags `nginx-npm`)와 apache 로그(`logs-apache.access`, tags `apache-host`)에 두 번 기록된다. 외부 트래픽은 NPM 기준으로, 백엔드 처리는 apache 기준으로 본다. 두 웹서버를 함께 볼 때는 `event.dataset : (nginx.access or apache.access)`에 `tags`나 `host.name` 조건을 같이 건다.

## 문제 해결

| 증상 | 확인 |
|---|---|
| `configtest`에서 `Invalid command 'RemoteIPHeader'` | `a2enmod remoteip`를 하지 않았다. 설정이 `<IfModule>` 안에 있어 오류 대신 무시될 수도 있으므로 `apache2ctl -M`으로 확인한다 |
| `Invalid command 'GlobalLog'` | 2.4.19 미만 버전이다. `GlobalLog` 줄을 지우고 vhost마다 `CustomLog ... ecs_vhost_combined env=!ecs_nolog`를 추가한다 |
| `(98)Address already in use: ... 127.0.0.1:8080` | 8080 포트 충돌이다. 포트를 바꾼다 |
| `/server-status` 404 | `a2enmod status`를 하지 않았거나, 요청이 8080이 아닌 기본 사이트로 갔다. Integration Hosts가 `:8080`인지 확인한다 |
| `/server-status` 403 | 요청 출발지가 127.0.0.1이 아니다. Agent와 같은 호스트에서 loopback으로 호출하는지 확인한다 |
| `ecs_access.log`에 NPM IP만 찍힘 | `<NPM_SERVER_IP>` 값이 실제 출발지와 다르다(`tail access.log` 첫 필드와 비교). 또는 `RemoteIPHeader` 이름이 틀렸다 |
| `ecs_access.log`가 생성되지 않음 | `a2enconf ecs-logging` 후 reload를 하지 않았다. `apache2ctl -t -D DUMP_INCLUDES`로 include 여부를 확인한다 |
| `error.message` 발생 | Step 1 판정과 실제 포맷이 다르다. `verify-ingest.txt` 3-1단계로 원문을 확인한다 |
| status 메트릭 일부 0 | `ExtendedStatus On`이 적용되지 않았다. `?auto` 출력에 `Total Accesses`가 있는지 확인한다 |
