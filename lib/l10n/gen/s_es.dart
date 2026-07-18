// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 's.dart';

// ignore_for_file: type=lint

/// The translations for Spanish Castilian (`es`).
class SEs extends S {
  SEs([String locale = 'es']) : super(locale);

  @override
  String get appTitle => 'SpotLink';

  @override
  String get commonCancel => 'Cancelar';

  @override
  String get commonDelete => 'Eliminar';

  @override
  String get commonSave => 'Guardar';

  @override
  String get notifWakeNudgeTitle => 'Hay amigos de SpotLink cerca';

  @override
  String get notifWakeNudgeBody => 'Toca para abrir y conectarte al instante.';

  @override
  String notifReaction(Object emoji) {
    return 'reaccionó con $emoji';
  }

  @override
  String get notifChannelName => 'Mensajes';

  @override
  String get notifChannelDesc => 'Avisos de nuevos mensajes y archivos';

  @override
  String get errFileCopyFailed =>
      'No se pudo guardar el archivo, así que no se puede enviar';

  @override
  String get errFileGoneRetry =>
      'El archivo original ya no existe; no se puede reenviar';

  @override
  String errGallerySave(Object error) {
    return 'Error al guardar en la galería: $error';
  }

  @override
  String get errServiceConnecting => 'Conectando al servicio de malla…';

  @override
  String get fgsTitle => 'SpotLink activo';

  @override
  String get fgsSearching => 'Buscando personas cerca…';

  @override
  String fgsConnected(Object count) {
    return 'Conectado a $count dispositivo(s) cercano(s).';
  }

  @override
  String chatSendFailed(Object error) {
    return 'Error al enviar: $error';
  }

  @override
  String get chatAttachMedia => 'Fotos y vídeos';

  @override
  String get chatAttachMediaSubtitle =>
      'Elegir de la galería (varios permitidos)';

  @override
  String get chatAttachFile => 'Archivo';

  @override
  String get chatAttachFileSubtitle =>
      'Cualquier archivo: documentos, comprimidos y más';

  @override
  String get chatAttachApk => 'Enviar la app SpotLink';

  @override
  String get chatAttachApkSubtitle =>
      'Comparte el instalador (APK), sin tienda';

  @override
  String chatSkippedAttachments(Object count) {
    return 'No se pudieron adjuntar $count archivo(s). Puede que los originales no estén en este dispositivo (iCloud): ábrelos una vez en Fotos e inténtalo de nuevo.';
  }

  @override
  String get chatApkExtractFailed => 'No se pudo extraer el instalador';

  @override
  String get chatPresenceNearby => 'Cerca';

  @override
  String chatPresenceNearbyHops(Object hops) {
    return 'Cerca · vía $hops salto(s)';
  }

  @override
  String get chatPresenceOffline => 'Sin conexión · se entregará después';

  @override
  String get chatNewMessage => 'Mensaje nuevo';

  @override
  String get chatAttachTooltip => 'Adjuntar archivo';

  @override
  String get chatMessageHint => 'Mensaje';

  @override
  String get chatSendTooltip => 'Enviar';

  @override
  String get chatUnverifiedNotice =>
      'Esta persona aún no está verificada por QR.\nCuando os veáis, escanead vuestros códigos QR para confirmar la identidad.';

  @override
  String get chatIdCopied => 'ID copiado';

  @override
  String chatCopyId(Object id) {
    return 'Copiar ID $id';
  }

  @override
  String get chatTapRetry => 'Toca para reintentar';

  @override
  String get chatReceiveInterrupted => 'La recepción se interrumpió';

  @override
  String get chatUndelivered => 'Aún sin entregar · toca para reenviar';

  @override
  String get chatQueuedHint => 'Se entrega automáticamente al encontraros';

  @override
  String chatTimeSentArrived(Object sent, Object arrived) {
    return 'enviado $sent · llegó $arrived';
  }

  @override
  String get chatAllEmojis => 'Todos los emojis';

  @override
  String get chatCopy => 'Copiar';

  @override
  String get chatCopied => 'Copiado';

