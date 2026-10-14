import Foundation

/// Tiny two-language string table (Turkish if the system prefers it, English otherwise).
enum L {
    static let isTurkish = Locale.preferredLanguages.first?.hasPrefix("tr") ?? false
    private static func t(_ en: String, _ tr: String) -> String { isTurkish ? tr : en }

    static let now = t("now", "şimdi")
    static let dayUnit = t("d", "g")
    static let hourUnit = t("h", "s")
    static let minuteUnit = t("m", "dk")

    static func resetsIn(_ s: String) -> String { t("resets in \(s)", "\(s) sonra sıfırlanır") }
    static func cycleEndsIn(_ s: String) -> String { t("cycle ends in \(s)", "dönem \(s) sonra biter") }

    static let offline = t("offline", "bağlantı yok")
    static let loading = t("loading…", "yükleniyor…")
    static let settings = t("Settings", "Ayarlar")
    static let active = t("active", "aktif")
    static let notFound = t("No signed-in account found", "Giriş yapılmış hesap yok")
    static let noAccounts = t("No Cursor or Claude Code login found.", "Cursor ya da Claude Code girişi bulunamadı.")
    static let noneSelected = t("No account selected. Pick some from the gear menu.", "Hesap seçili değil. Dişli menüsünden seçin.")
    static let refresh = t("Refresh", "Yenile")
    static let openDashboard = t("Open usage dashboard", "Kullanım panelini aç")
    static let launchAtLogin = t("Launch at login", "Girişte başlat")
    static let quit = t("Quit", "Çık")
    static func updated(_ s: String) -> String { t("updated \(s)", "güncellendi \(s)") }

    // Cursor
    static let extraSpend = t("Extra spend", "Ekstra harcama")
    static let team = t("Team", "Takım")
    static let you = t("You", "Sen")
    static let limit = t("Limit", "Limit")
    static let planSpend = t("Plan usage", "Plan kullanımı")
    static let included = t("included", "dahil")
    static let autoMeter = t("Auto + Composer", "Auto + Composer")
    static let apiMeter = t("API (named models)", "API (seçili modeller)")
    static let cursorNoDB = t("Cursor is not installed or never signed in.", "Cursor kurulu değil ya da hiç giriş yapılmamış.")
    static let cursorNoToken = t("Sign in to Cursor first.", "Önce Cursor'a giriş yapın.")

    // Claude
    static let session = t("Session (5h)", "Oturum (5 sa)")
    static let weekly = t("Weekly (all models)", "Haftalık (tüm modeller)")
    static let weeklyOpus = t("Weekly (Opus)", "Haftalık (Opus)")
    static let weeklySonnet = t("Weekly (Sonnet)", "Haftalık (Sonnet)")
    static let extraUsage = t("Extra usage", "Ekstra kullanım")
    static let plan = t("Plan", "Plan")
    static let claudeNoCreds = t("No Claude Code login found. Run `claude` and sign in.", "Claude Code girişi bulunamadı. `claude` çalıştırıp giriş yapın.")
    static let claudeExpired = t("Claude login expired. Open Claude Code once to refresh it.", "Claude oturumunun süresi doldu. Yenilemek için Claude Code'u bir kez açın.")
    static let rateLimited = t("Rate limited, showing last value.", "İstek sınırı aşıldı, son değer gösteriliyor.")
}
