// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 's.dart';

// ignore_for_file: type=lint

/// The translations for Korean (`ko`).
class SKo extends S {
  SKo([String locale = 'ko']) : super(locale);

  @override
  String get appTitle => 'SpotLink';

  @override
  String get commonCancel => '취소';

  @override
  String get commonDelete => '삭제';

  @override
  String get commonSave => '저장';

  @override
  String get notifWakeNudgeTitle => '주변에 SpotLink 친구가 있어요';

  @override
  String get notifWakeNudgeBody => '탭해서 열면 바로 연결됩니다.';

  @override
  String notifReaction(Object emoji) {
    return '$emoji 반응을 남겼습니다';
  }

  @override
  String get notifChannelName => '메시지';

  @override
  String get notifChannelDesc => '새 메시지와 파일 도착 알림';

  @override
  String get errFileCopyFailed => '파일을 저장할 수 없어 보낼 수 없습니다';

  @override
  String get errFileGoneRetry => '원본 파일이 없어 다시 보낼 수 없습니다';

  @override
  String errGallerySave(Object error) {
    return '갤러리 저장 실패: $error';
  }

  @override
  String get errServiceConnecting => '메시 서비스 연결 중…';

  @override
  String get fgsTitle => 'SpotLink 실행 중';

  @override
  String get fgsSearching => '주변 사람을 찾는 중…';

  @override
  String fgsConnected(Object count) {
    return '주변 기기 $count대와 연결됨';
  }

  @override
  String chatSendFailed(Object error) {
    return '전송 실패: $error';
  }

  @override
  String get chatAttachMedia => '사진·동영상';

  @override
  String get chatAttachMediaSubtitle => '갤러리에서 선택 (여러 장 가능)';

  @override
  String get chatAttachFile => '파일';

  @override
  String get chatAttachFileSubtitle => '문서·압축 등 모든 파일';

  @override
  String get chatAttachApk => 'SpotLink 앱 보내기';

  @override
  String get chatAttachApkSubtitle => '설치 파일(APK)을 전달 — 스토어 없이 설치';

  @override
  String chatSkippedAttachments(Object count) {
    return '$count개 파일은 첨부하지 못했어요. 사진 원본이 기기에 없을 수 있어요(iCloud) — 사진 앱에서 한 번 연 뒤 다시 시도해 주세요.';
  }

  @override
  String get chatApkExtractFailed => '설치 파일을 꺼내지 못했습니다';

  @override
  String get chatPresenceNearby => '주변에 있음';

  @override
  String chatPresenceNearbyHops(Object hops) {
    return '주변 · $hops홉 경유';
  }

  @override
  String get chatPresenceOffline => '오프라인 · 전달 대기';

  @override
  String get chatNewMessage => '새 메시지';

  @override
  String get chatAttachTooltip => '파일 첨부';

  @override
  String get chatMessageHint => '메시지';

  @override
  String get chatSendTooltip => '보내기';

  @override
  String get chatUnverifiedNotice =>
      '아직 QR로 인증하지 않은 상대입니다.\n만나면 서로의 QR을 스캔해 신원을 확인하세요.';

  @override
  String get chatIdCopied => 'ID를 복사했습니다';

  @override
  String chatCopyId(Object id) {
    return 'ID $id 복사';
  }

  @override
  String get chatTapRetry => '탭하여 다시 시도';

  @override
  String get chatReceiveInterrupted => '수신이 중단되었습니다';

  @override
  String get chatUndelivered => '아직 전달 안 됨 · 탭하여 다시 보내기';

  @override
  String get chatQueuedHint => '상대를 만나면 자동 전달';

  @override
  String chatTimeSentArrived(Object sent, Object arrived) {
    return '$sent 전송 · $arrived 도착';
  }

  @override
  String get chatAllEmojis => '모든 이모지';

  @override
  String get chatCopy => '복사';

  @override
  String get chatCopied => '복사했습니다';

