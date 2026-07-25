// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 's.dart';

// ignore_for_file: type=lint

/// The translations for German (`de`).
class SDe extends S {
  SDe([String locale = 'de']) : super(locale);

  @override
  String get appTitle => 'SpotLink';

  @override
  String get commonCancel => 'Abbrechen';

  @override
  String get commonDelete => 'Löschen';

  @override
  String get commonSave => 'Speichern';

  @override
  String get notifWakeNudgeTitle => 'SpotLink-Freunde sind in der Nähe';

  @override
  String get notifWakeNudgeBody => 'Tippe zum Öffnen und verbinde dich sofort.';

  @override
  String notifReaction(Object emoji) {
    return 'hat mit $emoji reagiert';
  }

  @override
  String get notifChannelName => 'Nachrichten';

  @override
  String get notifChannelDesc => 'Hinweise zu neuen Nachrichten und Dateien';

  @override
  String get errFileCopyFailed =>
      'Datei konnte nicht gespeichert werden, Senden nicht möglich';

  @override
  String get errFileGoneRetry =>
      'Originaldatei fehlt, erneutes Senden nicht möglich';

  @override
  String errGallerySave(Object error) {
    return 'Speichern in Galerie fehlgeschlagen: $error';
  }

  @override
  String get errServiceConnecting => 'Verbinde mit Mesh-Dienst…';

  @override
  String get fgsTitle => 'SpotLink ist aktiv';

  @override
  String get fgsSearching => 'Suche nach Personen in der Nähe…';

  @override
  String fgsConnected(Object count) {
    return 'Mit $count Gerät(en) in der Nähe verbunden.';
  }

  @override
  String chatSendFailed(Object error) {
    return 'Senden fehlgeschlagen: $error';
  }

  @override
  String get chatAttachMedia => 'Fotos & Videos';

  @override
  String get chatAttachMediaSubtitle =>
      'Aus der Galerie wählen (mehrere möglich)';

  @override
  String get chatAttachFile => 'Datei';

  @override
  String get chatAttachFileSubtitle =>
      'Beliebige Dateien — Dokumente, Archive u. m.';

  @override
  String get chatAttachApk => 'SpotLink-App senden';

  @override
  String get chatAttachApkSubtitle =>
      'Installer (APK) weitergeben — ohne Store installieren';

  @override
  String chatSkippedAttachments(Object count) {
    return '$count Datei(en) konnten nicht angehängt werden. Die Originale sind evtl. nicht auf dem Gerät (iCloud) — einmal in Fotos öffnen und erneut versuchen.';
  }

  @override
  String get chatApkExtractFailed => 'Installer konnte nicht extrahiert werden';

  @override
  String get chatPresenceNearby => 'In der Nähe';

  @override
  String chatPresenceNearbyHops(Object hops) {
    return 'In der Nähe · über $hops Hop(s)';
  }

  @override
  String get chatPresenceOffline => 'Offline · wird später zugestellt';

  @override
  String get chatNewMessage => 'Neue Nachricht';

  @override
  String get chatAttachTooltip => 'Datei anhängen';

  @override
  String get chatMessageHint => 'Nachricht';

  @override
  String get chatSendTooltip => 'Senden';

  @override
  String get chatUnverifiedNotice =>
      'Diese Person ist noch nicht per QR verifiziert.\nScannt beim Treffen gegenseitig eure QR-Codes zur Bestätigung.';

  @override
  String get chatIdCopied => 'ID kopiert';

  @override
  String chatCopyId(Object id) {
    return 'ID $id kopieren';
  }

  @override
  String get chatTapRetry => 'Zum Wiederholen tippen';

  @override
  String get chatReceiveInterrupted => 'Empfang wurde unterbrochen';

  @override
  String get chatUndelivered =>
      'Noch nicht zugestellt · zum erneuten Senden tippen';

  @override
  String get chatQueuedHint => 'Wird beim Treffen automatisch zugestellt';

  @override
  String chatTimeSentArrived(Object sent, Object arrived) {
    return 'gesendet $sent · angekommen $arrived';
  }

  @override
  String get chatAllEmojis => 'Alle Emojis';

  @override
  String get chatCopy => 'Kopieren';

  @override
  String get chatCopied => 'Kopiert';

  @override
  String get chatView => 'Ansehen';

