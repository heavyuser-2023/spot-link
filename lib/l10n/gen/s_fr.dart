// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 's.dart';

// ignore_for_file: type=lint

/// The translations for French (`fr`).
class SFr extends S {
  SFr([String locale = 'fr']) : super(locale);

  @override
  String get appTitle => 'SpotLink';

  @override
  String get commonCancel => 'Annuler';

  @override
  String get commonDelete => 'Supprimer';

  @override
  String get commonSave => 'Enregistrer';

  @override
  String get notifWakeNudgeTitle => 'Des amis SpotLink sont à proximité';

  @override
  String get notifWakeNudgeBody =>
      'Touchez pour ouvrir et vous connecter aussitôt.';

  @override
  String notifReaction(Object emoji) {
    return 'a réagi avec $emoji';
  }

  @override
  String get notifChannelName => 'Messages';

  @override
  String get notifChannelDesc => 'Alertes de nouveaux messages et fichiers';

  @override
  String get errFileCopyFailed =>
      'Impossible d\'enregistrer le fichier, envoi impossible';

  @override
  String get errFileGoneRetry =>
      'Le fichier d\'origine a disparu, renvoi impossible';

  @override
  String errGallerySave(Object error) {
    return 'Échec de l\'enregistrement dans la galerie : $error';
  }

  @override
  String get errServiceConnecting => 'Connexion au service maillé…';

  @override
  String get fgsTitle => 'SpotLink actif';

  @override
  String get fgsSearching => 'Recherche de personnes à proximité…';

  @override
  String fgsConnected(Object count) {
    return 'Connecté à $count appareil(s) proche(s).';
  }

  @override
  String chatSendFailed(Object error) {
    return 'Échec de l\'envoi : $error';
  }

  @override
  String get chatAttachMedia => 'Photos et vidéos';

  @override
  String get chatAttachMediaSubtitle =>
      'Choisir dans la galerie (plusieurs possibles)';

  @override
  String get chatAttachFile => 'Fichier';

  @override
  String get chatAttachFileSubtitle =>
      'Tout fichier — documents, archives, etc.';

  @override
  String get chatAttachApk => 'Envoyer l\'appli SpotLink';

  @override
  String get chatAttachApkSubtitle =>
      'Partager l\'installateur (APK) — sans store';

  @override
  String chatSkippedAttachments(Object count) {
    return '$count fichier(s) n\'ont pas pu être joints. Les originaux ne sont peut-être pas sur cet appareil (iCloud) — ouvrez-les une fois dans Photos puis réessayez.';
  }

  @override
  String get chatApkExtractFailed => 'Impossible d\'extraire l\'installateur';

  @override
  String get chatPresenceNearby => 'À proximité';

  @override
  String chatPresenceNearbyHops(Object hops) {
    return 'À proximité · via $hops saut(s)';
  }

  @override
  String get chatPresenceOffline => 'Hors ligne · sera livré plus tard';

  @override
  String get chatNewMessage => 'Nouveau message';

  @override
  String get chatAttachTooltip => 'Joindre un fichier';

  @override
  String get chatMessageHint => 'Message';

  @override
  String get chatSendTooltip => 'Envoyer';

  @override
  String get chatUnverifiedNotice =>
      'Cette personne n\'est pas encore vérifiée par QR.\nÀ votre rencontre, scannez vos codes QR pour confirmer vos identités.';

  @override
  String get chatIdCopied => 'ID copié';

  @override
  String chatCopyId(Object id) {
    return 'Copier l\'ID $id';
  }

  @override
  String get chatTapRetry => 'Touchez pour réessayer';

  @override
  String get chatReceiveInterrupted => 'Réception interrompue';

  @override
  String get chatUndelivered => 'Pas encore livré · touchez pour renvoyer';

  @override
  String get chatQueuedHint => 'Livré automatiquement à la rencontre';

  @override
  String chatTimeSentArrived(Object sent, Object arrived) {
    return 'envoyé $sent · arrivé $arrived';
  }

  @override
  String get chatAllEmojis => 'Tous les émojis';

  @override
  String get chatCopy => 'Copier';