  @override
  String get chatView => '보기';

  @override
  String get chatSaveToGallery => '갤러리에 저장';

  @override
  String get chatSavedToGallery => '갤러리에 저장했습니다';

  @override
  String get chatSaveToGalleryFailed => '갤러리에 저장하지 못했습니다';

  @override
  String get chatShareSaveToFiles => '공유 · 파일 앱에 저장';

  @override
  String get chatDeleteTitle => '메시지 삭제';

  @override
  String chatDeleteFileContent(Object fileName) {
    return '$fileName이(가) 내 기기에서 삭제됩니다. 상대방 기기에는 남아 있습니다.';
  }

  @override
  String get chatDeleteTextContent => '이 메시지를 내 기기에서 삭제할까요? 상대방 기기에는 남아 있습니다.';

  @override
  String get chatFileFallback => '파일';

  @override
  String get chatCancelSendTitle => '전송 취소';

  @override
  String chatCancelSendContent(Object fileName) {
    return '$fileName 전송을 취소할까요?';
  }

  @override
  String get chatKeepSending => '계속 보내기';

  @override
  String get chatCancelSend => '전송 취소';

  @override
  String get chatStatusSending => '보내는 중';

  @override
  String get chatStatusSent => '전송됨';

  @override
  String get chatStatusDelivered => '전달됨';

  @override
  String get chatStatusFailed => '실패';

  @override
  String get chatStatusQueued => '전달 대기';

  @override
  String get chatImageFallback => '이미지';

  @override
  String chatFileSizeTapOpen(Object size) {
    return '$size · 탭하여 열기';
  }

  @override
  String chatTransferSending(Object percent) {
    return '보내는 중 $percent%';
  }

  @override
  String chatTransferReceiving(Object percent) {
    return '받는 중 $percent%';
  }

  @override
  String get chatSentFile => '보낸 파일';

  @override
  String get chatReceivedFile => '받은 파일';

  @override
  String get chatLaneWifi => 'Wi-Fi 다이렉트';

  @override
  String get chatLaneBle => '블루투스';

  @override
  String get chatEncryptedTitle => '종단 간 암호화된 대화입니다';

  @override
  String get chatEncryptedSubtitle => '첫 인사를 건네보세요 👋';

  @override
  String get chatShare => '공유';

  @override
  String get meIdCopied => 'ID를 복사했습니다';

  @override
  String meIdLabel(Object id) {
    return 'ID $id';
  }

  @override
  String get meQrGuide =>
      '친구가 이 코드를 스캔하면 안전하게 추가됩니다.\n키는 암호화되지 않은 채로 기기를 떠나지 않습니다.';

  @override
  String get meShareSubject => 'SpotLink에서 저를 추가하세요';

  @override
  String get meShareInvite => '초대 코드 공유';

  @override
  String get meSettingsTitle => '설정';

  @override
  String get meBatterySaverTitle => '배터리 절약 (항상)';

  @override
  String get meBatterySaverSubtitle =>
      '평소엔 충전·배터리·연결 상태에 맞춰 자동 조절됩니다. 켜면 항상 최대 절전으로 고정합니다 (검색이 느려짐).';

  @override
  String get meRelayStoreTitle => '중계 보관함';

  @override
  String get meRelayStoreEmpty => '보관 중인 중계 메시지가 없습니다.';

  @override
  String meRelayStorePending(Object count, Object size) {
    return '전달 대기 메시지 $count개 · $size\n수신자를 만나면 자동 전달되고 지워집니다.';
  }

  @override
  String get meRelayClear => '비우기';

  @override
  String get meGuideTitle => '사용법과 동작 원리';

  @override
  String get meGuideSubtitle => '첫 실행 때 본 안내를 다시 볼 수 있습니다.';

  @override
  String get meShareApkTitle => '앱 공유 (오프라인 배포)';

