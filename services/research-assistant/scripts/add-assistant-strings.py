#!/usr/bin/env python3
"""Insert V13 assistant localization keys into Localizable.xcstrings."""
import json
from pathlib import Path

CATALOG = Path("ios/PodcastEnglishStudio/PodcastEnglishStudio/Support/Localizable.xcstrings")

ENTRIES = {
    "navigation.assistant": {
        "comment": "Assistant tab",
        "en": "Assistant",
        "zh-Hans": "助手",
        "zh-Hant": "助手",
        "es": "Asistente",
        "pt-BR": "Assistente",
        "ja": "アシスタント",
        "ko": "어시스턴트",
        "fr": "Assistant",
        "de": "Assistent",
        "ar": "المساعد",
    },
    "assistant.setup_required_title": {
        "en": "Turn on the assistant service",
        "zh-Hans": "请开启助手服务",
        "zh-Hant": "請開啟助手服務",
        "es": "Activa el servicio del asistente",
        "pt-BR": "Ative o serviço do assistente",
        "ja": "アシスタントサービスをオンにする",
        "ko": "어시스턴트 서비스를 켜세요",
        "fr": "Activez le service d’assistant",
        "de": "Assistentendienst aktivieren",
        "ar": "شغّل خدمة المساعد",
    },
    "assistant.setup_required_body": {
        "en": "Enable the assistant service and add its address and token in Settings.",
        "zh-Hans": "请在设置中启用助手服务，并填写地址和令牌。",
        "zh-Hant": "請在設定中啟用助手服務，並填寫地址和權杖。",
        "es": "Activa el servicio del asistente y añade su dirección y token en Ajustes.",
        "pt-BR": "Ative o serviço do assistente e adicione o endereço e o token em Ajustes.",
        "ja": "設定でアシスタントサービスを有効にし、アドレスとトークンを追加してください。",
        "ko": "설정에서 어시스턴트 서비스를 켜고 주소와 토큰을 추가하세요.",
        "fr": "Activez le service d’assistant et ajoutez son adresse et son jeton dans Réglages.",
        "de": "Aktivieren Sie den Assistentendienst und hinterlegen Sie Adresse und Token in den Einstellungen.",
        "ar": "فعّل خدمة المساعد وأضف عنوانها ورمزها في الإعدادات.",
    },
    "assistant.new_research": {
        "en": "New research",
        "zh-Hans": "新建研究",
        "zh-Hant": "新建研究",
        "es": "Nueva investigación",
        "pt-BR": "Nova pesquisa",
        "ja": "新しい調査",
        "ko": "새 리서치",
        "fr": "Nouvelle recherche",
        "de": "Neue Recherche",
        "ar": "بحث جديد",
    },
    "assistant.recent": {
        "en": "Recent",
        "zh-Hans": "最近",
        "zh-Hant": "最近",
        "es": "Recientes",
        "pt-BR": "Recentes",
        "ja": "最近",
        "ko": "최근",
        "fr": "Récent",
        "de": "Zuletzt",
        "ar": "الأخيرة",
    },
    "assistant.empty": {
        "en": "No research sessions yet.",
        "zh-Hans": "还没有研究会话。",
        "zh-Hant": "尚無研究工作階段。",
        "es": "Todavía no hay sesiones de investigación.",
        "pt-BR": "Ainda não há sessões de pesquisa.",
        "ja": "調査セッションはまだありません。",
        "ko": "아직 리서치 세션이 없습니다.",
        "fr": "Aucune session de recherche pour le moment.",
        "de": "Noch keine Recherchesitzungen.",
        "ar": "لا توجد جلسات بحث بعد.",
    },
    "assistant.prepare_confirm_title": {
        "en": "Start deep research?",
        "zh-Hans": "开始深度研究？",
        "zh-Hant": "開始深度研究？",
        "es": "¿Iniciar la investigación profunda?",
        "pt-BR": "Iniciar pesquisa aprofundada?",
        "ja": "詳細調査を開始しますか？",
        "ko": "심층 리서치를 시작할까요?",
        "fr": "Démarrer la recherche approfondie ?",
        "de": "Tiefenrecherche starten?",
        "ar": "بدء البحث المتعمق؟",
    },
    "assistant.prepare_confirm_action": {
        "en": "Transcribe and translate",
        "zh-Hans": "转写并翻译",
        "zh-Hant": "轉寫並翻譯",
        "es": "Transcribir y traducir",
        "pt-BR": "Transcrever e traduzir",
        "ja": "文字起こしして翻訳",
        "ko": "전사하고 번역",
        "fr": "Transcrire et traduire",
        "de": "Transkribieren und übersetzen",
        "ar": "انسخ وترجم",
    },
    "assistant.prepare_confirm_body": {
        "en": "This uses the cloud transcription and translation service. It does not download media on this device.",
        "zh-Hans": "这将调用云端转写翻译服务，不会在本机下载媒体。",
        "zh-Hant": "這將呼叫雲端轉寫翻譯服務，不會在本機下載媒體。",
        "es": "Esto usa el servicio de transcripción y traducción en la nube. No descarga el contenido en este dispositivo.",
        "pt-BR": "Isso usa o serviço de transcrição e tradução na nuvem. Não baixa a mídia neste dispositivo.",
        "ja": "クラウドの文字起こしと翻訳サービスを使います。この端末にメディアは保存しません。",
        "ko": "클라우드 전사 및 번역 서비스를 사용합니다. 이 기기에 미디어를 다운로드하지 않습니다.",
        "fr": "Cela utilise le service cloud de transcription et de traduction. Aucun média n’est téléchargé sur cet appareil.",
        "de": "Dafür wird der Cloud-Dienst für Transkription und Übersetzung genutzt. Medien werden nicht auf diesem Gerät geladen.",
        "ar": "يستخدم هذا خدمة النسخ والترجمة السحابية. ولن يُنزَّل المحتوى على هذا الجهاز.",
    },
    "assistant.you": {"en": "You", "zh-Hans": "你", "zh-Hant": "你", "es": "Tú", "pt-BR": "Você", "ja": "あなた", "ko": "나", "fr": "Vous", "de": "Du", "ar": "أنت"},
    "assistant.assistant": {"en": "Assistant", "zh-Hans": "助手", "zh-Hant": "助手", "es": "Asistente", "pt-BR": "Assistente", "ja": "アシスタント", "ko": "어시스턴트", "fr": "Assistant", "de": "Assistent", "ar": "المساعد"},
    "assistant.select_and_prepare": {
        "en": "Select and prepare",
        "zh-Hans": "选择并准备",
        "zh-Hant": "選擇並準備",
        "es": "Seleccionar y preparar",
        "pt-BR": "Selecionar e preparar",
        "ja": "選択して準備",
        "ko": "선택하고 준비",
        "fr": "Sélectionner et préparer",
        "de": "Auswählen und vorbereiten",
        "ar": "اختر وجهّز",
    },
    "assistant.preparation": {
        "en": "Preparation",
        "zh-Hans": "准备进度",
        "zh-Hant": "準備進度",
        "es": "Preparación",
        "pt-BR": "Preparação",
        "ja": "準備",
        "ko": "준비",
        "fr": "Préparation",
        "de": "Vorbereitung",
        "ar": "التحضير",
    },
    "assistant.prompt_placeholder": {
        "en": "Ask or research a topic",
        "zh-Hans": "提问或研究一个主题",
        "zh-Hant": "提問或研究一個主題",
        "es": "Pregunta o investiga un tema",
        "pt-BR": "Pergunte ou pesquise um tema",
        "ja": "質問するか、テーマを調べる",
        "ko": "질문하거나 주제를 조사하세요",
        "fr": "Posez une question ou recherchez un sujet",
        "de": "Frage stellen oder ein Thema recherchieren",
        "ar": "اسأل أو ابحث عن موضوع",
    },
    "assistant.cancel": {"en": "Cancel", "zh-Hans": "取消", "zh-Hant": "取消", "es": "Cancelar", "pt-BR": "Cancelar", "ja": "キャンセル", "ko": "취소", "fr": "Annuler", "de": "Abbrechen", "ar": "إلغاء"},
    "assistant.dismiss": {"en": "Cancel", "zh-Hans": "取消", "zh-Hant": "取消", "es": "Cancelar", "pt-BR": "Cancelar", "ja": "キャンセル", "ko": "취소", "fr": "Annuler", "de": "Abbrechen", "ar": "إلغاء"},
    "assistant.send": {"en": "Send", "zh-Hans": "发送", "zh-Hant": "傳送", "es": "Enviar", "pt-BR": "Enviar", "ja": "送信", "ko": "보내기", "fr": "Envoyer", "de": "Senden", "ar": "إرسال"},
    "settings.assistant_service": {
        "en": "Research Assistant Service",
        "zh-Hans": "研究助手服务",
        "zh-Hant": "研究助手服務",
        "es": "Servicio de asistente de investigación",
        "pt-BR": "Serviço do assistente de pesquisa",
        "ja": "リサーチアシスタントサービス",
        "ko": "리서치 어시스턴트 서비스",
        "fr": "Service d’assistant de recherche",
        "de": "Recherche-Assistentendienst",
        "ar": "خدمة مساعد البحث",
    },
    "settings.assistant_service_enabled": {
        "en": "Enable Research Assistant",
        "zh-Hans": "启用研究助手",
        "zh-Hant": "啟用研究助手",
        "es": "Activar el asistente de investigación",
        "pt-BR": "Ativar o assistente de pesquisa",
        "ja": "リサーチアシスタントを有効にする",
        "ko": "리서치 어시스턴트 사용",
        "fr": "Activer l’assistant de recherche",
        "de": "Recherche-Assistent aktivieren",
        "ar": "تفعيل مساعد البحث",
    },
    "settings.assistant_service_status": {"en": "Status", "zh-Hans": "状态", "zh-Hant": "狀態", "es": "Estado", "pt-BR": "Status", "ja": "状態", "ko": "상태", "fr": "État", "de": "Status", "ar": "الحالة"},
    "settings.assistant_base_url": {
        "en": "Assistant Base URL",
        "zh-Hans": "助手服务地址",
        "zh-Hant": "助手服務網址",
        "es": "URL base del asistente",
        "pt-BR": "URL base do assistente",
        "ja": "アシスタントのベース URL",
        "ko": "어시스턴트 기본 URL",
        "fr": "URL de base de l’assistant",
        "de": "Assistenten-Basis-URL",
        "ar": "عنوان المساعد الأساسي",
    },
    "settings.assistant_access_token": {
        "en": "Assistant Access Token",
        "zh-Hans": "助手访问令牌",
        "zh-Hant": "助手存取權杖",
        "es": "Token de acceso del asistente",
        "pt-BR": "Token de acesso do assistente",
        "ja": "アシスタントのアクセストークン",
        "ko": "어시스턴트 액세스 토큰",
        "fr": "Jeton d’accès de l’assistant",
        "de": "Assistenten-Zugriffstoken",
        "ar": "رمز وصول المساعد",
    },
    "settings.assistant_service_help": {
        "en": "The assistant service is separate from cloud generation. It uses its own HTTPS address and token.",
        "zh-Hans": "助手服务与云端生成服务相互独立，使用单独的 HTTPS 地址和令牌。",
        "zh-Hant": "助手服務與雲端生成服務相互獨立，使用單獨的 HTTPS 網址和權杖。",
        "es": "El servicio del asistente es independiente de la generación en la nube. Usa su propia dirección HTTPS y token.",
        "pt-BR": "O serviço do assistente é separado da geração na nuvem. Ele usa o próprio endereço HTTPS e token.",
        "ja": "アシスタントサービスはクラウド生成とは別です。独自の HTTPS アドレスとトークンを使います。",
        "ko": "어시스턴트 서비스는 클라우드 생성과 별개이며 자체 HTTPS 주소와 토큰을 사용합니다.",
        "fr": "Le service d’assistant est distinct de la génération cloud. Il utilise sa propre adresse HTTPS et son jeton.",
        "de": "Der Assistentendienst ist von der Cloud-Generierung getrennt und nutzt eine eigene HTTPS-Adresse und ein eigenes Token.",
        "ar": "خدمة المساعد منفصلة عن التوليد السحابي وتستخدم عنوان HTTPS ورمزًا خاصين بها.",
    },
    "settings.assistant_status_disabled": {"en": "Disabled", "zh-Hans": "已关闭", "zh-Hant": "已關閉", "es": "Desactivado", "pt-BR": "Desativado", "ja": "オフ", "ko": "꺼짐", "fr": "Désactivé", "de": "Deaktiviert", "ar": "معطّل"},
    "settings.assistant_status_missing_token": {
        "en": "Access token not configured",
        "zh-Hans": "未配置访问令牌",
        "zh-Hant": "尚未設定存取權杖",
        "es": "Token de acceso no configurado",
        "pt-BR": "Token de acesso não configurado",
        "ja": "アクセストークンが未設定です",
        "ko": "액세스 토큰이 설정되지 않았습니다",
        "fr": "Jeton d’accès non configuré",
        "de": "Zugriffstoken nicht konfiguriert",
        "ar": "لم يُضبط رمز الوصول",
    },
    "settings.assistant_status_ready": {"en": "Ready", "zh-Hans": "就绪", "zh-Hant": "就緒", "es": "Listo", "pt-BR": "Pronto", "ja": "準備完了", "ko": "준비됨", "fr": "Prêt", "de": "Bereit", "ar": "جاهز"},
    "settings.assistant_token_not_set": {"en": "Not set", "zh-Hans": "未设置", "zh-Hant": "未設定", "es": "No definido", "pt-BR": "Não definido", "ja": "未設定", "ko": "설정되지 않음", "fr": "Non défini", "de": "Nicht festgelegt", "ar": "غير مضبوط"},
}


def unit(value: str) -> dict:
    return {"stringUnit": {"state": "translated", "value": value}}


def main() -> None:
    data = json.loads(CATALOG.read_text())
    strings = data.setdefault("strings", {})
    for key, entry in ENTRIES.items():
        comment = entry.pop("comment", None) if "comment" in entry else None
        localizations = {lang: unit(value) for lang, value in entry.items() if lang != "comment"}
        payload = {"localizations": localizations}
        if comment:
            payload["comment"] = comment
        strings[key] = payload
        # restore comment key for next loop safety
        if comment:
            entry["comment"] = comment
    CATALOG.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
    print(f"wrote {len(ENTRIES)} keys")


if __name__ == "__main__":
    main()