  @override
  String get chatView => 'Ver';

  @override
  String get chatSaveToGallery => 'Guardar en la galería';

  @override
  String get chatSavedToGallery => 'Guardado en la galería';

  @override
  String get chatSaveToGalleryFailed => 'No se pudo guardar en la galería';

  @override
  String get chatShareSaveToFiles => 'Compartir · guardar en Archivos';

  @override
  String get chatDeleteTitle => 'Eliminar mensaje';

  @override
  String chatDeleteFileContent(Object fileName) {
    return '$fileName se eliminará de este dispositivo. Seguirá en el dispositivo de la otra persona.';
  }

  @override
  String get chatDeleteTextContent =>
      '¿Eliminar este mensaje de este dispositivo? Seguirá en el dispositivo de la otra persona.';

  @override
  String get chatFileFallback => 'Archivo';

  @override
  String get chatCancelSendTitle => 'Cancelar envío';

  @override
  String chatCancelSendContent(Object fileName) {
    return '¿Cancelar el envío de $fileName?';
  }

  @override
  String get chatKeepSending => 'Seguir enviando';

  @override
  String get chatCancelSend => 'Cancelar envío';

  @override
  String get chatStatusSending => 'Enviando';

  @override
  String get chatStatusSent => 'Enviado';

  @override
  String get chatStatusDelivered => 'Entregado';

  @override
  String get chatStatusFailed => 'Falló';

  @override
  String get chatStatusQueued => 'En cola';

  @override
  String get chatImageFallback => 'Imagen';

  @override
  String chatFileSizeTapOpen(Object size) {
    return '$size · toca para abrir';
  }

  @override
  String chatTransferSending(Object percent) {
    return 'Enviando $percent%';
  }

  @override
  String chatTransferReceiving(Object percent) {
    return 'Recibiendo $percent%';
  }

  @override
  String get chatSentFile => 'Archivo enviado';

  @override
  String get chatReceivedFile => 'Archivo recibido';

  @override
  String get chatLaneWifi => 'Wi-Fi Direct';

  @override
  String get chatLaneBle => 'Bluetooth';

  @override
  String get chatEncryptedTitle =>
      'Esta conversación está cifrada de extremo a extremo';

  @override
  String get chatEncryptedSubtitle => 'Di hola 👋';

  @override
  String get chatShare => 'Compartir';

  @override
  String get meIdCopied => 'ID copiado';

  @override
  String meIdLabel(Object id) {
    return 'ID $id';
  }

  @override
  String get meQrGuide =>
      'Los amigos que escaneen este código se añaden de forma segura.\nTus claves nunca salen del dispositivo sin cifrar.';

  @override
  String get meShareSubject => 'Añádeme en SpotLink';

  @override
  String get meShareInvite => 'Compartir código de invitación';

  @override
  String get meSettingsTitle => 'Ajustes';

  @override
  String get meBatterySaverTitle => 'Ahorro de batería (siempre)';

  @override
  String get meBatterySaverSubtitle =>
      'Normalmente se ajusta solo según carga, batería y conexión. Al activarlo se fija el ahorro máximo (la búsqueda será más lenta).';

  @override
  String get meRelayStoreTitle => 'Buzón de retransmisión';

  @override
  String get meRelayStoreEmpty => 'No hay mensajes retransmitidos en espera.';

  @override
  String meRelayStorePending(Object count, Object size) {
    return '$count mensaje(s) en espera · $size\nSe entregan y borran automáticamente al encontrar al destinatario.';
  }

  @override
  String get meRelayClear => 'Vaciar';

  @override
  String get meGuideTitle => 'Cómo funciona';

  @override
  String get meGuideSubtitle => 'Vuelve a ver la guía del primer inicio.';

  @override
  String get meShareApkTitle => 'Compartir la app (distribución sin conexión)';

  @override
  String get meShareApkSubtitle =>
      'Extrae y comparte el instalador (APK): pásalo por Quick Share, Bluetooth y más, sin tienda ni internet.';

  @override
  String get meBeaconTitle => 'Despertar aun cerrada (baliza)';