  @override
  String get meShareApkSubtitle =>
      '설치 파일(APK)을 꺼내 공유합니다 — 스토어·인터넷 없이 Quick Share·블루투스 등으로 전달할 수 있습니다.';

  @override
  String get meBeaconTitle => '꺼진 뒤에도 깨어나기 (비콘)';

  @override
  String get meBeaconSubtitle =>
      '주변 SpotLink 기기의 비콘을 감지하면 앱이 종료됐어도 iOS가 깨워서 메시지를 받습니다. 위치 권한(항상 허용)이 필요합니다.';

  @override
  String get meBeaconAlwaysTitle => '연결이 더 잘 되게 하려면';

  @override
  String get meBeaconAlwaysSubtitle =>
      '위치 권한이 \"앱을 사용하는 동안\"입니다. \"항상 허용\"으로 바꾸면 앱을 완전히 종료했거나 폰을 재부팅한 뒤에도 자동으로 다시 연결됩니다. (지금도 백그라운드 연결은 됩니다.)';

  @override
  String get meOpenSettings => '설정';

  @override
  String get meLiveReceiveTitle => '실시간 수신 안내';

  @override
  String get meLiveReceiveSubtitle =>
      '앱을 위로 밀어 완전히 종료하면 실시간 수신이 멈춥니다. 홈으로 나가 백그라운드에 두면 계속 받을 수 있고, 놓친 메시지도 다시 만나면 자동으로 도착합니다.';

  @override
  String get meShareApkFailed => '설치 파일을 꺼내지 못했습니다';

  @override
  String get meShareApkSubject => 'SpotLink 설치 파일';

  @override
  String get meRelayClearTitle => '중계 보관함 비우기';

  @override
  String get meRelayClearBody =>
      '상대에게 전달되기를 기다리는 메시지를 모두 삭제합니다.\n삭제하면 이 기기를 통해서는 전달되지 않습니다 (다른 중계 기기가 갖고 있다면 그쪽으로는 전달될 수 있음).';

  @override
  String get meEditNameTitle => '이름 변경';

  @override
  String get meDisplayNameLabel => '표시 이름';

  @override
  String get meBatteryExemptTitle => '백그라운드 항상 실행';

  @override
  String get meBatteryChecking => '확인 중…';

  @override
  String get meBatteryExemptOn => '배터리 최적화에서 제외되어 있습니다. 화면을 꺼도 메시가 유지됩니다.';

  @override
  String get meBatteryExemptOff =>
      '배터리 최적화가 켜져 있어 시스템이 수신을 중단시킬 수 있습니다. 항상 받으려면 허용해 주세요.';

  @override
  String get meBatteryAllow => '허용';

  @override
  String get meVersionCopied => '버전을 복사했습니다';

  @override
  String get meAvatarNudgeText => '지금은 무작위로 만들어진 아바타예요.\n나만의 모습으로 바꿔보세요!';

  @override
  String get meAvatarNudgeCreate => '만들기';

  @override
  String get meAvatarNudgeLater => '나중에';

  @override
  String get avatarSaved => '저장했어요 — 이제 주변 친구들에게 이 모습으로 보여요';

  @override
  String get avatarTitle => '내 아바타 만들기';

  @override
  String get avatarShuffleTooltip => '무작위 조합';

  @override
  String get avatarHint => '파츠를 조합해 나만의 아바타를 만드세요 · 🎲로 굴려보기';

  @override
  String get avatarPartHairstyle => '머리 스타일';

  @override
  String get avatarPartHairColor => '머리 색';

  @override
  String get avatarPartFacialHair => '수염';

  @override
  String get avatarPartFacialHairColor => '수염 색';

  @override
  String get avatarPartOutfit => '옷';

  @override
  String get avatarPartOutfitColor => '옷 색';

  @override
  String get avatarPartEyes => '눈';

  @override
  String get avatarPartEyebrows => '눈썹';

  @override
  String get avatarPartMouth => '입';

  @override
  String get avatarPartSkin => '피부색';