  @override
  String get chatSaveToGallery => 'In Galerie speichern';

  @override
  String get chatSavedToGallery => 'In Galerie gespeichert';

  @override
  String get chatSaveToGalleryFailed => 'Speichern in Galerie fehlgeschlagen';

  @override
  String get chatShareSaveToFiles => 'Teilen · in Dateien speichern';

  @override
  String get chatDeleteTitle => 'Nachricht löschen';

  @override
  String chatDeleteFileContent(Object fileName) {
    return '$fileName wird von diesem Gerät gelöscht. Auf dem Gerät der anderen Person bleibt sie erhalten.';
  }

  @override
  String get chatDeleteTextContent =>
      'Diese Nachricht von diesem Gerät löschen? Auf dem Gerät der anderen Person bleibt sie erhalten.';

  @override
  String get chatFileFallback => 'Datei';

  @override
  String get chatCancelSendTitle => 'Übertragung abbrechen';

  @override
  String chatCancelSendContent(Object fileName) {
    return 'Senden von $fileName abbrechen?';
  }

  @override
  String get chatKeepSending => 'Weiter senden';

  @override
  String get chatCancelSend => 'Übertragung abbrechen';

  @override
  String get chatStatusSending => 'Sendet';

  @override
  String get chatStatusSent => 'Gesendet';

  @override
  String get chatStatusDelivered => 'Zugestellt';

  @override
  String get chatStatusFailed => 'Fehlgeschlagen';

  @override
  String get chatStatusQueued => 'In Warteschlange';

  @override
  String get chatImageFallback => 'Bild';

  @override
  String chatFileSizeTapOpen(Object size) {
    return '$size · zum Öffnen tippen';
  }

  @override
  String chatTransferSending(Object percent) {
    return 'Senden $percent %';
  }

  @override
  String chatTransferReceiving(Object percent) {
    return 'Empfangen $percent %';
  }

  @override
  String get chatSentFile => 'Gesendete Datei';

  @override
  String get chatReceivedFile => 'Empfangene Datei';

  @override
  String get chatLaneWifi => 'Wi-Fi Direct';

  @override
  String get chatLaneBle => 'Bluetooth';

  @override
  String get chatEncryptedTitle =>
      'Diese Unterhaltung ist Ende-zu-Ende-verschlüsselt';

  @override
  String get chatEncryptedSubtitle => 'Sag Hallo 👋';

  @override
  String get chatShare => 'Teilen';

  @override
  String get meIdCopied => 'ID kopiert';

  @override
  String meIdLabel(Object id) {
    return 'ID $id';
  }

  @override
  String get meQrGuide =>
      'Freunde, die diesen Code scannen, werden sicher hinzugefügt.\nDeine Schlüssel verlassen das Gerät nie unverschlüsselt.';

  @override
  String get meShareSubject => 'Füge mich auf SpotLink hinzu';

  @override
  String get meShareInvite => 'Einladungscode teilen';

  @override
  String get meSettingsTitle => 'Einstellungen';

  @override
  String get meBatterySaverTitle => 'Energiesparen (immer)';

  @override
  String get meBatterySaverSubtitle =>
      'Passt sich sonst automatisch an Laden, Akku und Verbindung an. Eingeschaltet bleibt maximales Sparen fixiert (Suche wird langsamer).';

  @override
  String get meRelayStoreTitle => 'Relais-Postfach';

  @override
  String get meRelayStoreEmpty =>
      'Keine weitergeleiteten Nachrichten gespeichert.';

  @override
  String meRelayStorePending(Object count, Object size) {
    return '$count wartende Nachricht(en) · $size\nWerden beim Treffen des Empfängers automatisch zugestellt und gelöscht.';
  }

  @override
  String get meRelayClear => 'Leeren';

  @override
  String get meGuideTitle => 'So funktioniert es';

  @override
  String get meGuideSubtitle =>
      'Die Anleitung vom ersten Start erneut ansehen.';

  @override
  String get meShareApkTitle => 'App teilen (Offline-Verteilung)';

  @override
  String get meShareApkSubtitle =>
      'Installer (APK) extrahieren und teilen — per Quick Share, Bluetooth u. m., ganz ohne Store oder Internet.';

  @override
  String get meBeaconTitle => 'Auch nach dem Schließen aufwachen (Beacon)';

