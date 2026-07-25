// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 's.dart';

// ignore_for_file: type=lint

/// The translations for Portuguese (`pt`).
class SPt extends S {
  SPt([String locale = 'pt']) : super(locale);

  @override
  String get appTitle => 'SpotLink';

  @override
  String get commonCancel => 'Cancelar';

  @override
  String get commonDelete => 'Excluir';

  @override
  String get commonSave => 'Salvar';

  @override
  String get notifWakeNudgeTitle => 'Há amigos do SpotLink por perto';

  @override
  String get notifWakeNudgeBody => 'Toque para abrir e conectar na hora.';

  @override
  String notifReaction(Object emoji) {
    return 'reagiu com $emoji';
  }

  @override
  String get notifChannelName => 'Mensagens';

  @override
  String get notifChannelDesc => 'Avisos de novas mensagens e arquivos';

  @override
  String get errFileCopyFailed =>
      'Não foi possível salvar o arquivo, então não dá para enviar';

  @override
  String get errFileGoneRetry =>
      'O arquivo original sumiu; não dá para reenviar';

  @override
  String errGallerySave(Object error) {
    return 'Falha ao salvar na galeria: $error';
  }

  @override
  String get errServiceConnecting => 'Conectando ao serviço de malha…';

  @override
  String get fgsTitle => 'SpotLink ativo';

  @override
  String get fgsSearching => 'Procurando pessoas por perto…';

  @override
  String fgsConnected(Object count) {
    return 'Conectado a $count dispositivo(s) próximo(s).';
  }

  @override
  String chatSendFailed(Object error) {
    return 'Falha no envio: $error';
  }

  @override
  String get chatAttachMedia => 'Fotos e vídeos';

  @override
  String get chatAttachMediaSubtitle =>
      'Escolher da galeria (vários permitidos)';

  @override
  String get chatAttachFile => 'Arquivo';

  @override
  String get chatAttachFileSubtitle =>
      'Qualquer arquivo — documentos, compactados e mais';

  @override
  String get chatAttachApk => 'Enviar o app SpotLink';

  @override
  String get chatAttachApkSubtitle =>
      'Compartilhe o instalador (APK) — instala sem loja';

  @override
  String chatSkippedAttachments(Object count) {
    return '$count arquivo(s) não puderam ser anexados. Os originais podem não estar neste aparelho (iCloud) — abra-os uma vez no Fotos e tente de novo.';
  }

  @override
  String get chatApkExtractFailed => 'Não foi possível extrair o instalador';

  @override
  String get chatPresenceNearby => 'Por perto';

  @override
  String chatPresenceNearbyHops(Object hops) {
    return 'Por perto · via $hops salto(s)';
  }

  @override
  String get chatPresenceOffline => 'Offline · será entregue depois';

  @override
  String get chatNewMessage => 'Mensagem nova';

  @override
  String get chatAttachTooltip => 'Anexar arquivo';

  @override
  String get chatMessageHint => 'Mensagem';

  @override
  String get chatSendTooltip => 'Enviar';

  @override
  String get chatUnverifiedNotice =>
      'Esta pessoa ainda não foi verificada por QR.\nQuando se encontrarem, escaneiem os QR codes um do outro para confirmar a identidade.';

  @override
  String get chatIdCopied => 'ID copiado';

  @override
  String chatCopyId(Object id) {
    return 'Copiar ID $id';
  }

  @override
  String get chatTapRetry => 'Toque para tentar de novo';

  @override
  String get chatReceiveInterrupted => 'A recepção foi interrompida';

  @override
  String get chatUndelivered => 'Ainda não entregue · toque para reenviar';

  @override
  String get chatQueuedHint => 'Entrega automática quando se encontrarem';

  @override
  String chatTimeSentArrived(Object sent, Object arrived) {
    return 'enviado $sent · chegou $arrived';
  }

  @override
  String get chatAllEmojis => 'Todos os emojis';

  @override
  String get chatCopy => 'Copiar';

  @override
  String get chatCopied => 'Copiado';