  @override
  String get avatarPartAccessories => '안경·액세서리';

  @override
  String get peopleSearchHint => '이름으로 찾기';

  @override
  String get peopleSectionNearby => '주변';

  @override
  String get peopleSectionVerified => '인증된 친구';

  @override
  String get peopleSectionChatted => '대화했던 친구';

  @override
  String peopleSectionHeader(Object label, Object count) {
    return '$label · $count';
  }

  @override
  String get peopleBoosting => '집중 탐색 중';

  @override
  String get peopleScanning => '탐색 중';

  @override
  String peopleTileSubtitle(Object id, Object proximity) {
    return '$id · $proximity';
  }

  @override
  String get peopleStatusOffline => '오프라인';

  @override
  String peopleContactId(Object id) {
    return 'ID $id';
  }

  @override
  String get peopleActionChat => '대화하기';

  @override
  String get peopleActionRename => '이름 변경';

  @override
  String peopleDeleteTitle(Object name) {
    return '$name 삭제';
  }

  @override
  String get peopleDeleteBody =>
      '대화 내용과 주고받은 파일이 함께 삭제됩니다.\n\n차단 기능이 아니므로, 상대가 주변에 있으면 새 연락처로 다시 나타날 수 있습니다.';

  @override
  String get peopleDisplayNameLabel => '표시 이름';

  @override
  String get peopleEmptyTitle => '아직 아무도 없어요';

  @override
  String get peopleEmptyBody =>
      '주변의 SpotLink 사용자가 자동으로 나타납니다.\n친구의 QR 코드를 스캔해 안전하게 추가하고 인증하세요.';

  @override
  String get peopleAddFriendQr => 'QR로 친구 추가';

  @override
  String get peopleBluetoothOff => '블루투스가 꺼져 있거나 권한이 없습니다.';

  @override
  String radarTitle(Object count) {
    return '주변 친구 $count';
  }

  @override
  String radarTitleCapped(Object total, Object cap) {
    return '주변 $total명 · 가까운 $cap명 표시';
  }

  @override
  String get radarResetZoom => '원래 배율';

  @override
  String get radarLegendVerified => '인증된 친구';

  @override
  String get radarLegendChatted => '대화한 친구';

  @override
  String get radarLegendDiscovered => '배지 없음: 주변에서 발견';

  @override
  String radarZoomHint(Object scale) {
    return '$scale× · 두 번 탭하면 원래대로';
  }

  @override
  String get radarPanZoomHint => '가까울수록 중앙 · 핀치로 확대, 드래그로 이동';

  @override
  String radarOverflow(Object count) {
    return '+$count명';
  }

  @override
  String get radarCardHint => '가까울수록 중앙에 표시됩니다';

  @override
  String get chatsEmptyPreview => '대화를 시작해보세요';

  @override
  String get chatsMePrefix => '나: ';

  @override
  String get chatsFileFallback => '파일';

  @override
  String get chatsEmptyTitle => '아직 대화가 없어요';

  @override
  String get chatsEmptyBody => '인터넷 없이, 주변 친구와 바로 대화할 수 있어요.';

  @override
  String get chatsFindPeople => '주변 친구 보기';

  @override
  String get chatsAddFriendQr => 'QR로 친구 추가';

  @override
  String scanAddedContact(Object name) {
    return '$name님을 추가했습니다 ✓';
  }

  @override
  String scanAddFailed(Object error) {
    return '추가 실패: $error';
  }

  @override
  String get scanTitle => 'QR 코드 스캔';

  @override
  String get scanFlash => '플래시';

  @override
  String get scanHint => '친구의 SpotLink QR 코드를 사각형 안에 맞춰주세요';

  @override
  String get utilProximityVeryNear => '바로 옆';

  @override
  String get utilProximityNear => '가까이';

  @override
  String get utilProximityNearby => '근처';

  @override
  String get utilProximityFar => '멀리';

  @override
  String get utilProximityUnknown => '주변';

