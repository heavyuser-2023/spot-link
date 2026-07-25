// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 's.dart';

// ignore_for_file: type=lint

/// The translations for Japanese (`ja`).
class SJa extends S {
  SJa([String locale = 'ja']) : super(locale);

  @override
  String get appTitle => 'SpotLink';

  @override
  String get commonCancel => 'キャンセル';

  @override
  String get commonDelete => '削除';

  @override
  String get commonSave => '保存';

  @override
  String get notifWakeNudgeTitle => '近くにSpotLinkの友だちがいます';

  @override
  String get notifWakeNudgeBody => 'タップして開くとすぐつながります。';

  @override
  String notifReaction(Object emoji) {
    return '$emoji のリアクションをつけました';
  }

  @override
  String get notifChannelName => 'メッセージ';

  @override
  String get notifChannelDesc => '新着メッセージとファイル到着の通知';

  @override
  String get errFileCopyFailed => 'ファイルを保存できないため送信できません';

  @override
  String get errFileGoneRetry => '元のファイルがないため再送できません';

  @override
  String errGallerySave(Object error) {
    return 'ギャラリー保存に失敗: $error';
  }

  @override
  String get errServiceConnecting => 'メッシュサービスに接続中…';

  @override
  String get fgsTitle => 'SpotLink 実行中';

  @override
  String get fgsSearching => '近くの人を探しています…';

  @override
  String fgsConnected(Object count) {
    return '近くの$count台と接続中';
  }

  @override
  String chatSendFailed(Object error) {
    return '送信失敗: $error';
  }

  @override
  String get chatAttachMedia => '写真・動画';

  @override
  String get chatAttachMediaSubtitle => 'ギャラリーから選択（複数可）';

  @override
  String get chatAttachFile => 'ファイル';

  @override
  String get chatAttachFileSubtitle => '文書・圧縮などすべてのファイル';

  @override
  String get chatAttachApk => 'SpotLinkアプリを送る';

  @override
  String get chatAttachApkSubtitle => 'インストーラー(APK)を渡す — ストア不要でインストール';

  @override
  String chatSkippedAttachments(Object count) {
    return '$count件のファイルを添付できませんでした。原本が端末にない可能性があります(iCloud) — 写真アプリで一度開いてから再試行してください。';
  }

  @override
  String get chatApkExtractFailed => 'インストーラーを取り出せませんでした';

  @override
  String get chatPresenceNearby => '近くにいます';

  @override
  String chatPresenceNearbyHops(Object hops) {
    return '近く · $hopsホップ経由';
  }

  @override
  String get chatPresenceOffline => 'オフライン · 後で配達';

  @override
  String get chatNewMessage => '新着メッセージ';

  @override
  String get chatAttachTooltip => 'ファイルを添付';

  @override
  String get chatMessageHint => 'メッセージ';

  @override
  String get chatSendTooltip => '送信';

  @override
  String get chatUnverifiedNotice =>
      'まだQRで認証していない相手です。\n会ったらお互いのQRをスキャンして本人確認しましょう。';

  @override
  String get chatIdCopied => 'IDをコピーしました';

  @override
  String chatCopyId(Object id) {
    return 'ID $id をコピー';
  }

  @override
  String get chatTapRetry => 'タップして再試行';

  @override
  String get chatReceiveInterrupted => '受信が中断されました';

  @override
  String get chatUndelivered => 'まだ未配達 · タップして再送';

  @override
  String get chatQueuedHint => '相手に会うと自動配達';

  @override
  String chatTimeSentArrived(Object sent, Object arrived) {
    return '$sent 送信 · $arrived 到着';
  }

  @override
  String get chatAllEmojis => 'すべての絵文字';

  @override
  String get chatCopy => 'コピー';

  @override
  String get chatCopied => 'コピーしました';

  @override
  String get chatView => '表示';

  @override
  String get chatSaveToGallery => 'ギャラリーに保存';

