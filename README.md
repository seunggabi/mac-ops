# mac-ops

macOS 시스템 최적화 CLI 도구. 불필요한 캐시, 임시 파일, 좀비/고아 프로세스를 자동으로 정리합니다.

## 핵심 특징

- **72시간 안전망**: 파일을 바로 삭제하지 않고 휴지통으로 이동. 실수 시 복원 가능
- **외부 의존성 zero**: macOS 기본 도구(zsh, plutil, launchd)만 사용
- **5계층 안전 시스템**: 화이트리스트, 블랙리스트, 크기 가드, 프로세스 보호, 락
- **10개 정리 모듈**: 캐시, 임시파일, 로그, 좀비/고아 프로세스, Homebrew, 개발도구, Docker, 브라우저

## 설치

```bash
git clone https://github.com/seunggabi/mac-ops.git
cd mac-ops
chmod +x bin/mac-ops
```

### PATH에 추가 (선택)

```bash
# ~/.zshrc에 추가
export PATH="/path/to/mac-ops/bin:$PATH"
```

## 사용법

### 기본 명령어

```bash
# 미리보기 (dry-run) - 실제 삭제 없이 정리 대상 확인
bin/mac-ops run --dry-run

# 정리 실행
bin/mac-ops run

# 특정 모듈만 실행
bin/mac-ops run --module=cache
bin/mac-ops run --module=browser
bin/mac-ops run --module=docker

# 디스크 공간 분석 리포트
bin/mac-ops analyze

# 상세 로그 출력
bin/mac-ops run --verbose
```

### 사용 가능한 모듈

| 모듈 | 설명 |
|------|------|
| `cache` | ~/Library/Caches 캐시 정리 (Apple 제외) |
| `tmp` | /tmp, /private/var/folders, CrashReporter 정리 |
| `log` | ~/Library/Logs, 시스템 진단 리포트 정리 |
| `zombie` | 좀비 프로세스 탐지 및 정리 |
| `orphan` | 고아 프로세스 탐지 및 정리 |
| `orphan-app` | 삭제된 앱의 잔존 파일 정리 |
| `brew` | Homebrew 캐시 정리 |
| `dev` | Xcode, npm, yarn, pnpm, pip, Gradle 캐시 정리 |
| `docker` | Docker dangling 이미지, 중지된 컨테이너, 미사용 볼륨 정리 |
| `browser` | Safari, Chrome, Firefox 캐시 정리 |

### 휴지통 관리

```bash
# 휴지통 내역 조회
bin/mac-ops list-trash

# 실수로 삭제된 파일 복원
bin/mac-ops restore ~/Library/Caches/com.important.app

# 만료된 항목 즉시 영구 삭제
bin/mac-ops purge

# 현재 상태 확인 (휴지통, 디스크 사용량, launchd 상태)
bin/mac-ops status
```

### 기타

```bash
# 현재 설정 확인
bin/mac-ops config

# 버전 확인
bin/mac-ops version

# 도움말
bin/mac-ops help
```

## 자동 실행 설정

### 방법 1: launchd (권장)

macOS 기본 스케줄러로 1시간마다 자동 실행됩니다. 절전 모드에서 깨어날 때 밀린 작업도 실행합니다.

```bash
# 설치
bin/mac-ops install

# 제거
bin/mac-ops uninstall
```

### 방법 2: crontab

```bash
crontab -e
```

아래 내용을 추가합니다:

```cron
# 매시간 mac-ops 실행
0 * * * * /path/to/mac-ops/bin/mac-ops run --scheduled 2>&1 >> ~/.mac-ops/.logs/cron.log

# 또는 매일 새벽 3시에 실행
0 3 * * * /path/to/mac-ops/bin/mac-ops run --scheduled 2>&1 >> ~/.mac-ops/.logs/cron.log
```

> `/path/to/mac-ops`는 실제 설치 경로로 변경하세요.

## 주의사항

### Full Disk Access 권한 필요

macOS TCC 정책으로 인해 `~/Library/Caches`, `~/Library/Logs` 등 일부 경로에 접근하려면 **Full Disk Access** 권한이 필요합니다.

```
시스템 설정 > 개인정보 보호 및 보안 > Full Disk Access
```

Terminal.app (또는 iTerm, Warp 등 사용 중인 터미널)을 추가해주세요. launchd 자동 실행 시에는 `mac-ops` 바이너리 자체를 FDA 목록에 추가해야 합니다.

### dry-run 먼저 실행할 것

처음 사용 시 반드시 `--dry-run`으로 어떤 파일이 정리 대상인지 확인하세요.

```bash
bin/mac-ops run --dry-run
```

### 72시간 유예 기간

- 모든 정리 대상은 `~/.mac-ops/.trash/`로 이동되며, **72시간 후** 자동 영구 삭제됩니다
- 72시간 이내에 `mac-ops restore <경로>`로 복원할 수 있습니다
- `mac-ops purge`를 실행하면 만료된 항목이 즉시 영구 삭제됩니다

### 절대 건드리지 않는 경로

| 경로 | 이유 |
|------|------|
| `/System/*`, `/bin/*`, `/sbin/*`, `/usr/*` | SIP 보호 |
| `~/Library/Keychains/*` | 키체인 (암호, 인증서) |
| `~/Documents/*`, `~/Desktop/*` | 사용자 문서 |
| `/Library/LaunchDaemons/*` | 시스템 서비스 |

### 절대 종료하지 않는 프로세스

```
kernel_task, launchd, WindowServer, loginwindow,
SystemUIServer, Finder, cfprefsd, mds, mds_stores
```

### Docker 모듈

Docker Desktop이 실행 중일 때만 동작합니다. Docker가 설치되지 않았거나 중지 상태이면 자동으로 건너뜁니다.

### 크기 가드

단일 파일이 2GB를 초과하면 자동으로 건너뜁니다. `--force` 옵션으로 무시할 수 있습니다.

## 프로젝트 구조

```
mac-ops/
├── bin/mac-ops                    # CLI 엔트리포인트
├── lib/
│   ├── core/                      # 핵심 유틸리티
│   │   ├── config.zsh             # 설정 로더
│   │   ├── trash.zsh              # 휴지통 관리
│   │   ├── logger.zsh             # 로깅
│   │   ├── lock.zsh               # 중복 실행 방지
│   │   ├── safety.zsh             # 안전 시스템
│   │   └── disk.zsh               # 디스크 모니터링
│   ├── modules/                   # 정리 모듈
│   │   ├── cache-cleanup.zsh
│   │   ├── tmp-cleanup.zsh
│   │   ├── log-cleanup.zsh
│   │   ├── zombie-killer.zsh
│   │   ├── orphan-killer.zsh
│   │   ├── orphan-app-cleanup.zsh
│   │   ├── brew-cleanup.zsh
│   │   ├── dev-cleanup.zsh
│   │   ├── docker-cleanup.zsh
│   │   ├── browser-cleanup.zsh
│   │   └── analyze.zsh
│   └── utils/                     # 공유 유틸리티
│       ├── format.zsh
│       ├── notify.zsh
│       ├── parallel.zsh
│       └── plist-helper.zsh
├── config/                        # 설정 파일
├── launchd/                       # launchd 에이전트
└── tests/                         # 테스트 (64개)
```

## 라이선스

MIT
