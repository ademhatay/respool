using System.Globalization;

namespace Respool.Core;

/// <summary>
/// The interface's words in Turkish or English, as the macOS app has them. Turkish when Windows
/// is in Turkish, unless a language is picked in Settings.
/// </summary>
public static partial class L
{
    /// <summary>"tr", "en", or "" to follow Windows. Set once at start; a change takes a restart.</summary>
    public static string Choice { get; set; } = "";

    public static bool Turkish => Choice switch
    {
        "tr" => true,
        "en" => false,
        _ => CultureInfo.InstalledUICulture.TwoLetterISOLanguageName == "tr" || CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "tr",
    };

    public static CultureInfo Culture => Turkish ? CultureInfo.GetCultureInfo("tr-TR") : CultureInfo.GetCultureInfo("en-GB");

    private static string T(string turkish, string english) => Turkish ? turkish : english;

    /// <summary>A figure with thousands grouped: 1.280 or 1,280.</summary>
    public static string Count(long figure) => figure.ToString("N0", Culture);

    private static string Counted(long figure, string turkish, string single, string plural) =>
        Turkish ? $"{Count(figure)} {turkish}" : $"{Count(figure)} {(figure == 1 ? single : plural)}";

    // Words Windows says differently from the Mac.
    public static string ShowInFinder => T("Klasörü göster", "Show the folder");
    public static string Show => T("Göster", "Show");
    public static string ShortcutNeedsModifier => T("Kısayolda Ctrl, Alt ya da Win olmalı", "The shortcut needs Ctrl, Alt or Win");
    public static string OneOrganization => T("Bu bilgisayarda tek bir organizasyonun sohbetleri var; seçici görünmeyecek.",
        "This PC has chats from a single organization; the switcher will not show.");
    public static string OpensInTabs => T("Windows Terminal'de yeni sekmede aç", "Open in a new Windows Terminal tab");
    public static string Billions => T(" Mr", "B");

    public static IReadOnlyList<string> ColorNames => Turkish
        ? ["Kırmızı", "Turuncu", "Sarı", "Yeşil", "Mavi", "Mor", "Gri"]
        : ["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"];

    public static string Sessions(long figure) => Counted(figure, "sohbet", "chat", "chats");
    public static string Prompts(long figure) => Counted(figure, "istem", "prompt", "prompts");
    public static string OpenTasks(long figure) => Counted(figure, "açık görev", "open task", "open tasks");
    public static string Files(long figure) => Counted(figure, "dosya", "file", "files");
    public static string Folders(long figure) => Counted(figure, "klasör", "folder", "folders");
    public static string MoreSessions(long figure) => Counted(figure, "sohbet daha", "more chat", "more chats");
    public static string MoreFolders(long figure) => T($"ve {Count(figure)} klasör daha", $"and {Folders(figure)} more");
    public static string MoreTimeRows(long figure) => Counted(figure, "proje daha", "more project", "more projects");
    public static string Minutes(long figure) => T($"{figure} dk", $"{figure} min");
    public static string Hours(long figure) => T($"{figure} sa", $"{figure} h");
    public static string Days(long figure) => Counted(figure, "gün", "day", "days");
    public static string ShortDays(long figure) => T($"{figure} gün", $"{figure} d");
    public static string DaysAgo(long figure) => T($"{figure} gün önce", $"{figure} days ago");
    public static string HoursAndMinutes(long hours, long minutes) => T($"{hours} sa {minutes} dk", $"{hours} h {minutes} min");
    public static string DaysAndHours(long days, long hours) => T($"{days} gün {hours} sa", $"{days} days {hours} h");