  @override
  String get chatSavedToGallery => 'ギャラリーに保存しました';

  @override
  String get chatSaveToGalleryFailed => 'ギャラリーに保存できませんでした';

  @override
  String get chatShareSaveToFiles => '共有 · ファイルに保存';

  @override
  String get chatDeleteTitle => 'メッセージを削除';

  @override
  String chatDeleteFileContent(Object fileName) {
    return '$fileName をこの端末から削除します。相手の端末には残ります。';
  }

  @override
  String get chatDeleteTextContent => 'このメッセージをこの端末から削除しますか？相手の端末には残ります。';

  @override
  String get chatFileFallback => 'ファイル';

  @override
  String get chatCancelSendTitle => '送信をキャンセル';

  @override
  String chatCancelSendContent(Object fileName) {
    return '$fileName の送信をキャンセルしますか？';
  }

  @override
  String get chatKeepSending => '送信を続ける';

  @override
  String get chatCancelSend => '送信をキャンセル';

  @override
  String get chatStatusSending => '送信中';

  @override
  String get chatStatusSent => '送信済み';

  @override
  String get chatStatusDelivered => '配達済み';

  @override
  String get chatStatusFailed => '失敗';

  @override
  String get chatStatusQueued => '配達待ち';

  @override
  String get chatImageFallback => '画像';

  @override
  String chatFileSizeTapOpen(Object size) {
    return '$size · タップして開く';
  }

  @override
  String chatTransferSending(Object percent) {
    return '送信中 $percent%';
  }

  @override
  String chatTransferReceiving(Object percent) {
    return '受信中 $percent%';
  }

  @override
  String get chatSentFile => '送ったファイル';

  @override
  String get chatReceivedFile => '受け取ったファイル';

  @override
  String get chatLaneWifi => 'Wi-Fi Direct';

  @override
  String get chatLaneBle => 'Bluetooth';

  @override
  String get chatEncryptedTitle => 'この会話はエンドツーエンドで暗号化されています';

  @override
  String get chatEncryptedSubtitle => '最初のあいさつをどうぞ 👋';

  @override
  String get chatShare => '共有';

  @override
  String get meIdCopied => 'IDをコピーしました';

  @override
  String meIdLabel(Object id) {
    return 'ID $id';
  }

  @override
  String get meQrGuide =>
      '友だちがこのコードをスキャンすると安全に追加されます。\n鍵が暗号化されないまま端末を離れることはありません。';

  @override
  String get meShareSubject => 'SpotLinkで私を追加してください';

  @override
  String get meShareInvite => '招待コードを共有';

  @override
  String get meSettingsTitle => '設定';

  @override
  String get meBatterySaverTitle => 'バッテリーセーバー（常時）';

  @override
  String get meBatterySaverSubtitle =>
      '通常は充電・電池・接続状態に合わせて自動調整されます。オンにすると常に最大節電に固定されます（探索が遅くなります）。';

  @override
  String get meRelayStoreTitle => '中継ボックス';

  @override
  String get meRelayStoreEmpty => '保管中の中継メッセージはありません。';

  @override
  String meRelayStorePending(Object count, Object size) {
    return '配達待ちメッセージ $count件 · $size\n受取人に会うと自動配達され消去されます。';
  }

  @override
  String get meRelayClear => '空にする';

  @override
  String get meGuideTitle => '使い方としくみ';

  @override
  String get meGuideSubtitle => '初回起動時のガイドをもう一度見られます。';

  @override
  String get meShareApkTitle => 'アプリを共有（オフライン配布）';

  @override
  String get meShareApkSubtitle =>
      'インストーラー(APK)を取り出して共有します — ストアもネットも不要で、Quick Share・Bluetoothなどで渡せます。';

  @override
  String get meBeaconTitle => '終了後も目を覚ます（ビーコン）';

