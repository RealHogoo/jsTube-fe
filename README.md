# jsTube Frontend

Flutter 기반 미디어 프론트입니다.

## 대상

- Flutter Web
- Android APK
- Android TV APK 비공식 배포

## 실행

```powershell
flutter pub get
flutter run -d chrome --dart-define=MEDIA_API_BASE=http://localhost:8084
```

TV 화면은 웹에서 다음 쿼리로 진입합니다.

```text
/?karaoke_tv=1
```

## 빌드

```powershell
flutter build web --dart-define=MEDIA_API_BASE=https://med.js65.myds.me
flutter build apk --release --dart-define=MEDIA_API_BASE=https://med.js65.myds.me
```

## 환경값

- `MEDIA_API_BASE`: 미디어 백엔드 API 주소. 비우면 같은 origin의 `/api`를 사용합니다.
- `ADMIN_BASE_URL`: 어드민 서비스 주소
- `WEBHARD_BASE_URL`: 웹하드 서비스 주소