  @override
  String get chatView => 'Ver';

  @override
  String get chatSaveToGallery => 'Salvar na galeria';

  @override
  String get chatSavedToGallery => 'Salvo na galeria';

  @override
  String get chatSaveToGalleryFailed => 'Não foi possível salvar na galeria';

  @override
  String get chatShareSaveToFiles => 'Compartilhar · salvar em Arquivos';

  @override
  String get chatDeleteTitle => 'Excluir mensagem';

  @override
  String chatDeleteFileContent(Object fileName) {
    return '$fileName será excluído deste aparelho. Continua no aparelho da outra pessoa.';
  }

  @override
  String get chatDeleteTextContent =>
      'Excluir esta mensagem deste aparelho? Continua no aparelho da outra pessoa.';

  @override
  String get chatFileFallback => 'Arquivo';

  @override
  String get chatCancelSendTitle => 'Cancelar transferência';

  @override
  String chatCancelSendContent(Object fileName) {
    return 'Cancelar o envio de $fileName?';
  }

  @override
  String get chatKeepSending => 'Continuar enviando';

  @override
  String get chatCancelSend => 'Cancelar transferência';

  @override
  String get chatStatusSending => 'Enviando';

  @override
  String get chatStatusSent => 'Enviado';

  @override
  String get chatStatusDelivered => 'Entregue';

  @override
  String get chatStatusFailed => 'Falhou';

  @override
  String get chatStatusQueued => 'Na fila';

  @override
  String get chatImageFallback => 'Imagem';

  @override
  String chatFileSizeTapOpen(Object size) {
    return '$size · toque para abrir';
  }

  @override
  String chatTransferSending(Object percent) {
    return 'Enviando $percent%';
  }

  @override
  String chatTransferReceiving(Object percent) {
    return 'Recebendo $percent%';
  }

  @override
  String get chatSentFile => 'Arquivo enviado';

  @override
  String get chatReceivedFile => 'Arquivo recebido';

  @override
  String get chatLaneWifi => 'Wi-Fi Direct';

  @override
  String get chatLaneBle => 'Bluetooth';

  @override
  String get chatEncryptedTitle =>
      'Esta conversa é criptografada de ponta a ponta';

  @override
  String get chatEncryptedSubtitle => 'Diga oi 👋';

  @override
  String get chatShare => 'Compartilhar';

  @override
  String get meIdCopied => 'ID copiado';

  @override
  String meIdLabel(Object id) {
    return 'ID $id';
  }

  @override
  String get meQrGuide =>
      'Amigos que escanearem este código são adicionados com segurança.\nSuas chaves nunca saem do aparelho sem criptografia.';

  @override
  String get meShareSubject => 'Me adicione no SpotLink';

  @override
  String get meShareInvite => 'Compartilhar código de convite';

  @override
  String get meSettingsTitle => 'Configurações';

  @override
  String get meBatterySaverTitle => 'Economia de bateria (sempre)';

  @override
  String get meBatterySaverSubtitle =>
      'Normalmente se ajusta sozinho conforme carga, bateria e conexão. Ao ativar, trava na economia máxima (a busca fica mais lenta).';

  @override
  String get meRelayStoreTitle => 'Caixa de retransmissão';

  @override
  String get meRelayStoreEmpty => 'Nenhuma mensagem retransmitida guardada.';

  @override
  String meRelayStorePending(Object count, Object size) {
    return '$count mensagem(ns) aguardando · $size\nEntregues e apagadas automaticamente ao encontrar o destinatário.';
  }

  @override
  String get meRelayClear => 'Esvaziar';

  @override
  String get meGuideTitle => 'Como funciona';

  @override
  String get meGuideSubtitle => 'Reveja o guia do primeiro uso.';

  @override
  String get meShareApkTitle => 'Compartilhar o app (distribuição offline)';

  @override
  String get meShareApkSubtitle =>
      'Extraia e compartilhe o instalador (APK) — via Quick Share, Bluetooth e mais, sem loja nem internet.';