  @override
  String get meBeaconSubtitle =>
      '近くのSpotLink端末のビーコンを検知すると、アプリが終了していてもiOSが起こしてメッセージを受信します。位置情報の「常に許可」が必要です。';

  @override
  String get meBeaconAlwaysTitle => 'もっとつながりやすくするには';

  @override
  String get meBeaconAlwaysSubtitle =>
      '位置情報の権限が「使用中のみ」です。「常に」に変えると、完全終了後や再起動後も自動で再接続します。（今もバックグラウンド接続は動作します。）';

  @override
  String get meOpenSettings => '設定';

  @override
  String get meLiveReceiveTitle => 'リアルタイム受信について';

  @override
  String get meLiveReceiveSubtitle =>
      'アプリを上にスワイプして完全終了するとリアルタイム受信が止まります。バックグラウンドに残せば受信し続け、逃したメッセージも再会時に自動で届きます。';

  @override
  String get meShareApkFailed => 'インストーラーを取り出せませんでした';

  @override
  String get meShareApkSubject => 'SpotLink インストーラー';

  @override
  String get meRelayClearTitle => '中継ボックスを空にする';

  @override
  String get meRelayClearBody =>
      '他の人への配達を待っているメッセージをすべて削除します。\n削除するとこの端末経由では配達されません（他の中継端末が持っていればそちらから届くことがあります）。';

  @override
  String get meEditNameTitle => '名前を変更';

  @override
  String get meDisplayNameLabel => '表示名';

  @override
  String get meBatteryExemptTitle => 'バックグラウンドで常時実行';

  @override
  String get meBatteryChecking => '確認中…';

  @override
  String get meBatteryExemptOn => 'バッテリー最適化から除外されています。画面を消してもメッシュは維持されます。';

  @override
  String get meBatteryExemptOff =>
      'バッテリー最適化が有効のため、システムが受信を止めることがあります。常時受信するには許可してください。';

  @override
  String get meBatteryAllow => '許可';

  @override
  String get meVersionCopied => 'バージョンをコピーしました';

  @override
  String get meAvatarNudgeText => '今はランダム生成されたアバターです。\n自分らしい姿に変えてみましょう！';

  @override
  String get meAvatarNudgeCreate => '作成';

  @override
  String get meAvatarNudgeLater => 'あとで';

  @override
  String get avatarSaved => '保存しました — 近くの友だちにこの姿で表示されます';

  @override
  String get avatarTitle => 'マイアバターを作る';

  @override
  String get avatarShuffleTooltip => 'ランダム組み合わせ';

  @override
  String get avatarHint => 'パーツを組み合わせて自分だけのアバターを · 🎲で回してみる';

  @override
  String get avatarPartHairstyle => 'ヘアスタイル';

  @override
  String get avatarPartHairColor => '髪の色';

  @override
  String get avatarPartFacialHair => 'ひげ';

  @override
  String get avatarPartFacialHairColor => 'ひげの色';

  @override
  String get avatarPartOutfit => '服';

  @override
  String get avatarPartOutfitColor => '服の色';

  @override
  String get avatarPartEyes => '目';

  @override
  String get avatarPartEyebrows => '眉';

  @override
  String get avatarPartMouth => '口';

  @override
  String get avatarPartSkin => '肌の色';

  @override
  String get avatarPartAccessories => 'メガネ・アクセサリー';

  @override
  String get peopleSearchHint => '名前で探す';

  @override
  String get peopleSectionNearby => '近く';

  @override
  String get peopleSectionVerified => '認証済みの友だち';

  @override
  String get peopleSectionChatted => '話したことのある友だち';

  @override
  String peopleSectionHeader(Object label, Object count) {
    return '$label · $count';
  }

  @override
  String get peopleBoosting => '集中スキャン中';

  @override
  String get peopleScanning => 'スキャン中';

  @override
  String peopleTileSubtitle(Object id, Object proximity) {
    return '$id · $proximity';
  }

