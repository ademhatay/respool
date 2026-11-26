import Foundation

/// Every sentence the panel shows, in Turkish and in English, a line each.
///
/// The system's language chooses between them: Turkish when it comes first in the user's
/// languages, English for everything else. Dates, numbers and the calendar follow the same
/// choice. Messages that hold figures are functions, since English changes its nouns with
/// the count.
enum L10n {
    enum Language {
        case turkish, english
    }

    /// The language a developer mode asked for with `--lang`, whatever the system speaks.
    static var override: Language?

    static var language: Language {
        if let override { return override }
        return Locale.preferredLanguages.first?.hasPrefix("tr") == true ? .turkish : .english
    }

    /// The locale that shapes dates and numbers in the interface's language.
    static var localeIdentifier: String { language == .turkish ? "tr_TR" : "en_GB" }

    private static func tr(_ turkish: String, _ english: String) -> String {
        language == .turkish ? turkish : english
    }

    /// A figure with its noun. Turkish keeps the noun as it is; English changes it with the count.
    private static func counted(_ figure: Int, _ turkish: String, _ one: String, _ many: String) -> String {
        "\(Format.count(figure)) " + (language == .turkish ? turkish : (figure == 1 ? one : many))
    }

    // MARK: Words that several places use

    static var today: String { tr("Bugün", "Today") }
    static var tomorrow: String { tr("Yarın", "Tomorrow") }
    static var yesterday: String { tr("Dün", "Yesterday") }
    static var noDate: String { tr("Tarihsiz", "No date") }
    static var open: String { tr("Aç", "Open") }
    static var back: String { tr("Geri", "Back") }
    static var rename: String { tr("Yeniden adlandır", "Rename") }
    static var color: String { tr("Renk", "Color") }
    static var delete: String { tr("Sil", "Delete") }
    static var hide: String { tr("Gizle", "Hide") }
    static var refresh: String { tr("Yenile", "Refresh") }
    static var launchAtLogin: String { tr("Girişte başlat", "Start at login") }
    static var showInFinder: String { tr("Klasörü Finder'da göster", "Show the folder in Finder") }
    static var addTask: String { tr("Görev ekle", "Add a task") }
    static var removeLink: String { tr("Bağlantıyı kaldır", "Remove the link") }
    static var prompts: String { tr("İstem", "Prompts") }
    static var size: String { tr("Boyut", "Size") }

    // MARK: Panel

    static var searchPlaceholder: String { tr("Sohbetlerde ara", "Search chats") }
    static var clearSearch: String { tr("Aramayı temizle", "Clear the search") }
    static var newTag: String { tr("Yeni etiket…", "New tag…") }
    static var settingsMenu: String { tr("Ayarlar…", "Settings…") }
    static var quit: String { tr("Respool'dan çık", "Quit Respool") }
    static var account: String { tr("Hesap", "Account") }
    static var all: String { tr("Tümü", "All") }
    static var todosTitle: String { tr("Yapılacaklar", "To-dos") }
    static var overdue: String { tr("Gecikmiş", "Overdue") }
    static var pinnedTitle: String { tr("Sabitlenenler", "Pinned") }
    static var recentTitle: String { tr("Son sohbetler", "Recent chats") }
    static var weekTitle: String { tr("Bu hafta", "This week") }
    static var projectsTitle: String { tr("Projeler", "Projects") }
    static var allProjectsHidden: String { tr("Bütün projeler gizli ya da süzülüyor.", "Every project is hidden or filtered out.") }
    static var noResults: String { tr("Sonuç yok", "No results") }
    static var noTaggedChats: String { tr("Bu etikette sohbet yok", "No chats with this tag") }
    static var indexing: String { tr("Sohbetler dizine ekleniyor", "Indexing chats") }
    static var noChats: String { tr("Henüz sohbet yok", "No chats yet") }
    static var noChatsHint: String {
        tr("Claude Code'da bir sohbet başlattığınızda burada görünür.",
           "Start a chat in Claude Code and it shows up here.")
    }
    static var showSection: String { tr("Bölümü göster", "Show the section") }
    static var hideSection: String { tr("Bölümü gizle", "Hide the section") }