  @override
  String get meBeaconSubtitle =>
      'Wird ein SpotLink-Beacon in der Nähe erkannt, weckt iOS die App zum Empfangen — selbst wenn sie geschlossen war. Erfordert Standortberechtigung „Immer“.';

  @override
  String get meBeaconAlwaysTitle => 'Für zuverlässigere Verbindungen';

  @override
  String get meBeaconAlwaysSubtitle =>
      'Die Standortberechtigung steht auf „Beim Verwenden“. Mit „Immer“ verbindet sich die App auch nach vollständigem Schließen oder Neustart selbst wieder. (Hintergrundverbindungen laufen bereits.)';

  @override
  String get meOpenSettings => 'Einstellungen';

  @override
  String get meLiveReceiveTitle => 'Zum Echtzeit-Empfang';

  @override
  String get meLiveReceiveSubtitle =>
      'Wird die App weggewischt, stoppt der Echtzeit-Empfang. Im Hintergrund läuft er weiter; Verpasstes kommt beim nächsten Treffen automatisch an.';

  @override
  String get meShareApkFailed => 'Installer konnte nicht extrahiert werden';

  @override
  String get meShareApkSubject => 'SpotLink-Installer';

  @override
  String get meRelayClearTitle => 'Relais-Postfach leeren';

  @override
  String get meRelayClearBody =>
      'Löscht alle Nachrichten, die auf Zustellung an andere warten.\nNach dem Löschen erfolgt keine Zustellung über dieses Gerät mehr (ein anderes Relais kann sie ggf. noch zustellen).';

  @override
  String get meEditNameTitle => 'Namen ändern';

  @override
  String get meDisplayNameLabel => 'Anzeigename';

  @override
  String get meBatteryExemptTitle => 'Immer im Hintergrund laufen';

  @override
  String get meBatteryChecking => 'Prüfe…';

  @override
  String get meBatteryExemptOn =>
      'Von der Akku-Optimierung ausgenommen. Das Mesh läuft auch bei ausgeschaltetem Bildschirm weiter.';

  @override
  String get meBatteryExemptOff =>
      'Akku-Optimierung ist aktiv; das System kann den Empfang stoppen. Erlaube dies, um immer zu empfangen.';

  @override
  String get meBatteryAllow => 'Erlauben';

  @override
  String get meVersionCopied => 'Version kopiert';

  @override
  String get meAvatarNudgeText =>
      'Dieser Avatar wurde zufällig erzeugt.\nMach ihn zu deinem!';

  @override
  String get meAvatarNudgeCreate => 'Erstellen';

  @override
  String get meAvatarNudgeLater => 'Später';

  @override
  String get avatarSaved =>
      'Gespeichert — Freunde in der Nähe sehen dich jetzt so';

  @override
  String get avatarTitle => 'Meinen Avatar erstellen';

  @override
  String get avatarShuffleTooltip => 'Zufallsmix';

  @override
  String get avatarHint =>
      'Kombiniere Teile zu deinem eigenen Avatar · würfle mit 🎲';

  @override
  String get avatarPartHairstyle => 'Frisur';

  @override
  String get avatarPartHairColor => 'Haarfarbe';

  @override
  String get avatarPartFacialHair => 'Bart';

  @override
  String get avatarPartFacialHairColor => 'Bartfarbe';

  @override
  String get avatarPartOutfit => 'Outfit';

  @override
  String get avatarPartOutfitColor => 'Outfit-Farbe';

  @override
  String get avatarPartEyes => 'Augen';

  @override
  String get avatarPartEyebrows => 'Augenbrauen';

  @override
  String get avatarPartMouth => 'Mund';

  @override
  String get avatarPartSkin => 'Haut';

  @override
  String get avatarPartAccessories => 'Brille & Accessoires';

  @override
  String get peopleSearchHint => 'Nach Namen suchen';

  @override
  String get peopleSectionNearby => 'In der Nähe';

  @override
  String get peopleSectionVerified => 'Verifizierte Freunde';

  @override
  String get peopleSectionChatted => 'Freunde mit Chatverlauf';

  @override
  String peopleSectionHeader(Object label, Object count) {
    return '$label · $count';
  }

  @override
  String get peopleBoosting => 'Intensive Suche';

  @override
  String get peopleScanning => 'Suche';

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
  String get peopleActionChat => 'Chatten';

