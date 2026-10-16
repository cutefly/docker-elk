# NPM 컨테이너 타임존 일치 절차

## 왜 필요한가

nginx error log에는 타임존 정보가 없다(`2026/10/15 10:00:00 [error] ...`). Elastic Agent는 이 시각을 **호스트 타임존**으로 해석한다. 그래서 NPM 컨테이너가 UTC이고 호스트가 KST이면 error 이벤트가 9시간 어긋나 저장된다. access log(`$time_local`)는 `+0900` 같은 오프셋을 포함하므로 영향이 없다.

## Step 1. 현재 상태 확인 (웹서버)

```bash
timedatectl | grep 'Time zone'                   # 호스트 타임존, 예: Asia/Seoul (KST, +0900)
docker exec <npm> date +'%Z %z'                  # 컨테이너 타임존, 예: UTC +0000
cd <NPM compose 디렉터리> && docker compose config --services   # 서비스 이름, 예: app
docker compose config | grep -A6 'volumes:'      # /data, /etc/letsencrypt 가 볼륨 또는 bind mount인지 확인
```

> **주의**: 컨테이너를 재생성해도 `/data`와 `/etc/letsencrypt`가 볼륨이나 bind mount에 있으면 설정과 인증서는 유지된다. 마운트가 없다면 재생성하기 전에 반드시 백업한다.
>
> NPM을 compose가 아니라 `docker run`이나 Portainer로 띄웠다면 override 파일을 쓸 수 없다. 이 경우 같은 옵션(`-e TZ=Asia/Seoul -v /etc/localtime:/etc/localtime:ro`)을 넣어 컨테이너를 다시 생성한다.

## Step 2. override 파일 적용

1. 저장소의 `webserver/nginx-proxy-manager/docker-compose.override.yml`을 NPM compose 파일과 같은 디렉터리에 복사한다.
2. Step 1에서 확인한 서비스 이름이 `app`이 아니면 파일 안의 이름을 고친다. 타임존이 `Asia/Seoul`이 아니면 그 값도 고친다.
3. 병합 결과를 확인한 뒤 적용한다.

```bash
docker compose config | grep -E 'TZ|localtime'   # 병합 결과 확인
docker compose up -d                             # 변경된 서비스만 재생성 (수 초간 프록시 중단)
```

원본 compose 파일 이름이 기본값(`docker-compose.yml`, `compose.yaml`)이 아니어서 `-f`로 지정해 실행하고 있다면, override 파일도 `-f`로 함께 지정해야 병합된다.

## Step 3. 검증

```bash
docker exec <npm> date +'%Z %z'                  # 호스트와 같은 값 (예: KST +0900)
tail -n1 <NPM_DATA>/logs/ecs_access.log          # [..:..:.. +0900] 형태
docker exec <npm> nginx -t                       # custom 설정 포함 정상 여부
sudo ./install-agent.sh --npm-data <NPM_DATA> --npm-container <npm> --check-only   # 4번 항목 [OK]
```

## Step 4. 기존 error log 처리 (Agent 설치 전 권장)

타임존을 바꾸기 전에 UTC로 기록된 error log 라인은, Agent가 처음 읽을 때 9시간 어긋난 시각으로 저장된다. 과거 error 이력이 필요 없으면 Agent 설치 전에 비운다.

```bash
sudo sh -c 'for f in <NPM_DATA>/logs/*_error.log; do : > "$f"; done'
```

이력이 필요하면 그대로 두되, 해당 구간의 시간이 어긋난다는 점을 감안한다. 이 조치는 Agent 설치 전에만 의미가 있다. 이미 수집된 데이터는 바뀌지 않는다.
