# Phase 3 실행 가이드 — Fleet 정책 생성 및 Agent 설치

전제: ELK(192.168.219.126)의 Fleet Server가 Healthy 상태이고, NPM 커스텀 설정과 `_simulate` 파싱 테스트를 완료했다.

## Step 1. 웹서버 사전 점검

`webserver/install-agent.sh`를 웹서버로 복사한 뒤, 토큰 없이 점검만 실행한다.

```bash
sudo ./install-agent.sh --npm-data <NPM /data 호스트 경로> --npm-container <NPM 컨테이너명> --check-only
```

점검 항목은 다음과 같다.

- ES(9200)와 Fleet Server(8220)에 연결되는지
- `ecs_access.log`가 존재하고 기록이 쌓이는지, 포맷이 맞는지
- `nginx_status`가 응답하는지 (403이면 출력된 게이트웨이 대역을 `custom/http.conf`의 `allow`에 추가한다)
- 호스트와 컨테이너의 타임존이 일치하는지
- CPU 아키텍처

모든 항목이 `[OK]`가 될 때까지 해결한다. 타임존 불일치는 `[WARN]`으로만 표시되지만, error log 시간에 영향을 주므로 가능하면 맞춘다.

## Step 2. Fleet 정책 생성 (Kibana UI)

1. **Fleet → Agent policies → Create agent policy**
   - Name: `Webserver Policy`
   - Advanced options → Default namespace: `prod`
   - Collect system logs and metrics: **체크** (system integration 자동 추가)
2. **정책 선택 → Add integration → Nginx**
   - Integration name: `nginx-npm`
   - **Collect logs from Nginx instances**
     - Access logs Paths: `<NPM_DATA>/logs/ecs_access.log*`
     - Error logs Paths: `<NPM_DATA>/logs/*_error.log*`
     - 고급 옵션에 Exclude files가 있으면 `\.gz$`가 들어 있는지 확인한다.
   - **Collect metrics from Nginx instances**
     - Hosts: `http://127.0.0.1:80`
     - stubstatus의 Server status path: `/nginx_status`
   - Existing hosts → `Webserver Policy` 선택 후 저장
3. **Add integration → Docker**
   - 기본값 사용 (Docker host: `unix:///var/run/docker.sock`)
   - 정책은 `Webserver Policy`
4. **정책 백업** (재현용): Kibana Dev Tools에서 실행한다.
   ```
   GET kbn:/api/fleet/agent_policies?kuery=name:"Webserver Policy"
   GET kbn:/api/fleet/agent_policies/<id>/full
   ```
   결과를 `docs/fleet-webserver-policy.json`으로 저장한다.

UI 항목 이름은 패키지 버전에 따라 조금 다를 수 있다. 확인할 핵심은 access와 error의 경로 2개, 그리고 stubstatus의 host와 path다.

## Step 3. Agent 설치

1. **Fleet → Enrollment tokens**에서 `Webserver Policy`의 토큰을 복사한다.
2. 웹서버에서 실행한다.
   ```bash
   sudo ./install-agent.sh --npm-data <경로> --npm-container <컨테이너명> --token <토큰>
   ```
   스크립트는 점검을 다시 수행한 뒤, Agent를 다운로드하고 sha512로 검증한 다음 Fleet에 등록한다.

## Step 4. 검증 (설계 문서 Phase 4)

```
# Dev Tools
GET _data_stream/logs-nginx.*,metrics-nginx.*,metrics-docker.*,metrics-system.*?filter_path=data_streams.name
GET logs-nginx.access-*/_count?q=error.message:*                    # 0 이어야 함
GET logs-nginx.access-*/_search?size=1&sort=@timestamp:desc&filter_path=hits.hits._source.destination,hits.hits._source.source,hits.hits._source.http,hits.hits._source.url
```

Kibana 대시보드에서 다음 항목에 데이터가 표시되는지 확인한다.

- `[Logs Nginx] Access and error logs`
- `[Metrics Nginx] Overview`
- `[Metrics Docker] Overview`
- `[Metrics System] Host overview`

## 문제 해결

| 증상 | 확인 |
|---|---|
| Agent가 Offline 또는 Unhealthy | 웹서버에서 `sudo elastic-agent status`, `sudo journalctl -u elastic-agent -n 100` 확인 |
| nginx access 데이터 없음 | 정책 경로가 **호스트 경로**인지 확인 (컨테이너 경로 `/data/logs`가 아님). 경로 끝에 `*` 포함 여부 확인 |
| stubstatus 에러 (403) | `custom/http.conf`의 `allow` 대역과 Docker 게이트웨이 비교 |
| `error.message` 발생 | 해당 문서의 `event.original`을 `_simulate`로 재현. ecs_combined 외의 포맷이 섞였는지 확인 |
| error 이벤트 시간 ±9h | 호스트와 컨테이너 타임존 불일치 |
| ES 연결 거부 (Agent 로그) | `kibana.yml`의 Fleet output이 `http://192.168.219.126:9200`인지, Kibana를 재시작했는지 확인 |
