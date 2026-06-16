# jsTube Frontend

Flutter 기반 튜브 서비스 클라이언트입니다.

## 역할

- 미디어/노래방 목록 조회
- 영상 재생, 이동, 배속, 볼륨 조절
- 제목, 태그, 타임라인 편집
- Android/TV APK 빌드

## 로컬 개발 실행

```powershell
flutter pub get
flutter run -d chrome --dart-define=MEDIA_API_BASE=http://localhost:8084 --dart-define=ADMIN_BASE_URL=http://localhost:8081 --dart-define=WEBHARD_BASE_URL=http://localhost:8083
```

TV 화면은 다음 쿼리로 진입합니다.

```text
/?karaoke_tv=1
```

## 8084 통합 화면 반영

`jsTube-be`는 `../jsTube-fe/build/web`을 직접 서빙합니다. `http://localhost:8084`에서 보는 화면을 바꾸려면 Flutter dev server 재시작이 아니라 웹 빌드를 다시 만들어야 합니다.

```powershell
.\scripts\build-web-local.ps1
```

로컬 개발 빌드는 서비스워커 캐시 혼선을 줄이기 위해 기본적으로 `--pwa-strategy=none`을 사용합니다. PWA 서비스워커가 필요하면:

```powershell
.\scripts\build-web-local.ps1 -EnablePwa
```

## 빌드 산출물 정책

- `build/`는 git에 커밋하지 않습니다.
- 서버 배포 또는 로컬 통합 실행 전에 `.\scripts\build-web-local.ps1`로 `build/web`을 생성합니다.
- 브라우저가 이전 번들을 계속 보이면 DevTools에서 `Empty Cache and Hard Reload`를 실행합니다.

## 주요 환경값

- `MEDIA_API_BASE`: 튜브 BE API 주소. 예: `http://localhost:8084`
- `ADMIN_BASE_URL`: 어드민 서비스 주소. 예: `http://localhost:8081`
- `WEBHARD_BASE_URL`: 웹하드 서비스 주소. 예: `http://localhost:8083`
- `APK_DOWNLOAD_URL`: TV APK 다운로드 주소

## 운영 빌드 예시

```powershell
flutter build web --dart-define=MEDIA_API_BASE=https://med.js65.myds.me --dart-define=ADMIN_BASE_URL=https://adm.js65.myds.me --dart-define=WEBHARD_BASE_URL=https://webhard.js65.myds.me --dart-define=APK_DOWNLOAD_URL=https://med.js65.myds.me/downloads/jstube-tv.apk
flutter build apk --release --dart-define=MEDIA_API_BASE=https://med.js65.myds.me
```