  @override
  String get meBeaconSubtitle =>
      'Al detectar la baliza de un dispositivo SpotLink cercano, iOS despierta la app para recibir mensajes aunque estuviera cerrada. Requiere permiso de ubicación \"Siempre\".';

  @override
  String get meBeaconAlwaysTitle => 'Para conectar con más fiabilidad';

  @override
  String get meBeaconAlwaysSubtitle =>
      'El permiso de ubicación es \"Al usar la app\". Con \"Siempre\", la app se reconecta sola incluso tras cerrarse por completo o reiniciar el teléfono. (Las conexiones en segundo plano ya funcionan.)';

  @override
  String get meOpenSettings => 'Ajustes';

  @override
  String get meLiveReceiveTitle => 'Sobre la recepción en tiempo real';

  @override
  String get meLiveReceiveSubtitle =>
      'Si deslizas la app para cerrarla del todo, la recepción en tiempo real se detiene. Déjala en segundo plano para seguir recibiendo; lo perdido llega solo al reencontraros.';

  @override
  String get meShareApkFailed => 'No se pudo extraer el instalador';

  @override
  String get meShareApkSubject => 'Instalador de SpotLink';

  @override
  String get meRelayClearTitle => 'Vaciar buzón de retransmisión';

  @override
  String get meRelayClearBody =>
      'Elimina todos los mensajes que esperan ser entregados a otros.\nUna vez borrados, no se entregarán a través de este dispositivo (otro retransmisor podría entregarlos).';

  @override
  String get meEditNameTitle => 'Cambiar nombre';

  @override
  String get meDisplayNameLabel => 'Nombre visible';

  @override
  String get meBatteryExemptTitle => 'Ejecutar siempre en segundo plano';

  @override
  String get meBatteryChecking => 'Comprobando…';

  @override
  String get meBatteryExemptOn =>
      'Excluida de la optimización de batería. La malla sigue activa con la pantalla apagada.';

  @override
  String get meBatteryExemptOff =>
      'La optimización de batería está activa y el sistema puede cortar la recepción. Permítelo para recibir siempre.';

  @override
  String get meBatteryAllow => 'Permitir';

  @override
  String get meVersionCopied => 'Versión copiada';

  @override
  String get meAvatarNudgeText =>
      'Este avatar se generó al azar.\n¡Hazlo tuyo!';

  @override
  String get meAvatarNudgeCreate => 'Crear';

  @override
  String get meAvatarNudgeLater => 'Después';

  @override
  String get avatarSaved => 'Guardado: tus amigos cercanos ya te ven así';

  @override
  String get avatarTitle => 'Crear mi avatar';

  @override
  String get avatarShuffleTooltip => 'Mezcla aleatoria';

  @override
  String get avatarHint => 'Combina piezas para crear tu avatar · prueba el 🎲';

  @override
  String get avatarPartHairstyle => 'Peinado';

  @override
  String get avatarPartHairColor => 'Color de pelo';

  @override
  String get avatarPartFacialHair => 'Vello facial';

  @override
  String get avatarPartFacialHairColor => 'Color del vello';

  @override
  String get avatarPartOutfit => 'Ropa';

  @override
  String get avatarPartOutfitColor => 'Color de ropa';

  @override
  String get avatarPartEyes => 'Ojos';

  @override
  String get avatarPartEyebrows => 'Cejas';

  @override
  String get avatarPartMouth => 'Boca';

  @override
  String get avatarPartSkin => 'Piel';

  @override
  String get avatarPartAccessories => 'Gafas y accesorios';

  @override
  String get peopleSearchHint => 'Buscar por nombre';

  @override
  String get peopleSectionNearby => 'Cerca';

  @override
  String get peopleSectionVerified => 'Amigos verificados';

  @override
  String get peopleSectionChatted => 'Amigos con los que hablaste';

  @override
  String peopleSectionHeader(Object label, Object count) {
    return '$label · $count';
  }

  @override
  String get peopleBoosting => 'Búsqueda intensiva';

  @override
  String get peopleScanning => 'Buscando';

