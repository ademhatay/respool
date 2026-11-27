using System.Globalization;

namespace Respool.Windows;

/// <summary>The interface's few words, in Turkish when Windows is, in English otherwise.</summary>
public static class Strings
{
    private static bool Turkish => CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "tr";

    private static string T(string turkish, string english) => Turkish ? turkish : english;

    public static string Open => T("Aç", "Open");
    public static string Refresh => T("Yenile", "Refresh");
    public static string Quit => T("Respool'dan çık", "Quit Respool");
    public static string Search => T("Sohbetlerde ara", "Search chats");
    public static string Loading => T("Sohbetler okunuyor…", "Reading chats…");
    public static string NoChats => T("Claude Code sohbeti bulunamadı", "No Claude Code chats found");
    public static string NoResults => T("Sonuç yok", "No results");
    public static string FolderMissing => T("Sohbet klasörü okunamadı", "The chats folder could not be read");
    public static string CopyId => T("Oturum kimliğini kopyala", "Copy the session ID");
    public static string ShowFolder => T("Klasörü göster", "Show the folder");
    public static string NewChatHere => T("Bu klasörde yeni sohbet", "New chat in this folder");
    public static string OpenFailed => T("Sohbet açılamadı", "The chat could not be opened");
    public static string ShortcutTaken =>
        T("Alt+Shift+Space başka bir uygulamada kullanılıyor; paneli tepsi simgesinden açın.",
          "Alt+Shift+Space is taken by another app; open the panel from the tray icon.");

    public static string Status(int chats, int projects) =>
        T($"{chats} sohbet · {projects} proje", $"{chats} chats · {projects} projects");
}