  @override
  String get meBeaconTitle => 'Acordar mesmo fechado (beacon)';

  @override
  String get meBeaconSubtitle =>
      'Ao detectar o beacon de um SpotLink próximo, o iOS acorda o app para receber mensagens mesmo fechado. Requer permissão de localização \"Sempre\".';

  @override
  String get meBeaconAlwaysTitle => 'Para conectar com mais confiança';

  @override
  String get meBeaconAlwaysSubtitle =>
      'A permissão de localização está \"Durante o uso\". Mudando para \"Sempre\", o app se reconecta sozinho mesmo depois de fechado por completo ou de reiniciar o telefone. (As conexões em segundo plano já funcionam.)';

  @override
  String get meOpenSettings => 'Configurações';

  @override
  String get meLiveReceiveTitle => 'Sobre o recebimento em tempo real';

  @override
  String get meLiveReceiveSubtitle =>
      'Deslizar o app para fechá-lo interrompe o recebimento em tempo real. Deixe-o em segundo plano para continuar recebendo; o que perder chega sozinho no reencontro.';

  @override
  String get meShareApkFailed => 'Não foi possível extrair o instalador';

  @override
  String get meShareApkSubject => 'Instalador do SpotLink';

  @override
  String get meRelayClearTitle => 'Esvaziar caixa de retransmissão';

  @override
  String get meRelayClearBody =>
      'Apaga todas as mensagens aguardando entrega a outras pessoas.\nDepois de apagadas, não serão entregues por este aparelho (outro retransmissor ainda pode entregá-las).';

  @override
  String get meEditNameTitle => 'Mudar nome';

  @override
  String get meDisplayNameLabel => 'Nome de exibição';

  @override
  String get meBatteryExemptTitle => 'Sempre rodar em segundo plano';

  @override
  String get meBatteryChecking => 'Verificando…';

  @override
  String get meBatteryExemptOn =>
      'Excluído da otimização de bateria. A malha continua com a tela apagada.';

  @override
  String get meBatteryExemptOff =>
      'A otimização de bateria está ativa; o sistema pode parar o recebimento. Permita para receber sempre.';

  @override
  String get meBatteryAllow => 'Permitir';

  @override
  String get meVersionCopied => 'Versão copiada';

  @override
  String get meAvatarNudgeText =>
      'Este avatar foi gerado aleatoriamente.\nDeixe com a sua cara!';

  @override
  String get meAvatarNudgeCreate => 'Criar';

  @override
  String get meAvatarNudgeLater => 'Depois';

  @override
  String get avatarSaved => 'Salvo — amigos por perto já veem você assim';

  @override
  String get avatarTitle => 'Criar meu avatar';

  @override
  String get avatarShuffleTooltip => 'Mistura aleatória';

  @override
  String get avatarHint => 'Combine peças e crie seu avatar · role o 🎲';

  @override
  String get avatarPartHairstyle => 'Cabelo';

  @override
  String get avatarPartHairColor => 'Cor do cabelo';

  @override
  String get avatarPartFacialHair => 'Barba';

  @override
  String get avatarPartFacialHairColor => 'Cor da barba';

  @override
  String get avatarPartOutfit => 'Roupa';

  @override
  String get avatarPartOutfitColor => 'Cor da roupa';

  @override
  String get avatarPartEyes => 'Olhos';

  @override
  String get avatarPartEyebrows => 'Sobrancelhas';

  @override
  String get avatarPartMouth => 'Boca';

  @override
  String get avatarPartSkin => 'Pele';

  @override
  String get avatarPartAccessories => 'Óculos e acessórios';

  @override
  String get peopleSearchHint => 'Buscar por nome';

  @override
  String get peopleSectionNearby => 'Por perto';

  @override
  String get peopleSectionVerified => 'Amigos verificados';

  @override
  String get peopleSectionChatted => 'Amigos com quem conversou';

  @override
  String peopleSectionHeader(Object label, Object count) {
    return '$label · $count';
  }

  @override
  String get peopleBoosting => 'Busca intensa';