  @override
  String peopleTileSubtitle(Object id, Object proximity) {
    return '$id · $proximity';
  }

  @override
  String get peopleStatusOffline => 'Sin conexión';

  @override
  String peopleContactId(Object id) {
    return 'ID $id';
  }

  @override
  String get peopleActionChat => 'Chatear';

  @override
  String get peopleActionRename => 'Renombrar';

  @override
  String peopleDeleteTitle(Object name) {
    return 'Eliminar a $name';
  }

  @override
  String get peopleDeleteBody =>
      'También se eliminarán la conversación y los archivos compartidos.\n\nEsto no es un bloqueo: si sigue cerca, puede reaparecer como contacto nuevo.';

  @override
  String get peopleDisplayNameLabel => 'Nombre visible';

  @override
  String get peopleEmptyTitle => 'Aún no hay nadie';

  @override
  String get peopleEmptyBody =>
      'Los usuarios de SpotLink cercanos aparecen solos.\nEscanea el código QR de un amigo para añadirlo y verificarlo con seguridad.';

  @override
  String get peopleAddFriendQr => 'Añadir amigo por QR';

  @override
  String get peopleBluetoothOff =>
      'El Bluetooth está apagado o falta el permiso.';

  @override
  String radarTitle(Object count) {
    return 'Amigos cerca $count';
  }

  @override
  String radarTitleCapped(Object total, Object cap) {
    return '$total cerca · mostrando los $cap más cercanos';
  }

  @override
  String get radarResetZoom => 'Restablecer zoom';

  @override
  String get radarLegendVerified => 'Amigo verificado';

  @override
  String get radarLegendChatted => 'Amigo con quien hablaste';

  @override
  String get radarLegendDiscovered => 'Sin insignia: descubierto cerca';

  @override
  String radarZoomHint(Object scale) {
    return '$scale× · doble toque para restablecer';
  }

  @override
  String get radarPanZoomHint =>
      'Más cerca del centro = más próximo · pellizca para zoom, arrastra para mover';

  @override
  String radarOverflow(Object count) {
    return '+$count';
  }

  @override
  String get radarCardHint => 'Cuanto más cerca, más al centro';

  @override
  String get chatsEmptyPreview => 'Empieza una conversación';

  @override
  String get chatsMePrefix => 'Yo: ';

  @override
  String get chatsFileFallback => 'Archivo';

  @override
  String get chatsEmptyTitle => 'Aún no hay conversaciones';

  @override
  String get chatsEmptyBody => 'Chatea con gente cercana, sin internet.';

  @override
  String get chatsFindPeople => 'Ver gente cerca';

  @override
  String get chatsAddFriendQr => 'Añadir amigo por QR';

  @override
  String scanAddedContact(Object name) {
    return '$name añadido ✓';
  }

  @override
  String scanAddFailed(Object error) {
    return 'Error al añadir: $error';
  }

  @override
  String get scanTitle => 'Escanear código QR';

  @override
  String get scanFlash => 'Linterna';

  @override
  String get scanHint =>
      'Encaja el código QR de SpotLink de tu amigo en el marco';

  @override
  String get utilProximityVeryNear => 'Aquí mismo';

  @override
  String get utilProximityNear => 'Muy cerca';

  @override
  String get utilProximityNearby => 'Cerca';

  @override
  String get utilProximityFar => 'Lejos';

  @override
  String get utilProximityUnknown => 'Alrededor';

  @override
  String utilProximityRelayed(Object hops) {
    return 'a $hops salto(s)';
  }

  @override
  String get utilJustNow => 'ahora';

  @override
  String utilMinutesAgo(Object minutes) {
    return '$minutes min';
  }

  @override
  String get utilYesterday => 'Ayer';

  @override
  String get utilToday => 'Hoy';

  @override
  String get homeTabChats => 'Chats';

  @override
  String get homeTabNearby => 'Cerca';

  @override
  String get homeTabMe => 'Yo';

  @override
  String get homeStatusOff => 'Apagado';

  @override
  String homeStatusMesh(Object count) {
    return 'Malla $count';
  }