    /// The line at the bottom of the panel. The project count says how many are shown out of
    /// how many there are, when some are left out.
    static func statusLine(_ chats: Int, projectsShown: Int, projectsTotal: Int) -> String {
        let projects = projectsShown == projectsTotal ? "\(projectsShown)" : "\(projectsShown)/\(projectsTotal)"
        let noun = language == .turkish ? "proje" : "projects"
        return "\(sessions(chats)) · \(projects) \(noun)"
    }

    static func indexingProgress(_ done: Int, _ total: Int) -> String {
        tr("Dizine ekleniyor \(done) / \(total)", "Indexing \(done) / \(total)")
    }

    static func noMatch(_ query: String) -> String {
        tr("“\(query)” hiçbir sohbette geçmiyor.", "“\(query)” appears in no chat.")
    }

    static func tagHint(_ tag: String) -> String {
        tr("Bir sohbete sağ tıklayıp Etiketler menüsünden “\(tag)” etiketini verin.",
           "Right-click a chat and give it the “\(tag)” tag from the Tags menu.")
    }

    // MARK: Counts

    static func sessions(_ figure: Int) -> String { counted(figure, "sohbet", "chat", "chats") }
    static func prompts(_ figure: Int) -> String { counted(figure, "istem", "prompt", "prompts") }
    static func openTasks(_ figure: Int) -> String { counted(figure, "açık görev", "open task", "open tasks") }
    static func files(_ figure: Int) -> String { counted(figure, "dosya", "file", "files") }
    static func folders(_ figure: Int) -> String { counted(figure, "klasör", "folder", "folders") }

    static func moreSessions(_ figure: Int) -> String {
        language == .turkish ? "\(figure) sohbet daha" : "\(figure) more \(figure == 1 ? "chat" : "chats")"
    }

    static func moreFolders(_ figure: Int) -> String {
        tr("ve \(figure) klasör daha", "and \(folders(figure)) more")
    }

    static func minutes(_ figure: Int) -> String { tr("\(figure) dk", "\(figure) min") }
    static func hours(_ figure: Int) -> String { tr("\(figure) sa", "\(figure) h") }
    /// Whole days in a length of time.
    static func days(_ figure: Int) -> String { counted(figure, "gün", "day", "days") }

    // MARK: Session rows

    static var promptOutline: String { tr("İstem dökümü", "Prompt outline") }
    static var pin: String { tr("Sabitle", "Pin") }
    static var unpin: String { tr("Sabitlemeyi kaldır", "Unpin") }
    static var openInClaude: String { tr("Claude uygulamasında aç", "Open in the Claude app") }
    static var resumeInTerminal: String { tr("Terminalde sürdür", "Resume in a terminal") }
    static var tags: String { tr("Etiketler", "Tags") }
    static var backUpTranscript: String { tr("Dökümü yedekle", "Back up the transcript") }
    static var copySessionID: String { tr("Oturum kimliğini kopyala", "Copy the session ID") }

    // MARK: Deletion

    static var backedUp: String { tr("Silinmeden yedeği alındı", "Backed up before deletion") }
    static var mayDeleteNow: String { tr("Claude Code bu sohbeti artık silebilir", "Claude Code can delete this chat at any time") }
    static var backUp: String { tr("Yedekle", "Back up") }

    static func backedUpDaysLeft(_ figure: Int) -> String {
        tr("Silinmeden yedeği alındı · \(figure) gün kaldı", "\(backedUp) · \(days(figure)) left")
    }

    static func mayDeleteIn(_ figure: Int) -> String {
        tr("Claude Code bu sohbeti \(figure) gün içinde silebilir",
           "Claude Code can delete this chat in \(days(figure))")
    }

    static func expiringChats(_ figure: Int) -> String {
        language == .turkish ? "\(figure) sohbet yakında silinebilir" : "\(sessions(figure)) will be deleted soon"
    }

    static func expiryHelp(_ retentionDays: Int) -> String {
        tr("Claude Code, \(retentionDays) gündür yazılmayan terminal sohbetlerinin dökümünü siler. "
            + "Bir kopyası alınan sohbetler işaretlenir; kopyalar Respool'un klasöründeki Backups içinde durur.",
           "Claude Code deletes the transcripts of terminal chats it has not written to for \(retentionDays) days. "
            + "Chats that have a copy are marked; the copies are in Backups, in Respool's folder.")
    }