  @override
  String get chatCopied => 'Copié';

  @override
  String get chatView => 'Voir';

  @override
  String get chatSaveToGallery => 'Enregistrer dans la galerie';

  @override
  String get chatSavedToGallery => 'Enregistré dans la galerie';

  @override
  String get chatSaveToGalleryFailed =>
      'Impossible d\'enregistrer dans la galerie';

  @override
  String get chatShareSaveToFiles => 'Partager · enregistrer dans Fichiers';

  @override
  String get chatDeleteTitle => 'Supprimer le message';

  @override
  String chatDeleteFileContent(Object fileName) {
    return '$fileName sera supprimé de cet appareil. Il restera sur l\'appareil de l\'autre personne.';
  }

  @override
  String get chatDeleteTextContent =>
      'Supprimer ce message de cet appareil ? Il restera sur l\'appareil de l\'autre personne.';

  @override
  String get chatFileFallback => 'Fichier';

  @override
  String get chatCancelSendTitle => 'Annuler le transfert';

  @override
  String chatCancelSendContent(Object fileName) {
    return 'Annuler l\'envoi de $fileName ?';
  }

  @override
  String get chatKeepSending => 'Continuer l\'envoi';

  @override
  String get chatCancelSend => 'Annuler le transfert';

  @override
  String get chatStatusSending => 'Envoi';

  @override
  String get chatStatusSent => 'Envoyé';

  @override
  String get chatStatusDelivered => 'Livré';

  @override
  String get chatStatusFailed => 'Échec';

  @override
  String get chatStatusQueued => 'En attente';

  @override
  String get chatImageFallback => 'Image';

  @override
  String chatFileSizeTapOpen(Object size) {
    return '$size · touchez pour ouvrir';
  }

  @override
  String chatTransferSending(Object percent) {
    return 'Envoi $percent%';
  }

  @override
  String chatTransferReceiving(Object percent) {
    return 'Réception $percent%';
  }

  @override
  String get chatSentFile => 'Fichier envoyé';

  @override
  String get chatReceivedFile => 'Fichier reçu';

  @override
  String get chatLaneWifi => 'Wi-Fi Direct';

  @override
  String get chatLaneBle => 'Bluetooth';

  @override
  String get chatEncryptedTitle =>
      'Cette conversation est chiffrée de bout en bout';

  @override
  String get chatEncryptedSubtitle => 'Dites bonjour 👋';

  @override
  String get chatShare => 'Partager';

  @override
  String get meIdCopied => 'ID copié';

  @override
  String meIdLabel(Object id) {
    return 'ID $id';
  }

  @override
  String get meQrGuide =>
      'Les amis qui scannent ce code sont ajoutés en toute sécurité.\nVos clés ne quittent jamais l\'appareil en clair.';

  @override
  String get meShareSubject => 'Ajoutez-moi sur SpotLink';

  @override
  String get meShareInvite => 'Partager le code d\'invitation';

  @override
  String get meSettingsTitle => 'Réglages';

  @override
  String get meBatterySaverTitle => 'Économie de batterie (toujours)';

  @override
  String get meBatterySaverSubtitle =>
      'S\'ajuste normalement selon la charge, la batterie et la connexion. Activer fige l\'économie maximale (la découverte ralentit).';

  @override
  String get meRelayStoreTitle => 'Boîte de relais';

  @override
  String get meRelayStoreEmpty => 'Aucun message relayé en attente.';

  @override
  String meRelayStorePending(Object count, Object size) {
    return '$count message(s) en attente · $size\nLivrés et effacés automatiquement à la rencontre du destinataire.';
  }

  @override
  String get meRelayClear => 'Vider';

  @override
  String get meGuideTitle => 'Comment ça marche';

  @override
  String get meGuideSubtitle => 'Revoir le guide du premier lancement.';

  @override
  String get meShareApkTitle => 'Partager l\'appli (distribution hors ligne)';

  @override
  String get meShareApkSubtitle =>
      'Extraire et partager l\'installateur (APK) — via Quick Share, Bluetooth, etc., sans store ni internet.';

