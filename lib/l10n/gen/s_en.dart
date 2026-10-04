// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 's.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class SEn extends S {
  SEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'SpotLink';

  @override
  String get commonCancel => 'Cancel';

  @override
  String get commonDelete => 'Delete';

  @override
  String get commonSave => 'Save';

  @override
  String get notifWakeNudgeTitle => 'SpotLink friends are nearby';

  @override
  String get notifWakeNudgeBody => 'Tap to open and connect right away.';

  @override
  String notifReaction(Object emoji) {
    return 'reacted with $emoji';
  }

  @override
  String get notifChannelName => 'Messages';

  @override
  String get notifChannelDesc => 'New message and file arrival alerts';

  @override
  String get errFileCopyFailed =>
      'Couldn\'t store the file, so it can\'t be sent';

  @override
  String get errFileGoneRetry =>
      'The original file is gone, so it can\'t be resent';

  @override
  String errGallerySave(Object error) {
    return 'Couldn\'t save to gallery: $error';
  }

  @override
  String get errServiceConnecting => 'Connecting to mesh service…';

  @override
  String get fgsTitle => 'SpotLink is active';

  @override
  String get fgsSearching => 'Searching for people nearby…';

  @override
  String fgsConnected(Object count) {
    return 'Connected to $count nearby device(s).';
  }

  @override
  String chatSendFailed(Object error) {
    return 'Send failed: $error';
  }

  @override
  String get chatAttachMedia => 'Photos & videos';

  @override
  String get chatAttachMediaSubtitle => 'Pick from gallery (multiple allowed)';

  @override
  String get chatAttachFile => 'File';

  @override
  String get chatAttachFileSubtitle =>
      'Any file — documents, archives, and more';

  @override
  String get chatAttachApk => 'Send the SpotLink app';

  @override
  String get chatAttachApkSubtitle =>
      'Share the installer (APK) — install without a store';

  @override
  String chatSkippedAttachments(Object count) {
    return '$count file(s) couldn\'t be attached. The originals may not be on this device (iCloud) — open them once in Photos and try again.';
  }

  @override
  String get chatApkExtractFailed => 'Couldn\'t extract the installer';

  @override
  String get chatPresenceNearby => 'Nearby';

  @override
  String chatPresenceNearbyHops(Object hops) {
    return 'Nearby · via $hops hop(s)';
  }

  @override
  String get chatPresenceOffline => 'Offline · will deliver later';

  @override
  String get chatNewMessage => 'New message';

  @override
  String get chatAttachTooltip => 'Attach a file';

  @override
  String get chatMessageHint => 'Message';

  @override
  String get chatSendTooltip => 'Send';

  @override
  String get chatUnverifiedNotice =>
      'This person isn\'t QR-verified yet.\nWhen you meet, scan each other\'s QR codes to confirm identity.';

  @override
  String get chatIdCopied => 'ID copied';

  @override
  String chatCopyId(Object id) {
    return 'Copy ID $id';
  }

  @override
  String get chatTapRetry => 'Tap to retry';

  @override
  String get chatReceiveInterrupted => 'Receiving was interrupted';

  @override
  String get chatUndelivered => 'Not delivered yet · tap to resend';

  @override
  String get chatQueuedHint => 'Delivers automatically when you meet';

  @override
  String chatTimeSentArrived(Object sent, Object arrived) {
    return 'sent $sent · arrived $arrived';
  }

  @override
  String get chatAllEmojis => 'All emojis';

  @override
  String get chatCopy => 'Copy';

  @override
  String get chatCopied => 'Copied';

  @override
  String get chatView => 'View';

  @override
  String get chatSaveToGallery => 'Save to gallery';

  @override
  String get chatSavedToGallery => 'Saved to gallery';

  @override
  String get chatSaveToGalleryFailed => 'Couldn\'t save to gallery';

  @override
  String get chatShareSaveToFiles => 'Share · save to Files';

  @override
  String get chatDeleteTitle => 'Delete message';

  @override
  String chatDeleteFileContent(Object fileName) {
    return '$fileName will be deleted from this device. It stays on the other person\'s device.';
  }

  @override
  String get chatDeleteTextContent =>
      'Delete this message from this device? It stays on the other person\'s device.';

  @override
  String get chatFileFallback => 'File';

  @override
  String get chatCancelSendTitle => 'Cancel transfer';

  @override
  String chatCancelSendContent(Object fileName) {
    return 'Cancel sending $fileName?';
  }

  @override
  String get chatKeepSending => 'Keep sending';

  @override
  String get chatCancelSend => 'Cancel transfer';

  @override
  String get chatStatusSending => 'Sending';

  @override
  String get chatStatusSent => 'Sent';

  @override
  String get chatStatusDelivered => 'Delivered';

  @override
  String get chatStatusFailed => 'Failed';

  @override
  String get chatStatusQueued => 'Queued';

  @override
  String get chatImageFallback => 'Image';

  @override
  String chatFileSizeTapOpen(Object size) {
    return '$size · tap to open';
  }

  @override
  String chatTransferSending(Object percent) {
    return 'Sending $percent%';
  }

  @override
  String chatTransferReceiving(Object percent) {
    return 'Receiving $percent%';
  }

  @override
  String get chatSentFile => 'Sent file';

  @override
  String get chatReceivedFile => 'Received file';

  @override
  String get chatLaneWifi => 'Wi-Fi Direct';

  @override
  String get chatLaneBle => 'Bluetooth';

  @override
  String get chatEncryptedTitle => 'This conversation is end-to-end encrypted';

  @override
  String get chatEncryptedSubtitle => 'Say hello 👋';

  @override
  String get chatShare => 'Share';

  @override
  String get meIdCopied => 'ID copied';

  @override
  String meIdLabel(Object id) {
    return 'ID $id';
  }

  @override
  String get meQrGuide =>
      'Friends who scan this code are added safely.\nYour keys never leave the device unencrypted.';

  @override
  String get meShareSubject => 'Add me on SpotLink';

  @override
  String get meShareInvite => 'Share invite code';

  @override
  String get meSettingsTitle => 'Settings';

  @override
  String get meBatterySaverTitle => 'Battery saver (always)';

  @override
  String get meBatterySaverSubtitle =>
      'Normally adjusts automatically to charging, battery, and connection state. Turning this on locks maximum power saving (discovery gets slower).';

  @override
  String get meRelayStoreTitle => 'Relay mailbox';

  @override
  String get meRelayStoreEmpty => 'No relayed messages are being held.';

  @override
  String meRelayStorePending(Object count, Object size) {
    return '$count message(s) waiting · $size\nDelivered and cleared automatically when the recipient is met.';
  }

  @override
  String get meRelayClear => 'Clear';

  @override
  String get meGuideTitle => 'How it works';

  @override
  String get meGuideSubtitle => 'Revisit the guide you saw on first launch.';

  @override
  String get meShareApkTitle => 'Share the app (offline distribution)';

  @override
  String get meShareApkSubtitle =>
      'Extract and share the installer (APK) — pass it via Quick Share, Bluetooth, and more, no store or internet needed.';

  @override
  String get meBeaconTitle => 'Wake up even after closing (beacon)';

  @override
  String get meBeaconSubtitle =>
      'When a nearby SpotLink beacon is detected, iOS wakes the app to receive messages even if it was closed. Requires the \"Always\" location permission.';

  @override
  String get meBeaconAlwaysTitle => 'To connect more reliably';

  @override
  String get meBeaconAlwaysSubtitle =>
      'Location permission is \"While Using\". Switching to \"Always\" lets the app reconnect automatically even after being fully closed or after a reboot. (Background connections still work now.)';

  @override
  String get meOpenSettings => 'Settings';

  @override
  String get meLiveReceiveTitle => 'About real-time receiving';

  @override
  String get meLiveReceiveSubtitle =>
      'Swiping the app away stops real-time receiving. Leave it in the background to keep receiving; missed messages arrive automatically when you meet again.';

  @override
  String get meShareApkFailed => 'Couldn\'t extract the installer';

  @override
  String get meShareApkSubject => 'SpotLink installer';

  @override
  String get meRelayClearTitle => 'Clear relay mailbox';

  @override
  String get meRelayClearBody =>
      'Deletes all messages waiting to be delivered to others.\nOnce deleted, they won\'t be delivered through this device (another relay device may still deliver them).';

  @override
  String get meEditNameTitle => 'Change name';

  @override
  String get meDisplayNameLabel => 'Display name';

  @override
  String get meBatteryExemptTitle => 'Always run in background';

  @override
  String get meBatteryChecking => 'Checking…';

  @override
  String get meBatteryExemptOn =>
      'Excluded from battery optimization. The mesh keeps running with the screen off.';

  @override
  String get meBatteryExemptOff =>
      'Battery optimization is on, so the system may stop receiving. Allow this to always receive.';

  @override
  String get meBatteryAllow => 'Allow';

  @override
  String get meVersionCopied => 'Version copied';

  @override
  String get meAvatarNudgeText =>
      'This avatar was randomly generated.\nMake it your own!';

  @override
  String get meAvatarNudgeCreate => 'Create';

  @override
  String get meAvatarNudgeLater => 'Later';

  @override
  String get avatarSaved => 'Saved — nearby friends now see you like this';

  @override
  String get avatarTitle => 'Create my avatar';

  @override
  String get avatarShuffleTooltip => 'Random mix';

  @override
  String get avatarHint =>
      'Combine parts to make your own avatar · roll with 🎲';

  @override
  String get avatarPartHairstyle => 'Hairstyle';

  @override
  String get avatarPartHairColor => 'Hair color';

  @override
  String get avatarPartFacialHair => 'Facial hair';

  @override
  String get avatarPartFacialHairColor => 'Facial hair color';

  @override
  String get avatarPartOutfit => 'Outfit';

  @override
  String get avatarPartOutfitColor => 'Outfit color';

  @override
  String get avatarPartEyes => 'Eyes';

  @override
  String get avatarPartEyebrows => 'Eyebrows';

  @override
  String get avatarPartMouth => 'Mouth';

  @override
  String get avatarPartSkin => 'Skin';

  @override
  String get avatarPartAccessories => 'Glasses & accessories';

  @override
  String get peopleSearchHint => 'Search by name';

  @override
  String get peopleSectionNearby => 'Nearby';

  @override
  String get peopleSectionVerified => 'Verified friends';

  @override
  String get peopleSectionChatted => 'Friends you\'ve chatted with';

  @override
  String peopleSectionHeader(Object label, Object count) {
    return '$label · $count';
  }

  @override
  String get peopleBoosting => 'Boost scanning';

  @override
  String get peopleScanning => 'Scanning';

  @override
  String peopleTileSubtitle(Object id, Object proximity) {
    return '$id · $proximity';
  }

  @override
  String get peopleStatusOffline => 'Offline';

  @override
  String peopleContactId(Object id) {
    return 'ID $id';
  }

  @override
  String get peopleActionChat => 'Chat';

  @override
  String get peopleActionRename => 'Rename';

  @override
  String peopleDeleteTitle(Object name) {
    return 'Delete $name';
  }

  @override
  String get peopleDeleteBody =>
      'The conversation and shared files will be deleted too.\n\nThis isn\'t a block — if they\'re nearby they may reappear as a new contact.';

  @override
  String get peopleDisplayNameLabel => 'Display name';

  @override
  String get peopleEmptyTitle => 'No one here yet';

  @override
  String get peopleEmptyBody =>
      'Nearby SpotLink users appear automatically.\nScan a friend\'s QR code to add and verify them safely.';

  @override
  String get peopleAddFriendQr => 'Add friend via QR';

  @override
  String get peopleBluetoothOff => 'Bluetooth is off or permission is missing.';

  @override
  String radarTitle(Object count) {
    return 'Nearby friends $count';
  }

  @override
  String radarTitleCapped(Object total, Object cap) {
    return '$total nearby · showing closest $cap';
  }

  @override
  String get radarResetZoom => 'Reset zoom';

  @override
  String get radarLegendVerified => 'Verified friend';

  @override
  String get radarLegendChatted => 'Chatted friend';

  @override
  String get radarLegendDiscovered => 'No badge: discovered nearby';

  @override
  String radarZoomHint(Object scale) {
    return '$scale× · double-tap to reset';
  }

  @override
  String get radarPanZoomHint =>
      'Closer to center = nearer · pinch to zoom, drag to pan';

  @override
  String radarOverflow(Object count) {
    return '+$count';
  }

  @override
  String get radarCardHint => 'The closer, the nearer to the center';

  @override
  String get chatsEmptyPreview => 'Start a conversation';

  @override
  String get chatsMePrefix => 'Me: ';

  @override
  String get chatsFileFallback => 'File';

  @override
  String get chatsEmptyTitle => 'No conversations yet';

  @override
  String get chatsEmptyBody => 'Chat with people nearby — no internet needed.';

  @override
  String get chatsFindPeople => 'See nearby people';

  @override
  String get chatsAddFriendQr => 'Add friend via QR';

  @override
  String scanAddedContact(Object name) {
    return 'Added $name ✓';
  }

  @override
  String scanAddFailed(Object error) {
    return 'Failed to add: $error';
  }

  @override
  String get scanTitle => 'Scan QR code';

  @override
  String get scanFlash => 'Flashlight';

  @override
  String get scanHint => 'Fit your friend\'s SpotLink QR code inside the frame';

  @override
  String get utilProximityVeryNear => 'Right here';

  @override
  String get utilProximityNear => 'Close by';

  @override
  String get utilProximityNearby => 'Nearby';

  @override
  String get utilProximityFar => 'Far';

  @override
  String get utilProximityUnknown => 'Around';

  @override
  String utilProximityRelayed(Object hops) {
    return '$hops hop(s) away';
  }

  @override
  String get utilJustNow => 'now';

  @override
  String utilMinutesAgo(Object minutes) {
    return '${minutes}m';
  }

  @override
  String get utilYesterday => 'Yesterday';

  @override
  String get utilToday => 'Today';

  @override
  String get homeTabChats => 'Chats';

  @override
  String get homeTabNearby => 'Nearby';

  @override
  String get homeTabMe => 'Me';

  @override
  String get homeStatusOff => 'Off';

  @override
  String homeStatusMesh(Object count) {
    return 'Mesh $count';
  }

  @override
  String get homeStatusScanning => 'Scanning';

  @override
  String homeSemanticsConnected(Object count) {
    return '$count device(s) connected';
  }

  @override
  String get homeSemanticsScanning => 'Scanning nearby';

  @override
  String get homeSemanticsNoConnection => 'No connection';

  @override
  String get homeSheetTitle => 'Mesh status';

  @override
  String get homeStatConnected => 'Connected devices';

  @override
  String get homeStatNearby => 'Nearby friends';

  @override
  String get homeStatRelayQueue => 'Relay queue';

  @override
  String get homeBatterySaver => 'Battery saver';

  @override
  String get homeBtPoweredOff =>
      'Bluetooth is off. Turn it on and nearby discovery starts automatically.';

  @override
  String get homeBtUnauthorized =>
      'Bluetooth permission is missing. Allow Bluetooth in Settings > SpotLink.';

  @override
  String get homeBtUnauthorizedDesktop =>
      'Bluetooth permission is missing. Allow SpotLink in System Settings > Privacy & Security > Bluetooth.';

  @override
  String get homeBtUnavailable =>
      'Bluetooth is off or unauthorized, so nearby friends can\'t be found.';

  @override
  String get homeOpenSettings => 'Open Settings';

  @override
  String get guideTitle => 'How SpotLink works';

  @override
  String get guideSection1Title => 'No internet needed';

  @override
  String get guideSection1Body =>
      'SpotLink connects directly to nearby devices over Bluetooth. Chat with friends close by even where networks are down, abroad, or in a disaster.';

  @override
  String get guideSection2Title => 'Friends, safely via QR';

  @override
  String get guideSection2Body =>
      'Scan a friend\'s code with the QR button on the Nearby tab to exchange encryption keys and become verified friends. People discovered nearby also appear automatically.';

  @override
  String get guideSection3Title => 'Reach farther through friends';

  @override
  String get guideSection3Body =>
      'Even beyond direct range, messages relay through other SpotLink devices in between. The radar on the Nearby tab shows who is how many hops away.';

  @override
  String get guideSection4Title => 'If not now, then when you meet';

  @override
  String get guideSection4Body =>
      'If someone is out of range, messages are held and delivered automatically the moment you meet again. Late arrivals show both the sent and arrival times.';

  @override
  String get guideSection5Title => 'Only the two of you can read it';

  @override
  String get guideSection5Body =>
      'Every message is end-to-end encrypted. Even relaying devices in the middle can\'t read the contents.';

  @override
  String get guideSection6Title => 'Battery is managed for you';

  @override
  String get guideSection6Body =>
      'When connections are stable it drops into power saving automatically, and speeds up while charging or looking for new friends. Even if the app closes, a nearby friend can wake it again.';

  @override
  String get guideDontShowAgain => 'Don\'t show again';

  @override
  String get guideStart => 'Get started';

  @override
  String get onboardingWelcome => 'Welcome to\nSpotLink';

  @override
  String get onboardingSubtitle =>
      'Choose the name nearby friends will see.\nChat safely over Bluetooth, no internet needed.';

  @override
  String get onboardingNameLabel => 'Display name';

  @override
  String get onboardingNameHint => 'e.g. Alex';

  @override
  String get onboardingStart => 'Get started';

  @override
  String get bootStepNotifications => 'Preparing notifications';

  @override
  String get bootStepPermissions => 'Requesting permissions';

  @override
  String bootStepFailed(Object label, Object error) {
    return '$label failed: $error';
  }

  @override
  String bootLaunchFailed(Object attempt, Object error) {
    return 'Launch failed (attempt $attempt): $error';
  }

  @override
  String bootRetrying(Object error) {
    return '$error\nRetrying automatically';
  }

  @override
  String get encTitle => 'Passed by';

  @override
  String get encEntryTitle => 'Passed by';

  @override
  String get encEntryEmpty => 'Friends who pass nearby show up here';

  @override
  String encEntryRecent(Object name, Object when) {
    return 'Latest: $name · $when';
  }

  @override
  String get encEmptyTitle => 'No one has passed by yet';

  @override
  String get encEmptyBody =>
      'When a SpotLink friend passes nearby, we keep when, who, and where on this device — even if you weren\'t looking at the app.';

  @override
  String get encUnknownPeer => 'Unidentified SpotLink user';

  @override
  String get encUnknownHint => 'Came close but left before connecting';

  @override
  String get encMissed => 'Missed';

  @override
  String get encAutoSent => 'Auto-message sent';

  @override
  String get encDirect => 'Direct';

  @override
  String encViaHops(Object hops) {
    return 'via $hops hops';
  }

  @override
  String get encBriefly => 'Briefly';

  @override
  String encForMinutes(Object minutes) {
    return 'for $minutes min';
  }

  @override
  String get encNoLocation => 'No location';

  @override
  String get encLocationToggle => 'Record location';

  @override
  String get encLocationNote =>
      'Kept only on this device. Place names are looked up by sending coordinates to your device\'s map service';

  @override
  String get encLocationNoteForeground =>
      'Kept only on this device, and recorded only while the app is open here. Place names are looked up via your device\'s map service';

  @override
  String get encClear => 'Clear history';

  @override
  String get encClearTitle => 'Clear all passed-by history?';

  @override
  String get encClearBody =>
      'Times and locations will be deleted from this device. This can\'t be undone.';

  @override
  String get encCleared => 'History cleared';

  @override
  String get autoMsgTitle => 'Auto-message when passing by';

  @override
  String get autoMsgOff => 'Off';

  @override
  String get autoMsgHint => 'e.g. You were nearby! Coffee next time?';

  @override
  String autoMsgHelp(Object hours) {
    return 'Sent automatically when you connect with this friend — at most once every $hours hours.';
  }

  @override
  String get autoMsgTurnOff => 'Turn off';

  @override
  String get autoMsgSaved => 'Auto-message set';

  @override
  String get autoMsgCleared => 'Auto-message turned off';
}