  @override
  String get peopleStatusOffline => 'オフライン';

  @override
  String peopleContactId(Object id) {
    return 'ID $id';
  }

  @override
  String get peopleActionChat => 'チャット';

  @override
  String get peopleActionRename => '名前を変更';

  @override
  String peopleDeleteTitle(Object name) {
    return '$name を削除';
  }

  @override
  String get peopleDeleteBody =>
      '会話内容とやり取りしたファイルも一緒に削除されます。\n\nブロックではないため、相手が近くにいれば新しい連絡先として再び現れることがあります。';

  @override
  String get peopleDisplayNameLabel => '表示名';

  @override
  String get peopleEmptyTitle => 'まだ誰もいません';

  @override
  String get peopleEmptyBody =>
      '近くのSpotLinkユーザーが自動で表示されます。\n友だちのQRコードをスキャンして安全に追加・認証しましょう。';

  @override
  String get peopleAddFriendQr => 'QRで友だち追加';

  @override
  String get peopleBluetoothOff => 'Bluetoothがオフか、権限がありません。';

  @override
  String radarTitle(Object count) {
    return '近くの友だち $count';
  }

  @override
  String radarTitleCapped(Object total, Object cap) {
    return '近く$total人 · 近い$cap人を表示';
  }

  @override
  String get radarResetZoom => '元の倍率';

  @override
  String get radarLegendVerified => '認証済みの友だち';

  @override
  String get radarLegendChatted => '話した友だち';

  @override
  String get radarLegendDiscovered => 'バッジなし: 近くで発見';

  @override
  String radarZoomHint(Object scale) {
    return '$scale× · ダブルタップで元に戻す';
  }

  @override
  String get radarPanZoomHint => '近いほど中央 · ピンチで拡大、ドラッグで移動';

  @override
  String radarOverflow(Object count) {
    return '+$count人';
  }

  @override
  String get radarCardHint => '近いほど中央に表示されます';

  @override
  String get chatsEmptyPreview => '会話を始めましょう';

  @override
  String get chatsMePrefix => '自分: ';

  @override
  String get chatsFileFallback => 'ファイル';

  @override
  String get chatsEmptyTitle => 'まだ会話がありません';

  @override
  String get chatsEmptyBody => 'ネットなしで、近くの友だちとすぐ話せます。';

  @override
  String get chatsFindPeople => '近くの人を見る';

  @override
  String get chatsAddFriendQr => 'QRで友だち追加';

  @override
  String scanAddedContact(Object name) {
    return '$nameさんを追加しました ✓';
  }

  @override
  String scanAddFailed(Object error) {
    return '追加失敗: $error';
  }

  @override
  String get scanTitle => 'QRコードをスキャン';

  @override
  String get scanFlash => 'ライト';

  @override
  String get scanHint => '友だちのSpotLink QRコードを枠に合わせてください';

  @override
  String get utilProximityVeryNear => 'すぐそば';

  @override
  String get utilProximityNear => '近く';

  @override
  String get utilProximityNearby => '付近';

  @override
  String get utilProximityFar => '遠く';

  @override
  String get utilProximityUnknown => '周辺';

  @override
  String utilProximityRelayed(Object hops) {
    return '$hopsホップ先';
  }

  @override
  String get utilJustNow => '今';

  @override
  String utilMinutesAgo(Object minutes) {
    return '$minutes分';
  }

  @override
  String get utilYesterday => '昨日';

  @override
  String get utilToday => '今日';

  @override
  String get homeTabChats => 'チャット';

  @override
  String get homeTabNearby => '近く';

  @override
  String get homeTabMe => 'マイ情報';

  @override
  String get homeStatusOff => 'オフ';

  @override
  String homeStatusMesh(Object count) {
    return 'メッシュ $count';
  }

  @override
  String get homeStatusScanning => '探索中';