    // MARK: To-dos

    static var newTaskDayHelp: String {
        tr("Yeni görevler bu güne eklenir. Başka bir gün için takvimden gün seçin.",
           "New tasks go on this day. Pick another day in the calendar to plan ahead.")
    }
    static var previousMonth: String { tr("Önceki ay", "Previous month") }
    static var previousWeek: String { tr("Önceki hafta", "Previous week") }
    static var nextMonth: String { tr("Sonraki ay", "Next month") }
    static var nextWeek: String { tr("Sonraki hafta", "Next week") }
    static var weekView: String { tr("Hafta görünümüne geç", "Switch to the week view") }
    static var monthView: String { tr("Ay görünümüne geç", "Switch to the month view") }
    static var backToToday: String { tr("Bugüne dön", "Back to today") }

    static func taskLinkHelp(_ title: String) -> String {
        tr("Görev buna bağlanacak: \(title)", "The task will be attached to this: \(title)")
    }

    static func openTasksLine(_ place: String, _ open: Int) -> String {
        "\(place) · \(openTasks(open))"
    }

    // MARK: Tasks

    static var markNotDone: String { tr("Yapılmadı olarak işaretle", "Mark as not done") }
    static var markDone: String { tr("Tamamlandı olarak işaretle", "Mark as done") }
    static var startTaskInClaude: String { tr("Görevi Claude'da başlat", "Start the task in Claude") }
    static var deleteTask: String { tr("Görevi sil", "Delete the task") }
    static var date: String { tr("Tarih", "Date") }
    static var linkToProject: String { tr("Projeye bağla", "Link to a project") }

    // MARK: Week

    static func promptsLine(_ place: String, _ count: Int) -> String {
        "\(place) · \(prompts(count))"
    }

    static func daySummary(_ chats: Int, _ typed: Int) -> String {
        "\(sessions(chats)) · \(prompts(typed))"
    }

    static var hideDay: String { tr("Günün sohbetlerini gizle", "Hide the day's chats") }
    static var showDay: String { tr("Günün sohbetlerini göster", "Show the day's chats") }

    // MARK: Tags

    static var colorNames: [String] {
        language == .turkish
            ? ["Kırmızı", "Turuncu", "Sarı", "Yeşil", "Mavi", "Mor", "Gri"]
            : ["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"]
    }
    static var deleteTag: String { tr("Etiketi sil", "Delete the tag") }
    static var tagName: String { tr("Etiket adı", "Tag name") }

    // MARK: Accounts

    static var accountName: String { tr("Hesap adı", "Account name") }
    static var accountNames: String { tr("Hesap adları", "Account names") }
    static var saveNames: String { tr("Adları kaydet", "Save the names") }
    static var showAccounts: String { tr("Hesapları göster", "Show accounts") }
    static var oneOrganization: String {
        tr("Bu bilgisayarda tek bir organizasyonun sohbetleri var; seçici görünmeyecek.",
           "This Mac has chats from a single organization; the switcher will not show.")
    }

    static func accountNumber(_ figure: Int) -> String { tr("Hesap \(figure)", "Account \(figure)") }

    /// How many chats an account has, and whether it is the one Claude is signed in to.
    static func accountState(_ chats: Int, current: Bool) -> String {
        current ? tr("şu an açık · \(chats)", "signed in · \(chats)") : "\(chats)"
    }

    // MARK: Detail card

    static var inTerminal: String { tr(", terminalde", ", in a terminal") }
    static var inClaude: String { tr(", Claude'da", ", in Claude") }
    static var duration: String { tr("Süre", "Duration") }
    static var tokens: String { tr("Token", "Tokens") }
    static var input: String { tr("Girdi", "Input") }
    static var cache: String { tr("Önbellek", "Cache") }
    static var output: String { tr("Çıktı", "Output") }
    static var activity: String { tr("Etkinlik", "Activity") }
    static var chats: String { tr("Sohbet", "Chats") }
    static var last30Days: String { tr("Son 30 gün", "Last 30 days") }
    static var context: String { tr("Bağlam", "Context") }
    static var tokenWord: String { tr("token", "tokens") }

    static func lastActivity(_ date: String) -> String {
        tr("Son etkinlik \(date)", "Last activity \(date)")
    }

