import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 's_de.dart';
import 's_en.dart';
import 's_es.dart';
import 's_fr.dart';
import 's_ja.dart';
import 's_ko.dart';
import 's_pt.dart';
import 's_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of S
/// returned by `S.of(context)`.
///
/// Applications need to include `S.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'gen/s.dart';
///
/// return MaterialApp(
///   localizationsDelegates: S.localizationsDelegates,
///   supportedLocales: S.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the S.supportedLocales
/// property.
abstract class S {
  S(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static S of(BuildContext context) {
    return Localizations.of<S>(context, S)!;
  }

  static const LocalizationsDelegate<S> delegate = _SDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('de'),
    Locale('en'),
    Locale('es'),
    Locale('fr'),
    Locale('ja'),
    Locale('ko'),
    Locale('pt'),
    Locale('zh'),
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'SpotLink'**
  String get appTitle;

  /// No description provided for @commonCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get commonCancel;

  /// No description provided for @commonDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get commonDelete;

  /// No description provided for @commonSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get commonSave;

  /// No description provided for @notifWakeNudgeTitle.
  ///
  /// In en, this message translates to:
  /// **'SpotLink friends are nearby'**
  String get notifWakeNudgeTitle;

  /// No description provided for @notifWakeNudgeBody.
  ///
  /// In en, this message translates to:
  /// **'Tap to open and connect right away.'**
  String get notifWakeNudgeBody;

  /// No description provided for @notifReaction.
  ///
  /// In en, this message translates to:
  /// **'reacted with {emoji}'**
  String notifReaction(Object emoji);

  /// No description provided for @notifChannelName.
  ///
  /// In en, this message translates to:
  /// **'Messages'**
  String get notifChannelName;

  /// No description provided for @notifChannelDesc.
  ///
  /// In en, this message translates to:
  /// **'New message and file arrival alerts'**
  String get notifChannelDesc;

  /// No description provided for @errFileCopyFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t store the file, so it can\'t be sent'**
  String get errFileCopyFailed;

  /// No description provided for @errFileGoneRetry.
  ///
  /// In en, this message translates to:
  /// **'The original file is gone, so it can\'t be resent'**
  String get errFileGoneRetry;

  /// No description provided for @errGallerySave.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t save to gallery: {error}'**
  String errGallerySave(Object error);

  /// No description provided for @errServiceConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting to mesh service…'**
  String get errServiceConnecting;

  /// No description provided for @fgsTitle.
  ///
  /// In en, this message translates to:
  /// **'SpotLink is active'**
  String get fgsTitle;

  /// No description provided for @fgsSearching.
  ///
  /// In en, this message translates to:
  /// **'Searching for people nearby…'**
  String get fgsSearching;

  /// No description provided for @fgsConnected.
  ///
  /// In en, this message translates to:
  /// **'Connected to {count} nearby device(s).'**
  String fgsConnected(Object count);

  /// No description provided for @chatSendFailed.
  ///
  /// In en, this message translates to:
  /// **'Send failed: {error}'**
  String chatSendFailed(Object error);

  /// No description provided for @chatAttachMedia.
  ///
  /// In en, this message translates to:
  /// **'Photos & videos'**
  String get chatAttachMedia;

  /// No description provided for @chatAttachMediaSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Pick from gallery (multiple allowed)'**
  String get chatAttachMediaSubtitle;

  /// No description provided for @chatAttachFile.
  ///
  /// In en, this message translates to:
  /// **'File'**
  String get chatAttachFile;

  /// No description provided for @chatAttachFileSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Any file — documents, archives, and more'**
  String get chatAttachFileSubtitle;

  /// No description provided for @chatAttachApk.
  ///
  /// In en, this message translates to:
  /// **'Send the SpotLink app'**
  String get chatAttachApk;

  /// No description provided for @chatAttachApkSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Share the installer (APK) — install without a store'**
  String get chatAttachApkSubtitle;

  /// No description provided for @chatSkippedAttachments.
  ///
  /// In en, this message translates to:
  /// **'{count} file(s) couldn\'t be attached. The originals may not be on this device (iCloud) — open them once in Photos and try again.'**
  String chatSkippedAttachments(Object count);

  /// No description provided for @chatApkExtractFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t extract the installer'**
  String get chatApkExtractFailed;

  /// No description provided for @chatPresenceNearby.
  ///
  /// In en, this message translates to:
  /// **'Nearby'**
  String get chatPresenceNearby;

  /// No description provided for @chatPresenceNearbyHops.
  ///
  /// In en, this message translates to:
  /// **'Nearby · via {hops} hop(s)'**
  String chatPresenceNearbyHops(Object hops);

  /// No description provided for @chatPresenceOffline.
  ///
  /// In en, this message translates to:
  /// **'Offline · will deliver later'**
  String get chatPresenceOffline;

  /// No description provided for @chatNewMessage.
  ///
  /// In en, this message translates to:
  /// **'New message'**
  String get chatNewMessage;

  /// No description provided for @chatAttachTooltip.
  ///
  /// In en, this message translates to:
  /// **'Attach a file'**
  String get chatAttachTooltip;

  /// No description provided for @chatMessageHint.
  ///
  /// In en, this message translates to:
  /// **'Message'**
  String get chatMessageHint;

  /// No description provided for @chatSendTooltip.
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get chatSendTooltip;

  /// No description provided for @chatUnverifiedNotice.
  ///
  /// In en, this message translates to:
  /// **'This person isn\'t QR-verified yet.\nWhen you meet, scan each other\'s QR codes to confirm identity.'**
  String get chatUnverifiedNotice;

  /// No description provided for @chatIdCopied.
  ///
  /// In en, this message translates to:
  /// **'ID copied'**
  String get chatIdCopied;

  /// No description provided for @chatCopyId.
  ///
  /// In en, this message translates to:
  /// **'Copy ID {id}'**
  String chatCopyId(Object id);

  /// No description provided for @chatTapRetry.
  ///
  /// In en, this message translates to:
  /// **'Tap to retry'**
  String get chatTapRetry;

  /// No description provided for @chatReceiveInterrupted.
  ///
  /// In en, this message translates to:
  /// **'Receiving was interrupted'**
  String get chatReceiveInterrupted;

  /// No description provided for @chatUndelivered.
  ///
  /// In en, this message translates to:
  /// **'Not delivered yet · tap to resend'**
  String get chatUndelivered;

  /// No description provided for @chatQueuedHint.
  ///
  /// In en, this message translates to:
  /// **'Delivers automatically when you meet'**
  String get chatQueuedHint;

  /// No description provided for @chatTimeSentArrived.
  ///
  /// In en, this message translates to:
  /// **'sent {sent} · arrived {arrived}'**
  String chatTimeSentArrived(Object sent, Object arrived);

  /// No description provided for @chatAllEmojis.
  ///
  /// In en, this message translates to:
  /// **'All emojis'**
  String get chatAllEmojis;

  /// No description provided for @chatCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get chatCopy;

  /// No description provided for @chatCopied.
  ///
  /// In en, this message translates to:
  /// **'Copied'**
  String get chatCopied;

  /// No description provided for @chatView.
  ///
  /// In en, this message translates to:
  /// **'View'**
  String get chatView;

  /// No description provided for @chatSaveToGallery.
  ///
  /// In en, this message translates to:
  /// **'Save to gallery'**
  String get chatSaveToGallery;

  /// No description provided for @chatSavedToGallery.
  ///
  /// In en, this message translates to:
  /// **'Saved to gallery'**
  String get chatSavedToGallery;

  /// No description provided for @chatSaveToGalleryFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t save to gallery'**
  String get chatSaveToGalleryFailed;

  /// No description provided for @chatShareSaveToFiles.
  ///
  /// In en, this message translates to:
  /// **'Share · save to Files'**
  String get chatShareSaveToFiles;

  /// No description provided for @chatDeleteTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete message'**
  String get chatDeleteTitle;

  /// No description provided for @chatDeleteFileContent.
  ///
  /// In en, this message translates to:
  /// **'{fileName} will be deleted from this device. It stays on the other person\'s device.'**
  String chatDeleteFileContent(Object fileName);

  /// No description provided for @chatDeleteTextContent.
  ///
  /// In en, this message translates to:
  /// **'Delete this message from this device? It stays on the other person\'s device.'**
  String get chatDeleteTextContent;

  /// No description provided for @chatFileFallback.
  ///
  /// In en, this message translates to:
  /// **'File'**
  String get chatFileFallback;

  /// No description provided for @chatCancelSendTitle.
  ///
  /// In en, this message translates to:
  /// **'Cancel transfer'**
  String get chatCancelSendTitle;

  /// No description provided for @chatCancelSendContent.
  ///
  /// In en, this message translates to:
  /// **'Cancel sending {fileName}?'**
  String chatCancelSendContent(Object fileName);

  /// No description provided for @chatKeepSending.
  ///
  /// In en, this message translates to:
  /// **'Keep sending'**
  String get chatKeepSending;

  /// No description provided for @chatCancelSend.
  ///
  /// In en, this message translates to:
  /// **'Cancel transfer'**
  String get chatCancelSend;

  /// No description provided for @chatStatusSending.
  ///
  /// In en, this message translates to:
  /// **'Sending'**
  String get chatStatusSending;

  /// No description provided for @chatStatusSent.
  ///
  /// In en, this message translates to:
  /// **'Sent'**
  String get chatStatusSent;

  /// No description provided for @chatStatusDelivered.
  ///
  /// In en, this message translates to:
  /// **'Delivered'**
  String get chatStatusDelivered;

  /// No description provided for @chatStatusFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed'**
  String get chatStatusFailed;

  /// No description provided for @chatStatusQueued.
  ///
  /// In en, this message translates to:
  /// **'Queued'**
  String get chatStatusQueued;

  /// No description provided for @chatImageFallback.
  ///
  /// In en, this message translates to:
  /// **'Image'**
  String get chatImageFallback;

  /// No description provided for @chatFileSizeTapOpen.
  ///
  /// In en, this message translates to:
  /// **'{size} · tap to open'**
  String chatFileSizeTapOpen(Object size);

  /// No description provided for @chatTransferSending.
  ///
  /// In en, this message translates to:
  /// **'Sending {percent}%'**
  String chatTransferSending(Object percent);

  /// No description provided for @chatTransferReceiving.
  ///
  /// In en, this message translates to:
  /// **'Receiving {percent}%'**
  String chatTransferReceiving(Object percent);

  /// No description provided for @chatSentFile.
  ///
  /// In en, this message translates to:
  /// **'Sent file'**
  String get chatSentFile;

  /// No description provided for @chatReceivedFile.
  ///
  /// In en, this message translates to:
  /// **'Received file'**
  String get chatReceivedFile;

  /// No description provided for @chatLaneWifi.
  ///
  /// In en, this message translates to:
  /// **'Wi-Fi Direct'**
  String get chatLaneWifi;

  /// No description provided for @chatLaneBle.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth'**
  String get chatLaneBle;

  /// No description provided for @chatEncryptedTitle.
  ///
  /// In en, this message translates to:
  /// **'This conversation is end-to-end encrypted'**
  String get chatEncryptedTitle;

  /// No description provided for @chatEncryptedSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Say hello 👋'**
  String get chatEncryptedSubtitle;

  /// No description provided for @chatShare.
  ///
  /// In en, this message translates to:
  /// **'Share'**
  String get chatShare;

  /// No description provided for @meIdCopied.
  ///
  /// In en, this message translates to:
  /// **'ID copied'**
  String get meIdCopied;

  /// No description provided for @meIdLabel.
  ///
  /// In en, this message translates to:
  /// **'ID {id}'**
  String meIdLabel(Object id);

  /// No description provided for @meQrGuide.
  ///
  /// In en, this message translates to:
  /// **'Friends who scan this code are added safely.\nYour keys never leave the device unencrypted.'**
  String get meQrGuide;

  /// No description provided for @meShareSubject.
  ///
  /// In en, this message translates to:
  /// **'Add me on SpotLink'**
  String get meShareSubject;

  /// No description provided for @meShareInvite.
  ///
  /// In en, this message translates to:
  /// **'Share invite code'**
  String get meShareInvite;

  /// No description provided for @meSettingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get meSettingsTitle;

  /// No description provided for @meBatterySaverTitle.
  ///
  /// In en, this message translates to:
  /// **'Battery saver (always)'**
  String get meBatterySaverTitle;

  /// No description provided for @meBatterySaverSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Normally adjusts automatically to charging, battery, and connection state. Turning this on locks maximum power saving (discovery gets slower).'**
  String get meBatterySaverSubtitle;

  /// No description provided for @meRelayStoreTitle.
  ///
  /// In en, this message translates to:
  /// **'Relay mailbox'**
  String get meRelayStoreTitle;

  /// No description provided for @meRelayStoreEmpty.
  ///
  /// In en, this message translates to:
  /// **'No relayed messages are being held.'**
  String get meRelayStoreEmpty;

  /// No description provided for @meRelayStorePending.
  ///
  /// In en, this message translates to:
  /// **'{count} message(s) waiting · {size}\nDelivered and cleared automatically when the recipient is met.'**
  String meRelayStorePending(Object count, Object size);

  /// No description provided for @meRelayClear.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get meRelayClear;

  /// No description provided for @meGuideTitle.
  ///
  /// In en, this message translates to:
  /// **'How it works'**
  String get meGuideTitle;

  /// No description provided for @meGuideSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Revisit the guide you saw on first launch.'**
  String get meGuideSubtitle;

  /// No description provided for @meShareApkTitle.
  ///
  /// In en, this message translates to:
  /// **'Share the app (offline distribution)'**
  String get meShareApkTitle;

  /// No description provided for @meShareApkSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Extract and share the installer (APK) — pass it via Quick Share, Bluetooth, and more, no store or internet needed.'**
  String get meShareApkSubtitle;

  /// No description provided for @meBeaconTitle.
  ///
  /// In en, this message translates to:
  /// **'Wake up even after closing (beacon)'**
  String get meBeaconTitle;

  /// No description provided for @meBeaconSubtitle.
  ///
  /// In en, this message translates to:
  /// **'When a nearby SpotLink beacon is detected, iOS wakes the app to receive messages even if it was closed. Requires the \"Always\" location permission.'**
  String get meBeaconSubtitle;

  /// No description provided for @meBeaconAlwaysTitle.
  ///
  /// In en, this message translates to:
  /// **'To connect more reliably'**
  String get meBeaconAlwaysTitle;

  /// No description provided for @meBeaconAlwaysSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Location permission is \"While Using\". Switching to \"Always\" lets the app reconnect automatically even after being fully closed or after a reboot. (Background connections still work now.)'**
  String get meBeaconAlwaysSubtitle;

  /// No description provided for @meOpenSettings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get meOpenSettings;

  /// No description provided for @meLiveReceiveTitle.
  ///
  /// In en, this message translates to:
  /// **'About real-time receiving'**
  String get meLiveReceiveTitle;

  /// No description provided for @meLiveReceiveSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Swiping the app away stops real-time receiving. Leave it in the background to keep receiving; missed messages arrive automatically when you meet again.'**
  String get meLiveReceiveSubtitle;

  /// No description provided for @meShareApkFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t extract the installer'**
  String get meShareApkFailed;

  /// No description provided for @meShareApkSubject.
  ///
  /// In en, this message translates to:
  /// **'SpotLink installer'**
  String get meShareApkSubject;

  /// No description provided for @meRelayClearTitle.
  ///
  /// In en, this message translates to:
  /// **'Clear relay mailbox'**
  String get meRelayClearTitle;

  /// No description provided for @meRelayClearBody.
  ///
  /// In en, this message translates to:
  /// **'Deletes all messages waiting to be delivered to others.\nOnce deleted, they won\'t be delivered through this device (another relay device may still deliver them).'**
  String get meRelayClearBody;

  /// No description provided for @meEditNameTitle.
  ///
  /// In en, this message translates to:
  /// **'Change name'**
  String get meEditNameTitle;

  /// No description provided for @meDisplayNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Display name'**
  String get meDisplayNameLabel;

  /// No description provided for @meBatteryExemptTitle.
  ///
  /// In en, this message translates to:
  /// **'Always run in background'**
  String get meBatteryExemptTitle;

  /// No description provided for @meBatteryChecking.
  ///
  /// In en, this message translates to:
  /// **'Checking…'**
  String get meBatteryChecking;

  /// No description provided for @meBatteryExemptOn.
  ///
  /// In en, this message translates to:
  /// **'Excluded from battery optimization. The mesh keeps running with the screen off.'**
  String get meBatteryExemptOn;

  /// No description provided for @meBatteryExemptOff.
  ///
  /// In en, this message translates to:
  /// **'Battery optimization is on, so the system may stop receiving. Allow this to always receive.'**
  String get meBatteryExemptOff;

  /// No description provided for @meBatteryAllow.
  ///
  /// In en, this message translates to:
  /// **'Allow'**
  String get meBatteryAllow;

  /// No description provided for @meVersionCopied.
  ///
  /// In en, this message translates to:
  /// **'Version copied'**
  String get meVersionCopied;

  /// No description provided for @meAvatarNudgeText.
  ///
  /// In en, this message translates to:
  /// **'This avatar was randomly generated.\nMake it your own!'**
  String get meAvatarNudgeText;

  /// No description provided for @meAvatarNudgeCreate.
  ///
  /// In en, this message translates to:
  /// **'Create'**
  String get meAvatarNudgeCreate;

  /// No description provided for @meAvatarNudgeLater.
  ///
  /// In en, this message translates to:
  /// **'Later'**
  String get meAvatarNudgeLater;

  /// No description provided for @avatarSaved.
  ///
  /// In en, this message translates to:
  /// **'Saved — nearby friends now see you like this'**
  String get avatarSaved;

  /// No description provided for @avatarTitle.
  ///
  /// In en, this message translates to:
  /// **'Create my avatar'**
  String get avatarTitle;

  /// No description provided for @avatarShuffleTooltip.
  ///
  /// In en, this message translates to:
  /// **'Random mix'**
  String get avatarShuffleTooltip;

  /// No description provided for @avatarHint.
  ///
  /// In en, this message translates to:
  /// **'Combine parts to make your own avatar · roll with 🎲'**
  String get avatarHint;

  /// No description provided for @avatarPartHairstyle.
  ///
  /// In en, this message translates to:
  /// **'Hairstyle'**
  String get avatarPartHairstyle;

  /// No description provided for @avatarPartHairColor.
  ///
  /// In en, this message translates to:
  /// **'Hair color'**
  String get avatarPartHairColor;

  /// No description provided for @avatarPartFacialHair.
  ///
  /// In en, this message translates to:
  /// **'Facial hair'**
  String get avatarPartFacialHair;

  /// No description provided for @avatarPartFacialHairColor.
  ///
  /// In en, this message translates to:
  /// **'Facial hair color'**
  String get avatarPartFacialHairColor;

  /// No description provided for @avatarPartOutfit.
  ///
  /// In en, this message translates to:
  /// **'Outfit'**
  String get avatarPartOutfit;

  /// No description provided for @avatarPartOutfitColor.
  ///
  /// In en, this message translates to:
  /// **'Outfit color'**
  String get avatarPartOutfitColor;

  /// No description provided for @avatarPartEyes.
  ///
  /// In en, this message translates to:
  /// **'Eyes'**
  String get avatarPartEyes;

  /// No description provided for @avatarPartEyebrows.
  ///
  /// In en, this message translates to:
  /// **'Eyebrows'**
  String get avatarPartEyebrows;

  /// No description provided for @avatarPartMouth.
  ///
  /// In en, this message translates to:
  /// **'Mouth'**
  String get avatarPartMouth;

  /// No description provided for @avatarPartSkin.
  ///
  /// In en, this message translates to:
  /// **'Skin'**
  String get avatarPartSkin;

  /// No description provided for @avatarPartAccessories.
  ///
  /// In en, this message translates to:
  /// **'Glasses & accessories'**
  String get avatarPartAccessories;

  /// No description provided for @peopleSearchHint.
  ///
  /// In en, this message translates to:
  /// **'Search by name'**
  String get peopleSearchHint;

  /// No description provided for @peopleSectionNearby.
  ///
  /// In en, this message translates to:
  /// **'Nearby'**
  String get peopleSectionNearby;

  /// No description provided for @peopleSectionVerified.
  ///
  /// In en, this message translates to:
  /// **'Verified friends'**
  String get peopleSectionVerified;

  /// No description provided for @peopleSectionChatted.
  ///
  /// In en, this message translates to:
  /// **'Friends you\'ve chatted with'**
  String get peopleSectionChatted;

  /// No description provided for @peopleSectionHeader.
  ///
  /// In en, this message translates to:
  /// **'{label} · {count}'**
  String peopleSectionHeader(Object label, Object count);

  /// No description provided for @peopleBoosting.
  ///
  /// In en, this message translates to:
  /// **'Boost scanning'**
  String get peopleBoosting;

  /// No description provided for @peopleScanning.
  ///
  /// In en, this message translates to:
  /// **'Scanning'**
  String get peopleScanning;

  /// No description provided for @peopleTileSubtitle.
  ///
  /// In en, this message translates to:
  /// **'{id} · {proximity}'**
  String peopleTileSubtitle(Object id, Object proximity);

  /// No description provided for @peopleStatusOffline.
  ///
  /// In en, this message translates to:
  /// **'Offline'**
  String get peopleStatusOffline;

  /// No description provided for @peopleContactId.
  ///
  /// In en, this message translates to:
  /// **'ID {id}'**
  String peopleContactId(Object id);

  /// No description provided for @peopleActionChat.
  ///
  /// In en, this message translates to:
  /// **'Chat'**
  String get peopleActionChat;

  /// No description provided for @peopleActionRename.
  ///
  /// In en, this message translates to:
  /// **'Rename'**
  String get peopleActionRename;

  /// No description provided for @peopleDeleteTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete {name}'**
  String peopleDeleteTitle(Object name);

  /// No description provided for @peopleDeleteBody.
  ///
  /// In en, this message translates to:
  /// **'The conversation and shared files will be deleted too.\n\nThis isn\'t a block — if they\'re nearby they may reappear as a new contact.'**
  String get peopleDeleteBody;

  /// No description provided for @peopleDisplayNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Display name'**
  String get peopleDisplayNameLabel;

  /// No description provided for @peopleEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No one here yet'**
  String get peopleEmptyTitle;

  /// No description provided for @peopleEmptyBody.
  ///
  /// In en, this message translates to:
  /// **'Nearby SpotLink users appear automatically.\nScan a friend\'s QR code to add and verify them safely.'**
  String get peopleEmptyBody;

  /// No description provided for @peopleAddFriendQr.
  ///
  /// In en, this message translates to:
  /// **'Add friend via QR'**
  String get peopleAddFriendQr;

  /// No description provided for @peopleBluetoothOff.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth is off or permission is missing.'**
  String get peopleBluetoothOff;

  /// No description provided for @radarTitle.
  ///
  /// In en, this message translates to:
  /// **'Nearby friends {count}'**
  String radarTitle(Object count);

  /// No description provided for @radarTitleCapped.
  ///
  /// In en, this message translates to:
  /// **'{total} nearby · showing closest {cap}'**
  String radarTitleCapped(Object total, Object cap);

  /// No description provided for @radarResetZoom.
  ///
  /// In en, this message translates to:
  /// **'Reset zoom'**
  String get radarResetZoom;

  /// No description provided for @radarLegendVerified.
  ///
  /// In en, this message translates to:
  /// **'Verified friend'**
  String get radarLegendVerified;

  /// No description provided for @radarLegendChatted.
  ///
  /// In en, this message translates to:
  /// **'Chatted friend'**
  String get radarLegendChatted;

  /// No description provided for @radarLegendDiscovered.
  ///
  /// In en, this message translates to:
  /// **'No badge: discovered nearby'**
  String get radarLegendDiscovered;

  /// No description provided for @radarZoomHint.
  ///
  /// In en, this message translates to:
  /// **'{scale}× · double-tap to reset'**
  String radarZoomHint(Object scale);

  /// No description provided for @radarPanZoomHint.
  ///
  /// In en, this message translates to:
  /// **'Closer to center = nearer · pinch to zoom, drag to pan'**
  String get radarPanZoomHint;

  /// No description provided for @radarOverflow.
  ///
  /// In en, this message translates to:
  /// **'+{count}'**
  String radarOverflow(Object count);

  /// No description provided for @radarCardHint.
  ///
  /// In en, this message translates to:
  /// **'The closer, the nearer to the center'**
  String get radarCardHint;

  /// No description provided for @chatsEmptyPreview.
  ///
  /// In en, this message translates to:
  /// **'Start a conversation'**
  String get chatsEmptyPreview;

  /// No description provided for @chatsMePrefix.
  ///
  /// In en, this message translates to:
  /// **'Me: '**
  String get chatsMePrefix;

  /// No description provided for @chatsFileFallback.
  ///
  /// In en, this message translates to:
  /// **'File'**
  String get chatsFileFallback;

  /// No description provided for @chatsEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No conversations yet'**
  String get chatsEmptyTitle;

  /// No description provided for @chatsEmptyBody.
  ///
  /// In en, this message translates to:
  /// **'Chat with people nearby — no internet needed.'**
  String get chatsEmptyBody;

  /// No description provided for @chatsFindPeople.
  ///
  /// In en, this message translates to:
  /// **'See nearby people'**
  String get chatsFindPeople;

  /// No description provided for @chatsAddFriendQr.
  ///
  /// In en, this message translates to:
  /// **'Add friend via QR'**
  String get chatsAddFriendQr;

  /// No description provided for @scanAddedContact.
  ///
  /// In en, this message translates to:
  /// **'Added {name} ✓'**
  String scanAddedContact(Object name);

  /// No description provided for @scanAddFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to add: {error}'**
  String scanAddFailed(Object error);

  /// No description provided for @scanTitle.
  ///
  /// In en, this message translates to:
  /// **'Scan QR code'**
  String get scanTitle;

  /// No description provided for @scanFlash.
  ///
  /// In en, this message translates to:
  /// **'Flashlight'**
  String get scanFlash;

  /// No description provided for @scanHint.
  ///
  /// In en, this message translates to:
  /// **'Fit your friend\'s SpotLink QR code inside the frame'**
  String get scanHint;

  /// No description provided for @utilProximityVeryNear.
  ///
  /// In en, this message translates to:
  /// **'Right here'**
  String get utilProximityVeryNear;

  /// No description provided for @utilProximityNear.
  ///
  /// In en, this message translates to:
  /// **'Close by'**
  String get utilProximityNear;

  /// No description provided for @utilProximityNearby.
  ///
  /// In en, this message translates to:
  /// **'Nearby'**
  String get utilProximityNearby;

  /// No description provided for @utilProximityFar.
  ///
  /// In en, this message translates to:
  /// **'Far'**
  String get utilProximityFar;

  /// No description provided for @utilProximityUnknown.
  ///
  /// In en, this message translates to:
  /// **'Around'**
  String get utilProximityUnknown;

  /// No description provided for @utilProximityRelayed.
  ///
  /// In en, this message translates to:
  /// **'{hops} hop(s) away'**
  String utilProximityRelayed(Object hops);

  /// No description provided for @utilJustNow.
  ///
  /// In en, this message translates to:
  /// **'now'**
  String get utilJustNow;

  /// No description provided for @utilMinutesAgo.
  ///
  /// In en, this message translates to:
  /// **'{minutes}m'**
  String utilMinutesAgo(Object minutes);

  /// No description provided for @utilYesterday.
  ///
  /// In en, this message translates to:
  /// **'Yesterday'**
  String get utilYesterday;

  /// No description provided for @utilToday.
  ///
  /// In en, this message translates to:
  /// **'Today'**
  String get utilToday;

  /// No description provided for @homeTabChats.
  ///
  /// In en, this message translates to:
  /// **'Chats'**
  String get homeTabChats;

  /// No description provided for @homeTabNearby.
  ///
  /// In en, this message translates to:
  /// **'Nearby'**
  String get homeTabNearby;

  /// No description provided for @homeTabMe.
  ///
  /// In en, this message translates to:
  /// **'Me'**
  String get homeTabMe;

  /// No description provided for @homeStatusOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get homeStatusOff;

  /// No description provided for @homeStatusMesh.
  ///
  /// In en, this message translates to:
  /// **'Mesh {count}'**
  String homeStatusMesh(Object count);

  /// No description provided for @homeStatusScanning.
  ///
  /// In en, this message translates to:
  /// **'Scanning'**
  String get homeStatusScanning;

  /// No description provided for @homeSemanticsConnected.
  ///
  /// In en, this message translates to:
  /// **'{count} device(s) connected'**
  String homeSemanticsConnected(Object count);

  /// No description provided for @homeSemanticsScanning.
  ///
  /// In en, this message translates to:
  /// **'Scanning nearby'**
  String get homeSemanticsScanning;

  /// No description provided for @homeSemanticsNoConnection.
  ///
  /// In en, this message translates to:
  /// **'No connection'**
  String get homeSemanticsNoConnection;

  /// No description provided for @homeSheetTitle.
  ///
  /// In en, this message translates to:
  /// **'Mesh status'**
  String get homeSheetTitle;

  /// No description provided for @homeStatConnected.
  ///
  /// In en, this message translates to:
  /// **'Connected devices'**
  String get homeStatConnected;

  /// No description provided for @homeStatNearby.
  ///
  /// In en, this message translates to:
  /// **'Nearby friends'**
  String get homeStatNearby;

  /// No description provided for @homeStatRelayQueue.
  ///
  /// In en, this message translates to:
  /// **'Relay queue'**
  String get homeStatRelayQueue;

  /// No description provided for @homeBatterySaver.
  ///
  /// In en, this message translates to:
  /// **'Battery saver'**
  String get homeBatterySaver;

  /// No description provided for @homeBtPoweredOff.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth is off. Turn it on and nearby discovery starts automatically.'**
  String get homeBtPoweredOff;

  /// No description provided for @homeBtUnauthorized.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth permission is missing. Allow Bluetooth in Settings > SpotLink.'**
  String get homeBtUnauthorized;

  /// No description provided for @homeBtUnauthorizedDesktop.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth permission is missing. Allow SpotLink in System Settings > Privacy & Security > Bluetooth.'**
  String get homeBtUnauthorizedDesktop;

  /// No description provided for @homeBtUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth is off or unauthorized, so nearby friends can\'t be found.'**
  String get homeBtUnavailable;

  /// No description provided for @homeOpenSettings.
  ///
  /// In en, this message translates to:
  /// **'Open Settings'**
  String get homeOpenSettings;

  /// No description provided for @guideTitle.
  ///
  /// In en, this message translates to:
  /// **'How SpotLink works'**
  String get guideTitle;

  /// No description provided for @guideSection1Title.
  ///
  /// In en, this message translates to:
  /// **'No internet needed'**
  String get guideSection1Title;

  /// No description provided for @guideSection1Body.
  ///
  /// In en, this message translates to:
  /// **'SpotLink connects directly to nearby devices over Bluetooth. Chat with friends close by even where networks are down, abroad, or in a disaster.'**
  String get guideSection1Body;

  /// No description provided for @guideSection2Title.
  ///
  /// In en, this message translates to:
  /// **'Friends, safely via QR'**
  String get guideSection2Title;

  /// No description provided for @guideSection2Body.
  ///
  /// In en, this message translates to:
  /// **'Scan a friend\'s code with the QR button on the Nearby tab to exchange encryption keys and become verified friends. People discovered nearby also appear automatically.'**
  String get guideSection2Body;

  /// No description provided for @guideSection3Title.
  ///
  /// In en, this message translates to:
  /// **'Reach farther through friends'**
  String get guideSection3Title;

  /// No description provided for @guideSection3Body.
  ///
  /// In en, this message translates to:
  /// **'Even beyond direct range, messages relay through other SpotLink devices in between. The radar on the Nearby tab shows who is how many hops away.'**
  String get guideSection3Body;

  /// No description provided for @guideSection4Title.
  ///
  /// In en, this message translates to:
  /// **'If not now, then when you meet'**
  String get guideSection4Title;

  /// No description provided for @guideSection4Body.
  ///
  /// In en, this message translates to:
  /// **'If someone is out of range, messages are held and delivered automatically the moment you meet again. Late arrivals show both the sent and arrival times.'**
  String get guideSection4Body;

  /// No description provided for @guideSection5Title.
  ///
  /// In en, this message translates to:
  /// **'Only the two of you can read it'**
  String get guideSection5Title;

  /// No description provided for @guideSection5Body.
  ///
  /// In en, this message translates to:
  /// **'Every message is end-to-end encrypted. Even relaying devices in the middle can\'t read the contents.'**
  String get guideSection5Body;

  /// No description provided for @guideSection6Title.
  ///
  /// In en, this message translates to:
  /// **'Battery is managed for you'**
  String get guideSection6Title;

  /// No description provided for @guideSection6Body.
  ///
  /// In en, this message translates to:
  /// **'When connections are stable it drops into power saving automatically, and speeds up while charging or looking for new friends. Even if the app closes, a nearby friend can wake it again.'**
  String get guideSection6Body;

  /// No description provided for @guideDontShowAgain.
  ///
  /// In en, this message translates to:
  /// **'Don\'t show again'**
  String get guideDontShowAgain;

  /// No description provided for @guideStart.
  ///
  /// In en, this message translates to:
  /// **'Get started'**
  String get guideStart;

  /// No description provided for @onboardingWelcome.
  ///
  /// In en, this message translates to:
  /// **'Welcome to\nSpotLink'**
  String get onboardingWelcome;

  /// No description provided for @onboardingSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Choose the name nearby friends will see.\nChat safely over Bluetooth, no internet needed.'**
  String get onboardingSubtitle;

  /// No description provided for @onboardingNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Display name'**
  String get onboardingNameLabel;

  /// No description provided for @onboardingNameHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. Alex'**
  String get onboardingNameHint;

  /// No description provided for @onboardingStart.
  ///
  /// In en, this message translates to:
  /// **'Get started'**
  String get onboardingStart;

  /// No description provided for @bootStepNotifications.
  ///
  /// In en, this message translates to:
  /// **'Preparing notifications'**
  String get bootStepNotifications;

  /// No description provided for @bootStepPermissions.
  ///
  /// In en, this message translates to:
  /// **'Requesting permissions'**
  String get bootStepPermissions;

  /// No description provided for @bootStepFailed.
  ///
  /// In en, this message translates to:
  /// **'{label} failed: {error}'**
  String bootStepFailed(Object label, Object error);

  /// No description provided for @bootLaunchFailed.
  ///
  /// In en, this message translates to:
  /// **'Launch failed (attempt {attempt}): {error}'**
  String bootLaunchFailed(Object attempt, Object error);

  /// No description provided for @bootRetrying.
  ///
  /// In en, this message translates to:
  /// **'{error}\nRetrying automatically'**
  String bootRetrying(Object error);
}

class _SDelegate extends LocalizationsDelegate<S> {
  const _SDelegate();

  @override
  Future<S> load(Locale locale) {
    return SynchronousFuture<S>(lookupS(locale));
  }

  @override
  bool isSupported(Locale locale) => <String>[
    'de',
    'en',
    'es',
    'fr',
    'ja',
    'ko',
    'pt',
    'zh',
  ].contains(locale.languageCode);

  @override
  bool shouldReload(_SDelegate old) => false;
}

S lookupS(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'de':
      return SDe();
    case 'en':
      return SEn();
    case 'es':
      return SEs();
    case 'fr':
      return SFr();
    case 'ja':
      return SJa();
    case 'ko':
      return SKo();
    case 'pt':
      return SPt();
    case 'zh':
      return SZh();
  }

  throw FlutterError(
    'S.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