  @override
  String get meBeaconTitle => 'Se réveiller même fermée (balise)';

  @override
  String get meBeaconSubtitle =>
      'À la détection d\'une balise SpotLink proche, iOS réveille l\'appli pour recevoir les messages même fermée. Nécessite la permission de localisation « Toujours ».';

  @override
  String get meBeaconAlwaysTitle => 'Pour une connexion plus fiable';

  @override
  String get meBeaconAlwaysSubtitle =>
      'La permission de localisation est « Pendant l\'utilisation ». En « Toujours », l\'appli se reconnecte seule même après fermeture complète ou redémarrage. (Les connexions en arrière-plan marchent déjà.)';

  @override
  String get meOpenSettings => 'Réglages';

  @override
  String get meLiveReceiveTitle => 'À propos de la réception en temps réel';

  @override
  String get meLiveReceiveSubtitle =>
      'Balayer l\'appli pour la fermer stoppe la réception en temps réel. Laissez-la en arrière-plan pour continuer à recevoir ; les messages manqués arrivent seuls aux retrouvailles.';

  @override
  String get meShareApkFailed => 'Impossible d\'extraire l\'installateur';

  @override
  String get meShareApkSubject => 'Installateur SpotLink';

  @override
  String get meRelayClearTitle => 'Vider la boîte de relais';

  @override
  String get meRelayClearBody =>
      'Supprime tous les messages en attente de livraison à autrui.\nUne fois supprimés, ils ne seront pas livrés via cet appareil (un autre relais peut encore les livrer).';

  @override
  String get meEditNameTitle => 'Changer de nom';

  @override
  String get meDisplayNameLabel => 'Nom affiché';

  @override
  String get meBatteryExemptTitle => 'Toujours actif en arrière-plan';

  @override
  String get meBatteryChecking => 'Vérification…';

  @override
  String get meBatteryExemptOn =>
      'Exclue de l\'optimisation de batterie. Le maillage continue écran éteint.';

  @override
  String get meBatteryExemptOff =>
      'L\'optimisation de batterie est active ; le système peut couper la réception. Autorisez pour toujours recevoir.';

  @override
  String get meBatteryAllow => 'Autoriser';

  @override
  String get meVersionCopied => 'Version copiée';

  @override
  String get meAvatarNudgeText =>
      'Cet avatar a été généré au hasard.\nFaites-en le vôtre !';

  @override
  String get meAvatarNudgeCreate => 'Créer';

  @override
  String get meAvatarNudgeLater => 'Plus tard';

  @override
  String get avatarSaved =>
      'Enregistré — vos amis proches vous voient désormais ainsi';

  @override
  String get avatarTitle => 'Créer mon avatar';

  @override
  String get avatarShuffleTooltip => 'Mélange aléatoire';

  @override
  String get avatarHint =>
      'Combinez des pièces pour créer votre avatar · lancez le 🎲';

  @override
  String get avatarPartHairstyle => 'Coiffure';

  @override
  String get avatarPartHairColor => 'Couleur de cheveux';

  @override
  String get avatarPartFacialHair => 'Pilosité faciale';

  @override
  String get avatarPartFacialHairColor => 'Couleur de barbe';

  @override
  String get avatarPartOutfit => 'Tenue';

  @override
  String get avatarPartOutfitColor => 'Couleur de tenue';

  @override
  String get avatarPartEyes => 'Yeux';

  @override
  String get avatarPartEyebrows => 'Sourcils';

  @override
  String get avatarPartMouth => 'Bouche';

  @override
  String get avatarPartSkin => 'Peau';

  @override
  String get avatarPartAccessories => 'Lunettes et accessoires';

  @override
  String get peopleSearchHint => 'Chercher par nom';

  @override
  String get peopleSectionNearby => 'À proximité';

  @override
  String get peopleSectionVerified => 'Amis vérifiés';

  @override
  String get peopleSectionChatted => 'Amis avec qui vous avez discuté';

  @override
  String peopleSectionHeader(Object label, Object count) {
    return '$label · $count';
  }

  @override
  String get peopleBoosting => 'Recherche intensive';