    // MARK: Prompt outline

    static var outlineEmpty: String {
        tr("Bu sohbette yazılmış bir istem bulunamadı.", "No prompt was ever typed in this chat.")
    }
    static var openChat: String { tr("Sohbeti aç", "Open the chat") }
    static var copy: String { tr("Kopyala", "Copy") }
    static var promptCopied: String { tr("İstem kopyalandı", "Prompt copied") }
    static var pastedContent: String { tr("[yapıştırılan içerik]", "[pasted content]") }

    // MARK: Settings

    static var settingsTitle: String { tr("Ayarlar", "Settings") }
    static var shortcut: String { tr("Kısayol", "Shortcut") }
    static var notifications: String { tr("Bildirimler", "Notifications") }
    static var showTodos: String { tr("Yapılacakları göster", "Show to-dos") }
    static var showWeek: String { tr("Hafta özetini göster", "Show the week summary") }
    static var show: String { tr("Finder'da göster", "Show in Finder") }
    static var hiddenProjects: String { tr("Gizli projeler", "Hidden projects") }
    static var bringBack: String { tr("Geri getir", "Bring back") }
    static var escToCancel: String { tr("Vazgeçmek için esc", "Press esc to cancel") }
    static var changeShortcut: String { tr("Kısayolu değiştir", "Change the shortcut") }
    static var pressKeys: String { tr("Tuşlara basın…", "Press the keys…") }
    static var notAssigned: String { tr("Atanmadı", "Not assigned") }

    static func backups(_ count: Int, _ bytes: String) -> String {
        let noun = language == .turkish ? "Yedekler" : "Backups"
        return "\(noun) · \(files(count)) · \(bytes)"
    }

    // MARK: Projects

    static var projectName: String { tr("Proje adı", "Project name") }
    static var startChatHere: String { tr("Bu projede yeni sohbet başlat", "Start a new chat in this project") }
    static var startChat: String { tr("Yeni sohbet başlat", "Start a new chat") }
    static var mergeInto: String { tr("Şununla birleştir", "Merge into") }
    static var undoMerge: String { tr("Birleştirmeyi geri al", "Undo the merge") }
    static var sortOrFilter: String { tr("Projeleri sırala ya da süz", "Sort or filter the projects") }
    static var sortBy: String { tr("Sıralama", "Sort by") }
    static var hideSingleSessionProjects: String { tr("Tek sohbetlik projeleri gizle", "Hide projects with a single chat") }
    static var hideInactiveProjects: String {
        tr("Son 30 günde etkin olmayanları gizle", "Hide projects inactive for 30 days")
    }
    static var manageHidden: String { tr("Gizli projeleri yönet…", "Manage hidden projects…") }

    // MARK: Sorting

    static var sortActivity: String { tr("Son etkinlik", "Last activity") }
    static var sortName: String { tr("Ad", "Name") }
    static var sortSessions: String { tr("Sohbet sayısı", "Chat count") }
    static var sortTokens: String { tr("Token kullanımı", "Token use") }

    // MARK: Notices

    static var loginItemFailed: String { tr("Giriş öğesi değiştirilemedi", "The login item could not be changed") }
    static var taskCopied: String { tr("Görev panoya kopyalandı", "The task is on the clipboard") }
    static var projectFolderMissing: String { tr("Proje klasörü bulunamadı", "The project's folder was not found") }
    static var backupFailed: String { tr("Yedeklenemedi", "Could not back up") }
    static var shortcutNeedsModifier: String { tr("Kısayolda ⌘, ⌥ veya ⌃ olmalı", "The shortcut needs ⌘, ⌥ or ⌃") }
    static var couldNotSave: String { tr("Kaydedilemedi", "Could not save") }
    static var chatOpenInTerminal: String { tr("Bu sohbet bir terminalde açık", "This chat is open in a terminal") }
    static var promptCopiedOutline: String { tr("İstem kopyalandı", "Prompt copied") }

    static func backedUpChats(_ figure: Int) -> String {
        language == .turkish ? "\(figure) sohbet yedeklendi" : "\(sessions(figure)) backed up"
    }

    static func shortcutTaken(_ label: String) -> String {
        tr("\(label) kullanılamıyor, başka bir uygulamada", "\(label) is taken by another app")
    }

