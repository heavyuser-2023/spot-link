# SpotLink — Google Play 제출 가이드 (v1.5.34, 2026-07-16)

이 문서 하나로 Play Console 제출을 끝낼 수 있게 정리했습니다.
**자동으로 준비한 것**과 **사용자님만 할 수 있는 것**을 명확히 구분합니다.

---

## ✅ 자동으로 준비 완료된 것 (그대로 사용)

| 항목 | 위치 / 값 |
|---|---|
| **업로드용 App Bundle (.aab)** | `build/app/outputs/bundle/storeRelease/app-store-release.aab` (약 59.8MB) |
| 서명 | 릴리즈 키(`android/app/spotlink-release.jks`)로 서명됨 · targetSdk 36(요건 35+ 충족) |
| 정책 준수 | store 플레이버에서 `REQUEST_INSTALL_PACKAGES`, `READ_MEDIA_IMAGES/VIDEO/AUDIO` 제거 · APK 공유 UI 숨김(STORE_BUILD) · 위치는 API30 이하로 제한(위치 선언 불필요) |
| 앱 아이콘 512 | `docs/store/icon_512.png` |
| 피처 그래픽 1024×500 | `docs/store/feature_graphic.png` |
| 폰 스크린샷 5장(1080×2160, 리뉴얼 디자인) | `docs/store/screenshot_1_chats … 5_dark.png` |
| 리스팅 문구(한/영) | `docs/store/listing.md`, 갱신본 `docs/../listing.md` |
| 개인정보처리방침 | `docs/PRIVACY.md` / `docs/privacy.html` → 공개 URL: `https://github.com/heavyuser-2023/spot-link/blob/main/docs/PRIVACY.md` |

> 빌드 재생성:
> `flutter build appbundle --release --flavor store --dart-define=STORE_BUILD=true`

---

## 🙋 사용자님만 할 수 있는 단계 (제가 대신 못 하는 부분)

계정·결제·본인확인·약관 동의·최종 업로드는 사용자님의 구글 계정으로 직접 하셔야 합니다(자동화 불가·안전상 제가 대행 불가).

1. **Google Play 개발자 계정 등록** — https://play.google.com/console → 등록비 **$25**(1회) 결제 + 본인 인증(신분증/사업자). 개인은 최근 정책상 검증 기간이 걸릴 수 있음.
2. **앱 만들기** — 앱 이름 `SpotLink`, 기본 언어 한국어, 앱/무료, 선언 체크.
3. **App content(앱 콘텐츠)** 폼 작성 — 아래 값 그대로 입력.
4. **스토어 등록정보** — `listing.md`의 이름/설명, 위 그래픽·스크린샷 업로드, 카테고리 **커뮤니케이션**, 개인정보처리방침 URL 입력.
5. **프로덕션(또는 비공개 테스트) 트랙 → 새 버전** → 위 **.aab 업로드** → 출시 노트 입력 → 검토 제출.
   - 처음이면 **비공개 테스트(Closed testing)** 로 먼저 올리는 걸 권장(신규 개인 계정은 프로덕션 전 테스트 이력이 요구될 수 있음).
6. Play가 **앱 서명(Play App Signing)** 사용을 제안하면 수락 — 지금 .aab의 키가 업로드 키가 됩니다. (`spotlink-release.jks`는 **절대 분실 금지**, 안전 백업.)

---

## 📋 App content 폼 답안 (그대로 입력)

**개인정보처리방침 URL**
```
https://github.com/heavyuser-2023/spot-link/blob/main/docs/PRIVACY.md
```

**광고**: 아니요(광고 없음).

**데이터 보안(Data safety)**
- 데이터 수집/공유: **수집하지 않음 / 공유하지 않음** (서버 없음).
- "앱이 요구하는 데이터 유형" 전부 **아니요**.
- 전송 중 암호화: **예**(기기 간 종단간 암호화).
- 사용자가 데이터 삭제 요청 가능: **예 — 앱 삭제 시 전량 삭제**(기기 저장만).

**콘텐츠 등급(IARC 설문)** — 메시징 앱 기준 답안
- 앱 카테고리: **소셜/커뮤니케이션**.
- 폭력/성적/약물/도박 콘텐츠: 모두 **없음**.
- **사용자 간 자유 소통 가능: 예** (1:1/근거리 메시징). → 이 항목 때문에 보통 **만 12세 이상급(Teen)** 으로 산정됩니다. 사실대로 "예" 선택.
- 위치 공유: **아니요**(위치 데이터 공유 안 함).

**타깃 대상 및 콘텐츠**: 대상 연령대에서 **아동 제외**(13세 미만 대상 아님).

**정부 앱 / 금융 앱 / 건강 앱**: 아니요.

**포그라운드 서비스(Foreground service) 선언** — Play가 요구 시:
- 사용 유형: **connectedDevice** (블루투스 메시 노드를 백그라운드에서 유지).
- 설명 예: "블루투스로 연결된 주변 기기와 오프라인 메시지를 주고받고 중계하기 위해 화면이 꺼진 동안에도 연결을 유지합니다."
- 필요 시 30초 내외 데모 영상 요청될 수 있음(채팅 화면에서 백그라운드 수신 시연).

**민감 권한 검토 주의(선제 안내)**
- `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`: 백그라운드 메시 중계 유지를 위한 핵심 기능. 검토에서 사유를 물으면 "P2P 오프라인 메신저의 실시간 수신/중계에 필수"로 답변. 만약 반려되면, 이 권한을 빼고(설정 안내로 대체) 재제출하는 대안이 있으니 알려주세요 — 제가 store 플레이버에서 제거해 드립니다.

---

## 🔎 제출 전 최종 체크
- [ ] .aab가 최신(위 빌드 명령으로 재생성한 것)인지
- [ ] 스크린샷 5장이 새 디자인인지 (docs/store/screenshot_*)
- [ ] 개인정보처리방침 URL이 열리는지 (레포가 public이어야 함)
- [ ] 출시 노트 작성 (예: "첫 출시 — 인터넷 없이 블루투스로 대화하는 오프라인 메신저")