  @override
  String get homeStatusScanning => 'Buscando';

  @override
  String homeSemanticsConnected(Object count) {
    return '$count dispositivo(s) conectado(s)';
  }

  @override
  String get homeSemanticsScanning => 'Buscando cerca';

  @override
  String get homeSemanticsNoConnection => 'Sin conexión';

  @override
  String get homeSheetTitle => 'Estado de la malla';

  @override
  String get homeStatConnected => 'Dispositivos conectados';

  @override
  String get homeStatNearby => 'Amigos cerca';

  @override
  String get homeStatRelayQueue => 'Cola de retransmisión';

  @override
  String get homeBatterySaver => 'Ahorro de batería';

  @override
  String get homeBtPoweredOff =>
      'El Bluetooth está apagado. Enciéndelo y la búsqueda cercana empezará sola.';

  @override
  String get homeBtUnauthorized =>
      'Falta el permiso de Bluetooth. Permítelo en Ajustes > SpotLink.';

  @override
  String get homeBtUnavailable =>
      'El Bluetooth está apagado o sin permiso; no se pueden encontrar amigos cerca.';

  @override
  String get homeOpenSettings => 'Abrir Ajustes';

  @override
  String get guideTitle => 'Cómo funciona SpotLink';

  @override
  String get guideSection1Title => 'No necesita internet';

  @override
  String get guideSection1Body =>
      'SpotLink se conecta directamente a dispositivos cercanos por Bluetooth. Habla con amigos cercanos incluso sin red, en el extranjero o en un desastre.';

  @override
  String get guideSection2Title => 'Amigos, seguros con QR';

  @override
  String get guideSection2Body =>
      'Escanea el código de un amigo con el botón QR de la pestaña Cerca para intercambiar claves y ser amigos verificados. La gente descubierta cerca también aparece sola.';

  @override
  String get guideSection3Title => 'Llega más lejos a través de amigos';

  @override
  String get guideSection3Body =>
      'Incluso fuera del alcance directo, los mensajes se retransmiten por otros dispositivos SpotLink intermedios. El radar de la pestaña Cerca muestra a cuántos saltos está cada quien.';

  @override
  String get guideSection4Title => 'Si no es ahora, cuando os veáis';

  @override
  String get guideSection4Body =>
      'Si alguien está fuera de alcance, los mensajes se guardan y se entregan solos al reencontraros. Los que llegan tarde muestran la hora de envío y la de llegada.';

  @override
  String get guideSection5Title => 'Solo vosotros podéis leerlo';

  @override
  String get guideSection5Body =>
      'Cada mensaje va cifrado de extremo a extremo. Ni los dispositivos que retransmiten pueden leer el contenido.';

  @override
  String get guideSection6Title => 'La batería se gestiona sola';

  @override
  String get guideSection6Body =>
      'Con conexiones estables baja a ahorro automático, y acelera al cargar o buscar nuevos amigos. Aunque la app se cierre, un amigo cercano puede despertarla.';

  @override
  String get guideDontShowAgain => 'No mostrar de nuevo';

  @override
  String get guideStart => 'Empezar';

  @override
  String get onboardingWelcome => 'Bienvenido a\nSpotLink';

  @override
  String get onboardingSubtitle =>
      'Elige el nombre que verán tus amigos cercanos.\nChatea con seguridad por Bluetooth, sin internet.';

  @override
  String get onboardingNameLabel => 'Nombre visible';

  @override
  String get onboardingNameHint => 'p. ej. Alex';

  @override
  String get onboardingStart => 'Empezar';

  @override
  String get bootStepNotifications => 'Preparando notificaciones';

  @override
  String get bootStepPermissions => 'Solicitando permisos';

  @override
  String bootStepFailed(Object label, Object error) {
    return '$label falló: $error';
  }

  @override
  String bootLaunchFailed(Object attempt, Object error) {
    return 'Fallo al iniciar (intento $attempt): $error';
  }

  @override
  String bootRetrying(Object error) {
    return '$error\nReintentando automáticamente';
  }
}