    // MARK: Outside the panel

    static var launchFailed: String { tr("Respool başlatılamadı", "Respool could not start") }
    static var chatFailed: String { tr("Sohbet açılamadı", "The chat could not be opened") }
    static var chatFailedInClaude: String { tr("Sohbet Claude'da açılamadı", "The chat could not be opened in Claude") }
    static var sessionFailed: String { tr("Oturum başlatılamadı", "The session could not be started") }
    static var finished: String { tr("Bitti, sıra sizde", "Finished, your turn") }
    static var inOtherAccount: String {
        tr("Başka bir hesapta. Claude'da hesabı değiştirin.", "In another account. Switch account in Claude.")
    }

    static func indexUnopened(_ error: String) -> String {
        tr("Dizin dosyası açılamadı: \(error)", "The index file could not be opened: \(error)")
    }

    /// The notice for a chat the desktop app filed under an account it is not signed in to.
    static func inAccount(_ name: String) -> String {
        tr("\(name) hesabında. Claude'da hesabı değiştirin.", "In the \(name) account. Switch account in Claude.")
    }

    // MARK: Names and states

    static var untitledChat: String { tr("Adsız sohbet", "Untitled chat") }
    static var otherProject: String { tr("Diğer", "Other") }
    static var personal: String { tr("Kişisel", "Personal") }
    static var working: String { tr("Çalışıyor", "Working") }
    static var waiting: String { tr("Sizi bekliyor", "Waiting for you") }
    static var idle: String { tr("Açık", "Open") }

    static func waitingFor(_ what: String) -> String {
        tr("Sizi bekliyor: \(what)", "Waiting for you: \(what)")
    }

    static func daysAgo(_ figure: Int) -> String {
        tr("\(figure) gün önce", "\(figure) days ago")
    }

    // MARK: Lengths of time

    static var underMinute: String { tr("1 dk'dan az", "under 1 min") }

    static func hoursAndMinutes(_ hours: Int, _ minutes: Int) -> String {
        tr("\(hours) sa \(minutes) dk", "\(hours) h \(minutes) min")
    }

    static func daysAndHours(_ days: Int, _ hours: Int) -> String {
        tr("\(days) gün \(hours) sa", "\(days) days \(hours) h")
    }

    static var now: String { tr("şimdi", "now") }

    /// Days in the short form the list uses, as in "3 d".
    static func shortDays(_ figure: Int) -> String { tr("\(figure) gün", "\(figure) d") }

    // MARK: Notes and quick capture

    static var notesTitle: String { tr("Notlar", "Notes") }
    static var notePlaceholder: String { tr("Not yaz", "Write a note") }
    static var turnIntoTask: String { tr("Göreve çevir", "Turn into a task") }
    static var deleteNote: String { tr("Notu sil", "Delete the note") }
    static var noteCopied: String { tr("Not kopyalandı", "Note copied") }
    static var quickTaskShortcut: String { tr("Hızlı görev", "Quick task") }
    static var quickNoteShortcut: String { tr("Hızlı not", "Quick note") }
    static var openPanelShortcut: String { tr("Paneli aç", "Open the panel") }

    static var panelPosition: String { tr("Panel konumu", "Panel position") }
    static var edgeRight: String { tr("Sağ", "Right") }
    static var edgeLeft: String { tr("Sol", "Left") }
    static var edgeTop: String { tr("Üst", "Top") }
    static var edgeBottom: String { tr("Alt", "Bottom") }

    static var terminalFailed: String { tr("Terminal açılamadı", "The terminal could not be opened") }

    // MARK: Figures

    /// The suffix for thousands of millions of tokens.
    static var billions: String { tr(" Mr", "B") }

    /// Writes a decimal the way the language does: a comma in Turkish, a point in English.
    static func decimal(_ text: String) -> String {
        language == .turkish ? text.replacingOccurrences(of: ".", with: ",") : text
    }

    // MARK: Sample data

    static var previewTasks: [[String]] {
        language == .turkish
            ? [["Staging ortamında dene", "Hata mesajlarını gözden geçir"], [], ["Sonuçları ekiple paylaş"]]
            : [["Try it on staging", "Review the error messages"], [], ["Share the results with the team"]]
    }
}