  @override
  String homeSemanticsConnected(Object count) {
    return '$count台の端末と接続中';
  }

  @override
  String get homeSemanticsScanning => '周辺を探索中';

  @override
  String get homeSemanticsNoConnection => '接続なし';

  @override
  String get homeSheetTitle => 'メッシュの状態';

  @override
  String get homeStatConnected => '接続中の端末';

  @override
  String get homeStatNearby => '近くの友だち';

  @override
  String get homeStatRelayQueue => '中継待ち';

  @override
  String get homeBatterySaver => 'バッテリーセーバー';

  @override
  String get homeBtPoweredOff => 'Bluetoothがオフです。オンにすると自動で周辺探索を始めます。';

  @override
  String get homeBtUnauthorized =>
      'Bluetoothの権限がありません。設定 > SpotLink で許可してください。';

  @override
  String get homeBtUnauthorizedDesktop =>
      'Bluetoothの権限がありません。システム設定 > プライバシーとセキュリティ > Bluetooth で SpotLink を許可してください。';

  @override
  String get homeBtUnavailable => 'Bluetoothがオフか権限がないため、近くの友だちを探せません。';

  @override
  String get homeOpenSettings => '設定を開く';

  @override
  String get guideTitle => 'SpotLinkの使い方';

  @override
  String get guideSection1Title => 'インターネット不要';

  @override
  String get guideSection1Body =>
      'SpotLinkはBluetoothで近くの端末と直接つながります。通信網が途絶えた場所、海外、災害時でも近くの友だちと話せます。';

  @override
  String get guideSection2Title => '友だちはQRで安全に';

  @override
  String get guideSection2Body =>
      '「近く」タブのQRボタンで相手のコードをスキャンすると、お互いの暗号鍵が交換され認証済みの友だちになります。近くで見つかったユーザーも自動で表示されます。';

  @override
  String get guideSection3Title => '友だちを越えて遠くまで';

  @override
  String get guideSection3Body =>
      '直接届かない距離でも、間に他のSpotLink端末があればメッセージが中継されて届きます。「近く」タブのレーダーで誰が何ホップ先か見られます。';

  @override
  String get guideSection4Title => '今いなければ、会ったときに';

  @override
  String get guideSection4Body =>
      '相手が圏外ならメッセージを保管し、再会した瞬間に自動で配達します。遅れて届いたメッセージには送信時刻と到着時刻の両方が表示されます。';

  @override
  String get guideSection5Title => '内容は二人だけのもの';

  @override
  String get guideSection5Body =>
      'すべてのメッセージはエンドツーエンドで暗号化されます。途中で中継する端末も内容を読めません。';

  @override
  String get guideSection6Title => 'バッテリーは自動で節約';

  @override
  String get guideSection6Body =>
      '接続が安定すると自動で省電力に下がり、充電中や新しい友だちを探すときは高速モードに上がります。アプリを閉じても近くの友だちがまた起こしてくれます。';

  @override
  String get guideDontShowAgain => '今後表示しない';

  @override
  String get guideStart => 'はじめる';

  @override
  String get onboardingWelcome => 'SpotLinkへ\nようこそ';

  @override
  String get onboardingSubtitle =>
      '近くの友だちに表示される名前を決めてください。\nネットなしでBluetoothで安全に話せます。';

  @override
  String get onboardingNameLabel => '表示名';

  @override
  String get onboardingNameHint => '例: 田中';

  @override
  String get onboardingStart => 'はじめる';

  @override
  String get bootStepNotifications => '通知の準備';

  @override
  String get bootStepPermissions => '権限のリクエスト';

  @override
  String bootStepFailed(Object label, Object error) {
    return '$label 失敗: $error';
  }

  @override
  String bootLaunchFailed(Object attempt, Object error) {
    return '起動失敗（$attempt回目）: $error';
  }

  @override
  String bootRetrying(Object error) {
    return '$error\n自動で再試行します';
  }
}