  @override
  String get peopleScanning => 'Recherche';

  @override
  String peopleTileSubtitle(Object id, Object proximity) {
    return '$id · $proximity';
  }

  @override
  String get peopleStatusOffline => 'Hors ligne';

  @override
  String peopleContactId(Object id) {
    return 'ID $id';
  }

  @override
  String get peopleActionChat => 'Discuter';

  @override
  String get peopleActionRename => 'Renommer';

  @override
  String peopleDeleteTitle(Object name) {
    return 'Supprimer $name';
  }

  @override
  String get peopleDeleteBody =>
      'La conversation et les fichiers échangés seront aussi supprimés.\n\nCe n\'est pas un blocage : si la personne est proche, elle peut réapparaître comme nouveau contact.';

  @override
  String get peopleDisplayNameLabel => 'Nom affiché';

  @override
  String get peopleEmptyTitle => 'Personne pour l\'instant';

  @override
  String get peopleEmptyBody =>
      'Les utilisateurs SpotLink proches apparaissent automatiquement.\nScannez le code QR d\'un ami pour l\'ajouter et le vérifier en sécurité.';

  @override
  String get peopleAddFriendQr => 'Ajouter un ami par QR';

  @override
  String get peopleBluetoothOff =>
      'Le Bluetooth est désactivé ou la permission manque.';

  @override
  String radarTitle(Object count) {
    return 'Amis proches $count';
  }

  @override
  String radarTitleCapped(Object total, Object cap) {
    return '$total à proximité · les $cap plus proches affichés';
  }

  @override
  String get radarResetZoom => 'Réinitialiser le zoom';

  @override
  String get radarLegendVerified => 'Ami vérifié';

  @override
  String get radarLegendChatted => 'Ami de discussion';

  @override
  String get radarLegendDiscovered => 'Sans badge : découvert à proximité';

  @override
  String radarZoomHint(Object scale) {
    return '$scale× · double-touchez pour réinitialiser';
  }

  @override
  String get radarPanZoomHint =>
      'Plus près du centre = plus proche · pincez pour zoomer, glissez pour déplacer';

  @override
  String radarOverflow(Object count) {
    return '+$count';
  }

  @override
  String get radarCardHint => 'Plus c\'est proche, plus c\'est au centre';

  @override
  String get chatsEmptyPreview => 'Commencez une conversation';

  @override
  String get chatsMePrefix => 'Moi : ';

  @override
  String get chatsFileFallback => 'Fichier';

  @override
  String get chatsEmptyTitle => 'Pas encore de conversations';

  @override
  String get chatsEmptyBody =>
      'Discutez avec les gens proches — sans internet.';

  @override
  String get chatsFindPeople => 'Voir les gens proches';

  @override
  String get chatsAddFriendQr => 'Ajouter un ami par QR';

  @override
  String scanAddedContact(Object name) {
    return '$name ajouté ✓';
  }

  @override
  String scanAddFailed(Object error) {
    return 'Échec de l\'ajout : $error';
  }

  @override
  String get scanTitle => 'Scanner le code QR';

  @override
  String get scanFlash => 'Lampe';

  @override
  String get scanHint =>
      'Placez le code QR SpotLink de votre ami dans le cadre';

  @override
  String get utilProximityVeryNear => 'Juste là';

  @override
  String get utilProximityNear => 'Tout près';

  @override
  String get utilProximityNearby => 'À proximité';

  @override
  String get utilProximityFar => 'Loin';

  @override
  String get utilProximityUnknown => 'Autour';

  @override
  String utilProximityRelayed(Object hops) {
    return 'à $hops saut(s)';
  }

  @override
  String get utilJustNow => 'à l\'instant';

  @override
  String utilMinutesAgo(Object minutes) {
    return '$minutes min';
  }

  @override
  String get utilYesterday => 'Hier';

  @override
  String get utilToday => 'Aujourd\'hui';

  @override
  String get homeTabChats => 'Discussions';

  @override
  String get homeTabNearby => 'À proximité';

  @override
  String get homeTabMe => 'Moi';

  @override
  String get homeStatusOff => 'Éteint';