  @override
  String get peopleScanning => 'Buscando';

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
  String get peopleActionChat => 'Conversar';

  @override
  String get peopleActionRename => 'Renomear';

  @override
  String peopleDeleteTitle(Object name) {
    return 'Excluir $name';
  }

  @override
  String get peopleDeleteBody =>
      'A conversa e os arquivos trocados também serão excluídos.\n\nIsto não é um bloqueio — se a pessoa estiver por perto, pode reaparecer como novo contato.';

  @override
  String get peopleDisplayNameLabel => 'Nome de exibição';

  @override
  String get peopleEmptyTitle => 'Ninguém por aqui ainda';

  @override
  String get peopleEmptyBody =>
      'Usuários do SpotLink por perto aparecem sozinhos.\nEscaneie o QR code de um amigo para adicioná-lo e verificá-lo com segurança.';

  @override
  String get peopleAddFriendQr => 'Adicionar amigo por QR';

  @override
  String get peopleBluetoothOff =>
      'O Bluetooth está desligado ou sem permissão.';

  @override
  String radarTitle(Object count) {
    return 'Amigos por perto $count';
  }

  @override
  String radarTitleCapped(Object total, Object cap) {
    return '$total por perto · mostrando os $cap mais próximos';
  }

  @override
  String get radarResetZoom => 'Redefinir zoom';

  @override
  String get radarLegendVerified => 'Amigo verificado';

  @override
  String get radarLegendChatted => 'Amigo de conversa';

  @override
  String get radarLegendDiscovered => 'Sem selo: descoberto por perto';

  @override
  String radarZoomHint(Object scale) {
    return '$scale× · toque duas vezes para redefinir';
  }

  @override
  String get radarPanZoomHint =>
      'Mais perto do centro = mais próximo · belisque para zoom, arraste para mover';

  @override
  String radarOverflow(Object count) {
    return '+$count';
  }

  @override
  String get radarCardHint => 'Quanto mais perto, mais ao centro';

  @override
  String get chatsEmptyPreview => 'Comece uma conversa';

  @override
  String get chatsMePrefix => 'Eu: ';

  @override
  String get chatsFileFallback => 'Arquivo';

  @override
  String get chatsEmptyTitle => 'Nenhuma conversa ainda';

  @override
  String get chatsEmptyBody => 'Converse com pessoas por perto — sem internet.';

  @override
  String get chatsFindPeople => 'Ver pessoas por perto';

  @override
  String get chatsAddFriendQr => 'Adicionar amigo por QR';

  @override
  String scanAddedContact(Object name) {
    return '$name adicionado ✓';
  }

  @override
  String scanAddFailed(Object error) {
    return 'Falha ao adicionar: $error';
  }

  @override
  String get scanTitle => 'Escanear QR code';

  @override
  String get scanFlash => 'Lanterna';

  @override
  String get scanHint => 'Encaixe o QR code do SpotLink do seu amigo no quadro';

  @override
  String get utilProximityVeryNear => 'Bem aqui';

  @override
  String get utilProximityNear => 'Pertinho';

  @override
  String get utilProximityNearby => 'Por perto';

  @override
  String get utilProximityFar => 'Longe';

  @override
  String get utilProximityUnknown => 'Nos arredores';

  @override
  String utilProximityRelayed(Object hops) {
    return 'a $hops salto(s)';
  }

  @override
  String get utilJustNow => 'agora';

  @override
  String utilMinutesAgo(Object minutes) {
    return '$minutes min';
  }

  @override
  String get utilYesterday => 'Ontem';

  @override
  String get utilToday => 'Hoje';

  @override
  String get homeTabChats => 'Conversas';

  @override
  String get homeTabNearby => 'Por perto';

  @override
  String get homeTabMe => 'Eu';

  @override
  String get homeStatusOff => 'Desligado';

  @override
  String homeStatusMesh(Object count) {
    return 'Malha $count';
  }

  @override
  String get homeStatusScanning => 'Buscando';

  @override
  String homeSemanticsConnected(Object count) {
    return '$count dispositivo(s) conectado(s)';
  }