  @override
  String get peopleActionRename => 'Umbenennen';

  @override
  String peopleDeleteTitle(Object name) {
    return '$name löschen';
  }

  @override
  String get peopleDeleteBody =>
      'Die Unterhaltung und geteilte Dateien werden mitgelöscht.\n\nDas ist keine Blockierung — ist die Person in der Nähe, kann sie als neuer Kontakt wieder auftauchen.';

  @override
  String get peopleDisplayNameLabel => 'Anzeigename';

  @override
  String get peopleEmptyTitle => 'Noch niemand hier';

  @override
  String get peopleEmptyBody =>
      'SpotLink-Nutzer in der Nähe erscheinen automatisch.\nScanne den QR-Code eines Freundes, um ihn sicher hinzuzufügen und zu verifizieren.';

  @override
  String get peopleAddFriendQr => 'Freund per QR hinzufügen';

  @override
  String get peopleBluetoothOff =>
      'Bluetooth ist aus oder die Berechtigung fehlt.';

  @override
  String radarTitle(Object count) {
    return 'Freunde in der Nähe $count';
  }

  @override
  String radarTitleCapped(Object total, Object cap) {
    return '$total in der Nähe · die nächsten $cap angezeigt';
  }

  @override
  String get radarResetZoom => 'Zoom zurücksetzen';

  @override
  String get radarLegendVerified => 'Verifizierter Freund';

  @override
  String get radarLegendChatted => 'Chat-Freund';

  @override
  String get radarLegendDiscovered => 'Ohne Abzeichen: in der Nähe entdeckt';

  @override
  String radarZoomHint(Object scale) {
    return '$scale× · Doppeltippen zum Zurücksetzen';
  }

  @override
  String get radarPanZoomHint =>
      'Näher am Zentrum = näher dran · zum Zoomen kneifen, zum Verschieben ziehen';

  @override
  String radarOverflow(Object count) {
    return '+$count';
  }

  @override
  String get radarCardHint => 'Je näher, desto zentraler';

  @override
  String get chatsEmptyPreview => 'Starte eine Unterhaltung';

  @override
  String get chatsMePrefix => 'Ich: ';

  @override
  String get chatsFileFallback => 'Datei';

  @override
  String get chatsEmptyTitle => 'Noch keine Unterhaltungen';

  @override
  String get chatsEmptyBody =>
      'Chatte mit Leuten in der Nähe — ganz ohne Internet.';

  @override
  String get chatsFindPeople => 'Leute in der Nähe ansehen';

  @override
  String get chatsAddFriendQr => 'Freund per QR hinzufügen';

  @override
  String scanAddedContact(Object name) {
    return '$name hinzugefügt ✓';
  }

  @override
  String scanAddFailed(Object error) {
    return 'Hinzufügen fehlgeschlagen: $error';
  }

  @override
  String get scanTitle => 'QR-Code scannen';

  @override
  String get scanFlash => 'Taschenlampe';

  @override
  String get scanHint =>
      'Halte den SpotLink-QR-Code deines Freundes in den Rahmen';

  @override
  String get utilProximityVeryNear => 'Direkt hier';

  @override
  String get utilProximityNear => 'Ganz nah';

  @override
  String get utilProximityNearby => 'In der Nähe';

  @override
  String get utilProximityFar => 'Weit';

  @override
  String get utilProximityUnknown => 'Im Umkreis';

  @override
  String utilProximityRelayed(Object hops) {
    return '$hops Hop(s) entfernt';
  }

  @override
  String get utilJustNow => 'jetzt';

  @override
  String utilMinutesAgo(Object minutes) {
    return '$minutes Min.';
  }

  @override
  String get utilYesterday => 'Gestern';

  @override
  String get utilToday => 'Heute';

  @override
  String get homeTabChats => 'Chats';

  @override
  String get homeTabNearby => 'In der Nähe';

  @override
  String get homeTabMe => 'Ich';

  @override
  String get homeStatusOff => 'Aus';

  @override
  String homeStatusMesh(Object count) {
    return 'Mesh $count';
  }

  @override
  String get homeStatusScanning => 'Suche';

  @override
  String homeSemanticsConnected(Object count) {
    return '$count Gerät(e) verbunden';
  }

  @override
  String get homeSemanticsScanning => 'Suche in der Nähe';

  @override
  String get homeSemanticsNoConnection => 'Keine Verbindung';