    public static string StatusLine(int chats, int shown, int total) =>
        $"{Sessions(chats)} · {(shown == total ? Count(total) : $"{shown}/{total}")} {T("proje", total == 1 && shown == total ? "project" : "projects")}";
    public static string IndexingProgress(int done, int total) => T($"Dizine ekleniyor {done} / {total}", $"Indexing {done} / {total}");
    public static string NoMatch(string query) => T($"“{query}” hiçbir sohbette geçmiyor.", $"“{query}” appears in no chat.");
    public static string TagHint(string tag) => T($"Bir sohbete sağ tıklayıp Etiketler menüsünden “{tag}” etiketini verin.",
        $"Right-click a chat and give it the “{tag}” tag from the Tags menu.");
    public static string BackedUpDaysLeft(long figure) => T($"Silinmeden yedeği alındı · {figure} gün kaldı", $"{BackedUp} · {Days(figure)} left");
    public static string MayDeleteIn(long figure) => T($"Claude Code bu sohbeti {figure} gün içinde silebilir", $"Claude Code can delete this chat in {Days(figure)}");
    public static string ExpiringChats(long figure) => T($"{Count(figure)} sohbet yakında silinebilir", $"{Sessions(figure)} will be deleted soon");
    public static string ExpiryHelp(int days) => T(
        $"Claude Code, {days} gündür yazılmayan terminal sohbetlerinin dökümünü siler. Bir kopyası alınan sohbetler işaretlenir; kopyalar Respool'un klasöründeki Backups içinde durur.",
        $"Claude Code deletes the transcripts of terminal chats it has not written to for {days} days. Chats that have a copy are marked; the copies are in Backups, in Respool's folder.");
    public static string TaskLinkHelp(string title) => T($"Görev buna bağlanacak: {title}", $"The task will be attached to this: {title}");
    public static string OpenTasksLine(string place, long open) => $"{place} · {OpenTasks(open)}";
    public static string PromptsLine(string place, long count) => $"{place} · {Prompts(count)}";
    public static string DaySummary(long chats, long typed) => $"{Sessions(chats)} · {Prompts(typed)}";
    public static string AccountNumber(int figure) => T($"Hesap {figure}", $"Account {figure}");
    public static string AccountState(int chats, bool current) =>
        current ? T($"şu an açık · {Sessions(chats)}", $"signed in · {Sessions(chats)}") : Sessions(chats);
    public static string LastActivity(string date) => T($"Son etkinlik {date}", $"Last activity {date}");
    public static string Backups(int count, string bytes) => T($"Yedekler · {Files(count)} · {bytes}", $"Backups · {Files(count)} · {bytes}");
    public static string BackedUpChats(long figure) => T($"{Count(figure)} sohbet yedeklendi", $"{Sessions(figure)} backed up");
    public static string ShortcutTaken(string label) => T($"{label} kullanılamıyor, başka bir uygulamada", $"{label} is taken by another app");
    public static string IndexUnopened(string error) => T($"Dizin dosyası açılamadı: {error}", $"The index file could not be opened: {error}");
    public static string InAccount(string name) => T($"{name} hesabında. Claude'da hesabı değiştirin.", $"In the {name} account. Switch account in Claude.");
    public static string WaitingFor(string what) => T($"Sizi bekliyor: {what}", $"Waiting for you: {what}");
    public static string DeleteLastEntry(string length) => T($"Son sayaç kaydını sil · {length}", $"Delete the last timer entry · {length}");
    public static string TimeBreakdown(string timer, string automatic) => T($"Sayaç {timer} · otomatik {automatic}", $"Timer {timer} · automatic {automatic}");
    public static string VersionTitle(string version) => T($"Sürüm {version}", $"Version {version}");
    public static string UpdateAvailable(string version) => T($"{version} yayında", $"{version} is out");
    public static string UpdateMenu(string version) => T($"Yeni sürüm: {version}…", $"New version: {version}…");
    public static string WelcomeFound(int chats, int projects) =>
        T($"{Count(chats)} sohbet · {Count(projects)} proje bulundu", $"Found {Count(chats)} chats in {Count(projects)} projects");
    public static string SummaryHeading(string day, string worked) => $"{day} · {worked}";
    public static string SessionsInTag(string tag, int count) => $"{tag} · {Sessions(count)}";
}

/// <summary>Numbers, lengths of time and dates, as the macOS app writes them.</summary>
public static class Format
{
    /// <summary>A token count in the largest unit that keeps it short: 512K, 39,2M, 1,5 Mr.</summary>
    public static string Tokens(long count)
    {
        string Scaled(double divisor, string suffix)
        {
            var value = Math.Round(count / divisor * 10) / 10;
            var text = value == Math.Round(value) ? ((long)value).ToString(CultureInfo.InvariantCulture) : value.ToString("0.0", L.Culture);
            return text + suffix;
        }
        if (count >= 1_000_000_000) return Scaled(1_000_000_000, L.Billions);
        if (count >= 1_000_000) return Scaled(1_000_000, "M");
        if (count >= 10_000) return $"{(long)Math.Round(count / 1000.0)}K";
        if (count >= 1000) return Scaled(1000, "K");
        return count.ToString(CultureInfo.InvariantCulture);
    }

    public static string Bytes(long count)
    {
        string[] units = ["bytes", "KB", "MB", "GB", "TB"];
        double value = count;
        var unit = 0;
        while (value >= 1000 && unit < units.Length - 1) { value /= 1000; unit++; }
        return unit == 0 ? $"{count} {units[0]}" : value.ToString(value >= 100 ? "0" : "0.#", L.Culture) + " " + units[unit];
    }

    private static string Pattern(DateTimeOffset? date, string pattern) =>
        date is null ? "—" : date.Value.ToLocalTime().ToString(pattern, L.Culture);