  @override
  String homeStatusMesh(Object count) {
    return 'Maillage $count';
  }

  @override
  String get homeStatusScanning => 'Recherche';

  @override
  String homeSemanticsConnected(Object count) {
    return '$count appareil(s) connecté(s)';
  }

  @override
  String get homeSemanticsScanning => 'Recherche à proximité';

  @override
  String get homeSemanticsNoConnection => 'Aucune connexion';

  @override
  String get homeSheetTitle => 'État du maillage';

  @override
  String get homeStatConnected => 'Appareils connectés';

  @override
  String get homeStatNearby => 'Amis proches';

  @override
  String get homeStatRelayQueue => 'File de relais';

  @override
  String get homeBatterySaver => 'Économie de batterie';

  @override
  String get homeBtPoweredOff =>
      'Le Bluetooth est désactivé. Activez-le et la découverte démarre seule.';

  @override
  String get homeBtUnauthorized =>
      'Permission Bluetooth manquante. Autorisez-la dans Réglages > SpotLink.';

  @override
  String get homeBtUnavailable =>
      'Bluetooth désactivé ou non autorisé : impossible de trouver des amis proches.';

  @override
  String get homeOpenSettings => 'Ouvrir les Réglages';

  @override
  String get guideTitle => 'Comment marche SpotLink';

  @override
  String get guideSection1Title => 'Pas besoin d\'internet';

  @override
  String get guideSection1Body =>
      'SpotLink se connecte directement aux appareils proches en Bluetooth. Discutez avec vos amis proches même sans réseau, à l\'étranger ou en cas de catastrophe.';

  @override
  String get guideSection2Title => 'Des amis, en sécurité via QR';

  @override
  String get guideSection2Body =>
      'Scannez le code d\'un ami avec le bouton QR de l\'onglet À proximité pour échanger vos clés et devenir amis vérifiés. Les personnes découvertes à proximité apparaissent aussi automatiquement.';

  @override
  String get guideSection3Title => 'Plus loin grâce aux amis';

  @override
  String get guideSection3Body =>
      'Même hors de portée directe, les messages sont relayés par d\'autres appareils SpotLink intermédiaires. Le radar de l\'onglet À proximité montre qui est à combien de sauts.';

  @override
  String get guideSection4Title => 'Sinon maintenant, à la rencontre';

  @override
  String get guideSection4Body =>
      'Si quelqu\'un est hors de portée, les messages sont conservés et livrés dès les retrouvailles. Les arrivées tardives affichent l\'heure d\'envoi et d\'arrivée.';

  @override
  String get guideSection5Title => 'Rien que pour vous deux';

  @override
  String get guideSection5Body =>
      'Chaque message est chiffré de bout en bout. Même les appareils relais ne peuvent pas lire le contenu.';

  @override
  String get guideSection6Title => 'La batterie se gère toute seule';

  @override
  String get guideSection6Body =>
      'Quand les connexions sont stables, l\'appli passe seule en économie, et accélère en charge ou en recherche de nouveaux amis. Même fermée, un ami proche peut la réveiller.';

  @override
  String get guideDontShowAgain => 'Ne plus afficher';

  @override
  String get guideStart => 'Commencer';

  @override
  String get onboardingWelcome => 'Bienvenue sur\nSpotLink';

  @override
  String get onboardingSubtitle =>
      'Choisissez le nom que verront vos amis proches.\nDiscutez en sécurité par Bluetooth, sans internet.';

  @override
  String get onboardingNameLabel => 'Nom affiché';

  @override
  String get onboardingNameHint => 'ex. Alex';

  @override
  String get onboardingStart => 'Commencer';

  @override
  String get bootStepNotifications => 'Préparation des notifications';

  @override
  String get bootStepPermissions => 'Demande des permissions';

  @override
  String bootStepFailed(Object label, Object error) {
    return '$label a échoué : $error';
  }

  @override
  String bootLaunchFailed(Object attempt, Object error) {
    return 'Échec du lancement (essai $attempt) : $error';
  }

  @override
  String bootRetrying(Object error) {
    return '$error\nNouvel essai automatique';
  }
}