  @override
  String get homeSheetTitle => 'Mesh-Status';

  @override
  String get homeStatConnected => 'Verbundene Geräte';

  @override
  String get homeStatNearby => 'Freunde in der Nähe';

  @override
  String get homeStatRelayQueue => 'Relais-Warteschlange';

  @override
  String get homeBatterySaver => 'Energiesparen';

  @override
  String get homeBtPoweredOff =>
      'Bluetooth ist aus. Nach dem Einschalten startet die Suche automatisch.';

  @override
  String get homeBtUnauthorized =>
      'Bluetooth-Berechtigung fehlt. Erlaube Bluetooth unter Einstellungen > SpotLink.';

  @override
  String get homeBtUnauthorizedDesktop =>
      'Bluetooth-Berechtigung fehlt. Erlaube SpotLink in Systemeinstellungen > Datenschutz & Sicherheit > Bluetooth.';

  @override
  String get homeBtUnavailable =>
      'Bluetooth ist aus oder nicht erlaubt — Freunde in der Nähe können nicht gefunden werden.';

  @override
  String get homeOpenSettings => 'Einstellungen öffnen';

  @override
  String get guideTitle => 'So funktioniert SpotLink';

  @override
  String get guideSection1Title => 'Kein Internet nötig';

  @override
  String get guideSection1Body =>
      'SpotLink verbindet sich per Bluetooth direkt mit Geräten in der Nähe. Chatte mit Freunden nebenan — auch ohne Netz, im Ausland oder im Katastrophenfall.';

  @override
  String get guideSection2Title => 'Freunde, sicher per QR';

  @override
  String get guideSection2Body =>
      'Scanne mit dem QR-Button im Nähe-Tab den Code eines Freundes: Ihr tauscht Schlüssel und werdet verifizierte Freunde. In der Nähe Entdeckte erscheinen auch automatisch.';

  @override
  String get guideSection3Title => 'Über Freunde weiter hinaus';

  @override
  String get guideSection3Body =>
      'Auch außer Reichweite werden Nachrichten über andere SpotLink-Geräte dazwischen weitergereicht. Das Radar im Nähe-Tab zeigt, wer wie viele Hops entfernt ist.';

  @override
  String get guideSection4Title => 'Wenn nicht jetzt, dann beim Treffen';

  @override
  String get guideSection4Body =>
      'Ist jemand außer Reichweite, werden Nachrichten aufbewahrt und beim Wiedersehen sofort zugestellt. Verspätete zeigen Sende- und Ankunftszeit.';

  @override
  String get guideSection5Title => 'Nur ihr beide könnt es lesen';

  @override
  String get guideSection5Body =>
      'Jede Nachricht ist Ende-zu-Ende-verschlüsselt. Auch weiterleitende Geräte können den Inhalt nicht lesen.';

  @override
  String get guideSection6Title => 'Der Akku wird geschont';

  @override
  String get guideSection6Body =>
      'Bei stabilen Verbindungen schaltet die App selbst in den Sparmodus und beschleunigt beim Laden oder bei der Suche nach neuen Freunden. Selbst geschlossen kann ein Freund in der Nähe sie wieder wecken.';

  @override
  String get guideDontShowAgain => 'Nicht mehr anzeigen';

  @override
  String get guideStart => 'Loslegen';

  @override
  String get onboardingWelcome => 'Willkommen bei\nSpotLink';

  @override
  String get onboardingSubtitle =>
      'Wähle den Namen, den Freunde in der Nähe sehen.\nChatte sicher per Bluetooth, ohne Internet.';

  @override
  String get onboardingNameLabel => 'Anzeigename';

  @override
  String get onboardingNameHint => 'z. B. Alex';

  @override
  String get onboardingStart => 'Loslegen';

  @override
  String get bootStepNotifications => 'Benachrichtigungen vorbereiten';

  @override
  String get bootStepPermissions => 'Berechtigungen anfordern';

  @override
  String bootStepFailed(Object label, Object error) {
    return '$label fehlgeschlagen: $error';
  }

  @override
  String bootLaunchFailed(Object attempt, Object error) {
    return 'Start fehlgeschlagen (Versuch $attempt): $error';
  }

  @override
  String bootRetrying(Object error) {
    return '$error\nErneuter Versuch läuft automatisch';
  }
}
