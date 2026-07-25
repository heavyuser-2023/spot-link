// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 's.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class SZh extends S {
  SZh([String locale = 'zh']) : super(locale);

  @override
  String get appTitle => 'SpotLink';

  @override
  String get commonCancel => '取消';

  @override
  String get commonDelete => '删除';

  @override
  String get commonSave => '保存';

  @override
  String get notifWakeNudgeTitle => '附近有 SpotLink 好友';

  @override
  String get notifWakeNudgeBody => '点按打开即可立刻连接。';

  @override
  String notifReaction(Object emoji) {
    return '回应了 $emoji';
  }

  @override
  String get notifChannelName => '消息';

  @override
  String get notifChannelDesc => '新消息和文件到达提醒';

  @override
  String get errFileCopyFailed => '无法保存文件，因此无法发送';

  @override
  String get errFileGoneRetry => '原文件已丢失，无法重新发送';

  @override
  String errGallerySave(Object error) {
    return '保存到相册失败：$error';
  }

  @override
  String get errServiceConnecting => '正在连接网状服务…';

  @override
  String get fgsTitle => 'SpotLink 运行中';

  @override
  String get fgsSearching => '正在寻找附近的人…';

  @override
  String fgsConnected(Object count) {
    return '已连接附近 $count 台设备';
  }

  @override
  String chatSendFailed(Object error) {
    return '发送失败：$error';
  }

  @override
  String get chatAttachMedia => '照片·视频';

  @override
  String get chatAttachMediaSubtitle => '从相册选择（可多选）';

  @override
  String get chatAttachFile => '文件';

  @override
  String get chatAttachFileSubtitle => '文档、压缩包等所有文件';

  @override
  String get chatAttachApk => '发送 SpotLink 应用';

  @override
  String get chatAttachApkSubtitle => '传送安装包(APK) — 无需商店即可安装';

  @override
  String chatSkippedAttachments(Object count) {
    return '有 $count 个文件未能附加。原件可能不在本机(iCloud) — 请在照片应用中打开一次后重试。';
  }

  @override
  String get chatApkExtractFailed => '无法提取安装包';

  @override
  String get chatPresenceNearby => '就在附近';

  @override
  String chatPresenceNearbyHops(Object hops) {
    return '附近 · 经 $hops 跳';
  }

  @override
  String get chatPresenceOffline => '离线 · 稍后送达';

  @override
  String get chatNewMessage => '新消息';

  @override
  String get chatAttachTooltip => '附加文件';

  @override
  String get chatMessageHint => '消息';

  @override
  String get chatSendTooltip => '发送';

  @override
  String get chatUnverifiedNotice => '对方尚未通过二维码认证。\n见面时请互相扫描二维码确认身份。';

  @override
  String get chatIdCopied => '已复制 ID';

  @override
  String chatCopyId(Object id) {
    return '复制 ID $id';
  }

  @override
  String get chatTapRetry => '点按重试';

  @override
  String get chatReceiveInterrupted => '接收已中断';

  @override
  String get chatUndelivered => '尚未送达 · 点按重发';

  @override
  String get chatQueuedHint => '相遇时自动送达';

  @override
  String chatTimeSentArrived(Object sent, Object arrived) {
    return '$sent 发送 · $arrived 到达';
  }

  @override
  String get chatAllEmojis => '全部表情';

  @override
  String get chatCopy => '复制';

  @override
  String get chatCopied => '已复制';

  @override
  String get chatView => '查看';

  @override
  String get chatSaveToGallery => '保存到相册';

  @override
  String get chatSavedToGallery => '已保存到相册';

  @override
  String get chatSaveToGalleryFailed => '无法保存到相册';

  @override
  String get chatShareSaveToFiles => '分享 · 保存到文件';

  @override
  String get chatDeleteTitle => '删除消息';

  @override
  String chatDeleteFileContent(Object fileName) {
    return '$fileName 将从本机删除。对方设备上仍会保留。';
  }

  @override
  String get chatDeleteTextContent => '从本机删除这条消息吗？对方设备上仍会保留。';

  @override
  String get chatFileFallback => '文件';

  @override
  String get chatCancelSendTitle => '取消传输';

  @override
  String chatCancelSendContent(Object fileName) {
    return '取消发送 $fileName 吗？';
  }

  @override
  String get chatKeepSending => '继续发送';

  @override
  String get chatCancelSend => '取消传输';

  @override
  String get chatStatusSending => '发送中';

  @override
  String get chatStatusSent => '已发送';

  @override
  String get chatStatusDelivered => '已送达';

  @override
  String get chatStatusFailed => '失败';

  @override
  String get chatStatusQueued => '等待送达';

  @override
  String get chatImageFallback => '图片';

  @override
  String chatFileSizeTapOpen(Object size) {
    return '$size · 点按打开';
  }

  @override
  String chatTransferSending(Object percent) {
    return '发送中 $percent%';
  }

  @override
  String chatTransferReceiving(Object percent) {
    return '接收中 $percent%';
  }

  @override
  String get chatSentFile => '发出的文件';

  @override
  String get chatReceivedFile => '收到的文件';

  @override
  String get chatLaneWifi => 'Wi-Fi 直连';

  @override
  String get chatLaneBle => '蓝牙';

  @override
  String get chatEncryptedTitle => '此对话已端到端加密';

  @override
  String get chatEncryptedSubtitle => '打个招呼吧 👋';

  @override
  String get chatShare => '分享';

  @override
  String get meIdCopied => '已复制 ID';

  @override
  String meIdLabel(Object id) {
    return 'ID $id';
  }

  @override
  String get meQrGuide => '好友扫描此码即可安全添加。\n密钥绝不会以未加密形式离开设备。';

  @override
  String get meShareSubject => '在 SpotLink 上添加我';

  @override
  String get meShareInvite => '分享邀请码';

  @override
  String get meSettingsTitle => '设置';

  @override
  String get meBatterySaverTitle => '省电模式（始终）';

  @override
  String get meBatterySaverSubtitle =>
      '平时会根据充电、电量和连接状态自动调节。开启后将始终锁定最大省电（搜索会变慢）。';

  @override
  String get meRelayStoreTitle => '中继信箱';

  @override
  String get meRelayStoreEmpty => '没有暂存的中继消息。';

  @override
  String meRelayStorePending(Object count, Object size) {
    return '$count 条待送达消息 · $size\n遇到收件人后会自动送达并清除。';
  }

  @override
  String get meRelayClear => '清空';

  @override
  String get meGuideTitle => '使用方法与原理';

  @override
  String get meGuideSubtitle => '重温首次启动时的引导。';

  @override
  String get meShareApkTitle => '分享应用（离线分发）';

  @override
  String get meShareApkSubtitle =>
      '提取并分享安装包(APK) — 无需商店和网络，可通过 Quick Share、蓝牙等传递。';

  @override
  String get meBeaconTitle => '关闭后也能唤醒（信标）';

  @override
  String get meBeaconSubtitle =>
      '检测到附近 SpotLink 设备的信标时，即使应用已关闭，iOS 也会唤醒它接收消息。需要“始终允许”的位置权限。';

  @override
  String get meBeaconAlwaysTitle => '让连接更可靠';

  @override
  String get meBeaconAlwaysSubtitle =>
      '位置权限目前为“使用期间”。改为“始终”后，即使完全关闭应用或重启手机也能自动重连。（目前后台连接仍可用。）';

  @override
  String get meOpenSettings => '设置';

  @override
  String get meLiveReceiveTitle => '关于实时接收';

  @override
  String get meLiveReceiveSubtitle =>
      '上滑彻底关闭应用会停止实时接收。留在后台即可持续接收，错过的消息在再次相遇时也会自动送达。';

  @override
  String get meShareApkFailed => '无法提取安装包';

  @override
  String get meShareApkSubject => 'SpotLink 安装包';

  @override
  String get meRelayClearTitle => '清空中继信箱';

  @override
  String get meRelayClearBody =>
      '删除所有等待送达给他人的消息。\n删除后将不会经由本机送达（若其他中继设备持有副本，仍可能由那里送达）。';

  @override
  String get meEditNameTitle => '修改名字';

  @override
  String get meDisplayNameLabel => '显示名称';

  @override
  String get meBatteryExemptTitle => '后台常驻运行';

  @override
  String get meBatteryChecking => '检查中…';

  @override
  String get meBatteryExemptOn => '已从电池优化中排除。熄屏后网状网络仍会保持。';

  @override
  String get meBatteryExemptOff => '电池优化已开启，系统可能会中断接收。要始终接收，请允许此项。';

  @override
  String get meBatteryAllow => '允许';

  @override
  String get meVersionCopied => '已复制版本号';

  @override
  String get meAvatarNudgeText => '这是随机生成的头像。\n换成属于你自己的样子吧！';

  @override
  String get meAvatarNudgeCreate => '创建';

  @override
  String get meAvatarNudgeLater => '以后再说';

  @override
  String get avatarSaved => '已保存 — 附近的好友现在会看到这个形象';

  @override
  String get avatarTitle => '创建我的头像';

  @override
  String get avatarShuffleTooltip => '随机组合';

  @override
  String get avatarHint => '组合部件打造专属头像 · 用 🎲 试试手气';

  @override
  String get avatarPartHairstyle => '发型';

  @override
  String get avatarPartHairColor => '发色';

  @override
  String get avatarPartFacialHair => '胡子';

  @override
  String get avatarPartFacialHairColor => '胡子颜色';

  @override
  String get avatarPartOutfit => '服装';

  @override
  String get avatarPartOutfitColor => '服装颜色';

  @override
  String get avatarPartEyes => '眼睛';

  @override
  String get avatarPartEyebrows => '眉毛';

  @override
  String get avatarPartMouth => '嘴';

  @override
  String get avatarPartSkin => '肤色';

  @override
  String get avatarPartAccessories => '眼镜·配饰';

  @override
  String get peopleSearchHint => '按名字查找';

  @override
  String get peopleSectionNearby => '附近';

  @override
  String get peopleSectionVerified => '已认证好友';

  @override
  String get peopleSectionChatted => '聊过的好友';

  @override
  String peopleSectionHeader(Object label, Object count) {
    return '$label · $count';
  }

  @override
  String get peopleBoosting => '加强扫描中';

  @override
  String get peopleScanning => '扫描中';

  @override
  String peopleTileSubtitle(Object id, Object proximity) {
    return '$id · $proximity';
  }

  @override
  String get peopleStatusOffline => '离线';

  @override
  String peopleContactId(Object id) {
    return 'ID $id';
  }

  @override
  String get peopleActionChat => '聊天';

  @override
  String get peopleActionRename => '改名';

  @override
  String peopleDeleteTitle(Object name) {
    return '删除 $name';
  }

  @override
  String get peopleDeleteBody =>
      '对话内容和互传的文件会一并删除。\n\n这不是拉黑 — 如果对方仍在附近，可能会作为新联系人再次出现。';

  @override
  String get peopleDisplayNameLabel => '显示名称';

  @override
  String get peopleEmptyTitle => '这里还没有人';

  @override
  String get peopleEmptyBody => '附近的 SpotLink 用户会自动出现。\n扫描好友的二维码即可安全添加并认证。';

  @override
  String get peopleAddFriendQr => '扫码加好友';

  @override
  String get peopleBluetoothOff => '蓝牙已关闭或缺少权限。';

  @override
  String radarTitle(Object count) {
    return '附近好友 $count';
  }

  @override
  String radarTitleCapped(Object total, Object cap) {
    return '附近 $total 人 · 显示最近 $cap 人';
  }

  @override
  String get radarResetZoom => '恢复缩放';

  @override
  String get radarLegendVerified => '已认证好友';

  @override
  String get radarLegendChatted => '聊过的好友';

  @override
  String get radarLegendDiscovered => '无徽章：附近发现';

  @override
  String radarZoomHint(Object scale) {
    return '$scale× · 双击复原';
  }

  @override
  String get radarPanZoomHint => '越近越居中 · 双指缩放，拖动平移';

  @override
  String radarOverflow(Object count) {
    return '+$count人';
  }

  @override
  String get radarCardHint => '越近的人越靠近中心';

  @override
  String get chatsEmptyPreview => '开始聊天吧';

  @override
  String get chatsMePrefix => '我: ';

  @override
  String get chatsFileFallback => '文件';

  @override
  String get chatsEmptyTitle => '还没有对话';

  @override
  String get chatsEmptyBody => '无需网络，即刻与附近好友畅聊。';

  @override
  String get chatsFindPeople => '查看附近的人';

  @override
  String get chatsAddFriendQr => '扫码加好友';

  @override
  String scanAddedContact(Object name) {
    return '已添加 $name ✓';
  }

  @override
  String scanAddFailed(Object error) {
    return '添加失败：$error';
  }

  @override
  String get scanTitle => '扫描二维码';

  @override
  String get scanFlash => '手电筒';

  @override
  String get scanHint => '请将好友的 SpotLink 二维码对准框内';

  @override
  String get utilProximityVeryNear => '近在咫尺';

  @override
  String get utilProximityNear => '很近';

  @override
  String get utilProximityNearby => '附近';

  @override
  String get utilProximityFar => '较远';

  @override
  String get utilProximityUnknown => '周围';

  @override
  String utilProximityRelayed(Object hops) {
    return '隔 $hops 跳';
  }

  @override
  String get utilJustNow => '刚刚';

  @override
  String utilMinutesAgo(Object minutes) {
    return '$minutes分钟';
  }

  @override
  String get utilYesterday => '昨天';

  @override
  String get utilToday => '今天';

  @override
  String get homeTabChats => '聊天';

  @override
  String get homeTabNearby => '附近';

  @override
  String get homeTabMe => '我的';

  @override
  String get homeStatusOff => '关闭';

  @override
  String homeStatusMesh(Object count) {
    return '网格 $count';
  }

  @override
  String get homeStatusScanning => '搜索中';

  @override
  String homeSemanticsConnected(Object count) {
    return '已连接 $count 台设备';
  }

  @override
  String get homeSemanticsScanning => '正在搜索附近';

  @override
  String get homeSemanticsNoConnection => '无连接';

  @override
  String get homeSheetTitle => '网格状态';

  @override
  String get homeStatConnected => '已连接设备';

  @override
  String get homeStatNearby => '附近好友';

  @override
  String get homeStatRelayQueue => '中继队列';

  @override
  String get homeBatterySaver => '省电模式';

  @override
  String get homeBtPoweredOff => '蓝牙已关闭。打开蓝牙后会自动开始搜索附近。';

  @override
  String get homeBtUnauthorized => '缺少蓝牙权限。请在 设置 > SpotLink 中允许蓝牙。';

  @override
  String get homeBtUnauthorizedDesktop =>
      '缺少蓝牙权限。请在“系统设置 > 隐私与安全性 > 蓝牙”中允许 SpotLink。';

  @override
  String get homeBtUnavailable => '蓝牙已关闭或未授权，无法寻找附近好友。';

  @override
  String get homeOpenSettings => '打开设置';

  @override
  String get guideTitle => 'SpotLink 使用指南';

  @override
  String get guideSection1Title => '无需互联网';

  @override
  String get guideSection1Body =>
      'SpotLink 通过蓝牙与附近设备直接连接。即使在断网地区、海外或灾害中，也能与身边的朋友聊天。';

  @override
  String get guideSection2Title => '扫码安全加好友';

  @override
  String get guideSection2Body =>
      '在“附近”页用二维码按钮扫描对方的码，即可交换加密密钥成为认证好友。附近发现的用户也会自动出现。';

  @override
  String get guideSection3Title => '借好友传得更远';

  @override
  String get guideSection3Body =>
      '即使超出直连距离，只要中间有其他 SpotLink 设备，消息就会被中继送达。“附近”页的雷达能看到谁在几跳之外。';

  @override
  String get guideSection4Title => '现在不在，见面再送';

  @override
  String get guideSection4Body =>
      '对方超出范围时消息会被暂存，再次相遇的瞬间自动送达。迟到的消息会同时显示发送与到达时间。';

  @override
  String get guideSection5Title => '内容只属于你们俩';

  @override
  String get guideSection5Body => '所有消息均为端到端加密。中途中继的设备也无法读取内容。';

  @override
  String get guideSection6Title => '电量自动节省';

  @override
  String get guideSection6Body =>
      '连接稳定时自动降为省电模式，充电或寻找新朋友时切换到快速模式。即使关闭应用，附近的朋友也能再次唤醒它。';

  @override
  String get guideDontShowAgain => '不再显示';

  @override
  String get guideStart => '开始使用';

  @override
  String get onboardingWelcome => '欢迎来到\nSpotLink';

  @override
  String get onboardingSubtitle => '取一个附近好友能看到的名字。\n无需网络，用蓝牙安全畅聊。';

  @override
  String get onboardingNameLabel => '显示名称';

  @override
  String get onboardingNameHint => '例如：小明';

  @override
  String get onboardingStart => '开始使用';

  @override
  String get bootStepNotifications => '准备通知';

  @override
  String get bootStepPermissions => '请求权限';

  @override
  String bootStepFailed(Object label, Object error) {
    return '$label 失败：$error';
  }

  @override
  String bootLaunchFailed(Object attempt, Object error) {
    return '启动失败（第 $attempt 次）：$error';
  }

  @override
  String bootRetrying(Object error) {
    return '$error\n将自动重试';
  }
}