    public static string Date(DateTimeOffset? date) => Pattern(date, "d MMM yyyy HH:mm");
    public static string ShortDate(DateTimeOffset date) => Pattern(date, "d MMM HH:mm");
    public static string Day(DateTime date) => date.ToString("d MMMM dddd", L.Culture);
    public static string ShortDay(DateTime date) => date.ToString("ddd d MMM", L.Culture);
    public static string Weekday(DateTime date) => date.ToString("ddd", L.Culture);
    public static string ReleaseDate(DateTimeOffset date) => Pattern(date, "d MMM yyyy");
    public static string TimeOfDay(DateTimeOffset? date) => date is null ? "" : date.Value.ToLocalTime().ToString("HH:mm", L.Culture);

    public static string Month(DateTime date)
    {
        var text = date.ToString("MMMM yyyy", L.Culture);
        return L.Culture.TextInfo.ToTitleCase(text);
    }

    private static string MonthName(DateTime date) => L.Culture.TextInfo.ToTitleCase(date.ToString("MMMM", L.Culture));

    /// <summary>One month, or both when the days cross into another.</summary>
    public static string CalendarTitle(DateTime first, DateTime last)
    {
        if (first.Year == last.Year && first.Month == last.Month) return Month(first);
        if (first.Year == last.Year) return MonthName(first) + " – " + Month(last);
        return Month(first) + " – " + Month(last);
    }

    /// <summary>The local calendar day as <c>yyyy-MM-dd</c>, which sorts in date order.</summary>
    public static string DayKey(DateTime date) => date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
    public static string DayKey(DateTimeOffset date) => DayKey(date.ToLocalTime().DateTime);
    public static string Today => DayKey(DateTime.Now);

    public static DateTime? FromDayKey(string? key) =>
        DateTime.TryParseExact(key, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var date) ? date : null;

    /// <summary>A length of time in its two largest units: "6 sa 40 dk", "3 gün 2 sa".</summary>
    public static string Duration(double seconds)
    {
        var minutes = (long)(seconds / 60);
        if (minutes < 1) return L.UnderMinute;
        if (minutes < 60) return L.Minutes(minutes);
        var hours = minutes / 60;
        if (hours < 24) return minutes % 60 == 0 ? L.Hours(hours) : L.HoursAndMinutes(hours, minutes % 60);
        var days = hours / 24;
        return hours % 24 == 0 ? L.Days(days) : L.DaysAndHours(days, hours % 24);
    }

    /// <summary>A length of work in hours and minutes, however long: 26 sa 10 dk.</summary>
    public static string Worked(double seconds)
    {
        var minutes = (long)Math.Round(seconds / 60);
        if (minutes < 1) return L.UnderMinute;
        if (minutes < 60) return L.Minutes(minutes);
        return minutes % 60 == 0 ? L.Hours(minutes / 60) : L.HoursAndMinutes(minutes / 60, minutes % 60);
    }

    /// <summary>A running clock: 0:42:07.</summary>
    public static string Clock(double seconds)
    {
        var whole = Math.Max((long)seconds, 0);
        return $"{whole / 3600}:{whole / 60 % 60:00}:{whole % 60:00}";
    }

    /// <summary>Minutes and seconds, with the hours once there are any.</summary>
    public static string ShortClock(double seconds)
    {
        var whole = Math.Max((long)seconds, 0);
        return whole < 3600 ? $"{whole / 60}:{whole % 60:00}" : Clock(seconds);
    }

    public static string FolderPath(string path)
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        return path.StartsWith(home, StringComparison.OrdinalIgnoreCase) ? "~" + path[home.Length..] : path;
    }

    /// <summary>Today, Tomorrow, Yesterday, or "Wed 25 Nov".</summary>
    public static string DayLabel(string key)
    {
        var today = DateTime.Today;
        if (key == DayKey(today)) return L.Today;
        if (key == DayKey(today.AddDays(1))) return L.Tomorrow;
        if (key == DayKey(today.AddDays(-1))) return L.Yesterday;
        return FromDayKey(key) is { } date ? ShortDay(date) : key;
    }

    /// <summary>"now", "12 min", "3 h", "yesterday", "2 d", "4 Nov", "Nov 2025".</summary>
    public static string Relative(DateTimeOffset? date, DateTimeOffset? now = null)
    {
        if (date is null) return "";
        var current = now ?? DateTimeOffset.Now;
        var seconds = (current - date.Value).TotalSeconds;
        if (seconds < 60) return L.Now;
        if (seconds < 3600) return L.Minutes((long)(seconds / 60));
        var local = date.Value.ToLocalTime();
        var today = current.ToLocalTime().Date;
        if (local.Date == today) return L.Hours((long)(seconds / 3600));
        var days = (today - local.Date).Days;
        if (days <= 1) return L.Yesterday.ToLower(L.Culture);
        if (days < 7) return L.ShortDays(days);
        return local.ToString(local.Year == current.ToLocalTime().Year ? "d MMM" : "MMM yyyy", L.Culture);
    }
}