  @override
  String utilProximityRelayed(Object hops) {
    return '$hops홉 건너';
  }

  @override
  String get utilJustNow => '지금';

  @override
  String utilMinutesAgo(Object minutes) {
    return '$minutes분';
  }

  @override
  String get utilYesterday => '어제';

  @override
  String get utilToday => '오늘';

  @override
  String get homeTabChats => '채팅';

  @override
  String get homeTabNearby => '주변';

  @override
  String get homeTabMe => '내 정보';

  @override
  String get homeStatusOff => '꺼짐';

  @override
  String homeStatusMesh(Object count) {
    return '메시 $count';
  }

  @override
  String get homeStatusScanning => '검색 중';

  @override
  String homeSemanticsConnected(Object count) {
    return '$count개 기기 연결됨';
  }

  @override
  String get homeSemanticsScanning => '주변 검색 중';

  @override
  String get homeSemanticsNoConnection => '연결 없음';

  @override
  String get homeSheetTitle => '메시 상태';

  @override
  String get homeStatConnected => '연결된 기기';

  @override
  String get homeStatNearby => '주변 친구';

  @override
  String get homeStatRelayQueue => '중계 대기';

  @override
  String get homeBatterySaver => '배터리 절약';

  @override
  String get homeBtPoweredOff => '블루투스가 꺼져 있습니다. 블루투스를 켜면 자동으로 주변 검색을 시작합니다.';

  @override
  String get homeBtUnauthorized =>
      '블루투스 권한이 없습니다. 설정 > SpotLink에서 블루투스를 허용해 주세요.';

  @override
  String get homeBtUnauthorizedDesktop =>
      '블루투스 권한이 없습니다. 시스템 설정 > 개인정보 보호 및 보안 > 블루투스에서 SpotLink를 허용해 주세요.';

  @override
  String get homeBtUnavailable => '블루투스가 꺼져 있거나 권한이 없어 주변 친구를 찾을 수 없습니다.';

  @override
  String get homeOpenSettings => '설정 열기';

  @override
  String get guideTitle => 'SpotLink 사용법';

  @override
  String get guideSection1Title => '인터넷이 필요 없어요';

  @override
  String get guideSection1Body =>
      'SpotLink는 블루투스로 주변 기기와 직접 연결됩니다. 통신망이 끊긴 곳, 해외, 재난 상황에서도 근처 친구와 대화할 수 있어요.';

  @override
  String get guideSection2Title => '친구는 QR로 안전하게';

  @override
  String get guideSection2Body =>
      '친구 탭의 QR 버튼으로 상대의 코드를 스캔하면 서로의 암호 키가 교환되어 인증된 친구가 됩니다. 주변에서 발견된 사용자도 자동으로 나타나요.';

  @override
  String get guideSection3Title => '친구를 건너 멀리까지';

  @override
  String get guideSection3Body =>
      '직접 닿지 않는 거리라도 중간에 다른 SpotLink 기기가 있으면 메시지가 릴레이되어 전달됩니다. 친구 탭의 레이더에서 누가 몇 홉 거리인지 볼 수 있어요.';

  @override
  String get guideSection4Title => '지금 없으면, 만났을 때';

  @override
  String get guideSection4Body =>
      '상대가 범위 밖이면 메시지를 보관했다가 다시 만나는 순간 자동으로 전달합니다. 늦게 도착한 메시지에는 보낸 시각과 도착한 시각이 함께 표시돼요.';

  @override
  String get guideSection5Title => '내용은 둘만 볼 수 있어요';

  @override
  String get guideSection5Body =>
      '모든 메시지는 종단간 암호화됩니다. 중간에서 릴레이해 주는 기기도 내용을 읽을 수 없어요.';

  @override
  String get guideSection6Title => '배터리는 알아서 아껴요';