  @override
  String get homeSemanticsScanning => 'Buscando por perto';

  @override
  String get homeSemanticsNoConnection => 'Sem conexão';

  @override
  String get homeSheetTitle => 'Estado da malha';

  @override
  String get homeStatConnected => 'Dispositivos conectados';

  @override
  String get homeStatNearby => 'Amigos por perto';

  @override
  String get homeStatRelayQueue => 'Fila de retransmissão';

  @override
  String get homeBatterySaver => 'Economia de bateria';

  @override
  String get homeBtPoweredOff =>
      'O Bluetooth está desligado. Ligue-o e a busca começa sozinha.';

  @override
  String get homeBtUnauthorized =>
      'Sem permissão de Bluetooth. Permita em Ajustes > SpotLink.';

  @override
  String get homeBtUnauthorizedDesktop =>
      'Falta permissão de Bluetooth. Permita o SpotLink em Ajustes do Sistema > Privacidade e Segurança > Bluetooth.';

  @override
  String get homeBtUnavailable =>
      'Bluetooth desligado ou sem permissão — não dá para achar amigos por perto.';

  @override
  String get homeOpenSettings => 'Abrir Ajustes';

  @override
  String get guideTitle => 'Como o SpotLink funciona';

  @override
  String get guideSection1Title => 'Não precisa de internet';

  @override
  String get guideSection1Body =>
      'O SpotLink conecta direto a aparelhos próximos por Bluetooth. Converse com amigos por perto mesmo sem rede, no exterior ou num desastre.';

  @override
  String get guideSection2Title => 'Amigos, com segurança via QR';

  @override
  String get guideSection2Body =>
      'Escaneie o código de um amigo com o botão QR da aba Por perto para trocar chaves e virarem amigos verificados. Pessoas descobertas por perto também aparecem sozinhas.';

  @override
  String get guideSection3Title => 'Mais longe através dos amigos';

  @override
  String get guideSection3Body =>
      'Mesmo fora do alcance direto, mensagens são retransmitidas por outros SpotLinks no caminho. O radar da aba Por perto mostra quem está a quantos saltos.';

  @override
  String get guideSection4Title => 'Se não agora, quando se encontrarem';

  @override
  String get guideSection4Body =>
      'Se alguém estiver fora de alcance, as mensagens ficam guardadas e são entregues no instante do reencontro. As atrasadas mostram hora de envio e de chegada.';

  @override
  String get guideSection5Title => 'Só vocês dois podem ler';

  @override
  String get guideSection5Body =>
      'Toda mensagem é criptografada de ponta a ponta. Nem os aparelhos que retransmitem conseguem ler o conteúdo.';

  @override
  String get guideSection6Title => 'A bateria se cuida sozinha';

  @override
  String get guideSection6Body =>
      'Com conexões estáveis, entra em economia automática; carregando ou buscando novos amigos, acelera. Mesmo fechado, um amigo próximo pode acordá-lo de novo.';

  @override
  String get guideDontShowAgain => 'Não mostrar de novo';

  @override
  String get guideStart => 'Começar';

  @override
  String get onboardingWelcome => 'Bem-vindo ao\nSpotLink';

  @override
  String get onboardingSubtitle =>
      'Escolha o nome que os amigos por perto verão.\nConverse com segurança por Bluetooth, sem internet.';

  @override
  String get onboardingNameLabel => 'Nome de exibição';

  @override
  String get onboardingNameHint => 'ex.: Alex';

  @override
  String get onboardingStart => 'Começar';

  @override
  String get bootStepNotifications => 'Preparando notificações';

  @override
  String get bootStepPermissions => 'Solicitando permissões';

  @override
  String bootStepFailed(Object label, Object error) {
    return '$label falhou: $error';
  }

  @override
  String bootLaunchFailed(Object attempt, Object error) {
    return 'Falha ao iniciar (tentativa $attempt): $error';
  }

  @override
  String bootRetrying(Object error) {
    return '$error\nTentando de novo automaticamente';
  }
}