  @override
  String get guideSection6Body =>
      '연결이 안정되면 자동으로 절전 모드로 내려가고, 충전 중이거나 새 친구를 찾을 땐 빠른 모드로 올라갑니다. 앱을 꺼도 근처 친구가 다시 깨워줄 수 있어요.';

  @override
  String get guideDontShowAgain => '다시 보지 않기';

  @override
  String get guideStart => '시작하기';

  @override
  String get onboardingWelcome => 'SpotLink에\n오신 걸 환영합니다';

  @override
  String get onboardingSubtitle =>
      '주변 친구들에게 표시될 이름을 정해주세요.\n인터넷 없이 블루투스로 안전하게 대화합니다.';

  @override
  String get onboardingNameLabel => '표시 이름';

  @override
  String get onboardingNameHint => '예: 김정훈';

  @override
  String get onboardingStart => '시작하기';

  @override
  String get bootStepNotifications => '알림 준비';

  @override
  String get bootStepPermissions => '권한 요청';

  @override
  String bootStepFailed(Object label, Object error) {
    return '$label 실패: $error';
  }

  @override
  String bootLaunchFailed(Object attempt, Object error) {
    return '시작 실패 ($attempt회): $error';
  }

  @override
  String bootRetrying(Object error) {
    return '$error\n자동으로 다시 시도합니다';
  }

  @override
  String get encTitle => '스쳐간 친구';

  @override
  String get encEntryTitle => '스쳐간 친구';

  @override
  String get encEntryEmpty => '친구가 근처를 지나가면 여기에 남아요';

  @override
  String encEntryRecent(Object name, Object when) {
    return '최근 $name · $when';
  }

  @override
  String get encEmptyTitle => '아직 스쳐간 친구가 없어요';

  @override
  String get encEmptyBody =>
      'SpotLink 친구가 근처를 지나가면 언제, 누가, 어디서였는지 이 기기에 남겨 둬요. 앱을 보고 있지 않았어도요.';

  @override
  String get encUnknownPeer => '확인되지 않은 SpotLink 사용자';

  @override
  String get encUnknownHint => '가까이 왔지만 연결되기 전에 멀어졌어요';

  @override
  String get encMissed => '놓침';

  @override
  String get encAutoSent => '자동 메시지 보냄';

  @override
  String get encDirect => '직접';

  @override
  String encViaHops(Object hops) {
    return '$hops홉 경유';
  }

  @override
  String get encBriefly => '잠깐';

  @override
  String encForMinutes(Object minutes) {
    return '$minutes분 동안';
  }

  @override
  String get encNoLocation => '위치 없음';

  @override
  String get encLocationToggle => '위치 함께 기록';

  @override
  String get encLocationNote => '이 기기에만 저장돼요. 장소 이름은 기기의 지도 서비스에 좌표를 조회해 찾아요';

  @override
  String get encLocationNoteForeground =>
      '이 기기에만 저장되고, 이 기기에서는 앱이 열려 있을 때만 기록해요. 장소 이름은 기기의 지도 서비스에 좌표를 조회해 찾아요';

  @override
  String get encClear => '기록 지우기';

  @override
  String get encClearTitle => '스쳐간 기록을 모두 지울까요?';

  @override
  String get encClearBody => '시간과 위치 기록이 이 기기에서 삭제돼요. 되돌릴 수 없어요.';

  @override
  String get encCleared => '기록을 지웠어요';

  @override
  String get autoMsgTitle => '스쳐 지날 때 자동 메시지';

  @override
  String get autoMsgOff => '꺼짐';

  @override
  String get autoMsgHint => '예: 근처에 있었네! 다음에 커피 한잔해';

  @override
  String autoMsgHelp(Object hours) {
    return '이 친구와 연결되면 자동으로 보내요. 같은 친구에게는 $hours시간에 한 번만 보내요.';
  }

  @override
  String get autoMsgTurnOff => '끄기';

  @override
  String get autoMsgSaved => '자동 메시지를 설정했어요';

  @override
  String get autoMsgCleared => '자동 메시지를 껐어요';
}
