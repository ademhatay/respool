using System.Net.Http.Headers;
using System.Reflection;
using System.Text.Json;

namespace Respool.Core;

/// <summary>A published release: its version without the "v", its notes, when, and its page.</summary>
public sealed record Release(string Version, string Notes, DateTimeOffset? Date, string Url);

/// <summary>
/// The update check, Respool's only use of the network: the releases published on GitHub. It
/// only reads them; nothing is downloaded or installed.
/// </summary>
public static class Updates
{
    public const string Page = "https://github.com/ademhatay/respool/releases";
    private const string Api = "https://api.github.com/repos/ademhatay/respool/releases?per_page=12";

    private static readonly HttpClient Client = new() { Timeout = Timeout.InfiniteTimeSpan };

    /// <summary>The running version, without the "+commit" the build adds.</summary>
    public static string Installed { get; } = ReadInstalled();

    private static string ReadInstalled()
    {
        var assembly = Assembly.GetEntryAssembly() ?? typeof(Updates).Assembly;
        var version = assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion
            ?? assembly.GetName().Version?.ToString(3)
            ?? "0.0.0";
        var plus = version.IndexOf('+');
        return plus >= 0 ? version[..plus] : version;
    }

    /// <summary>The published releases, newest first, or null when GitHub could not be reached.</summary>
    public static async Task<IReadOnlyList<Release>?> FetchAsync()
    {
        try
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(12));
            using var request = new HttpRequestMessage(HttpMethod.Get, Api);
            request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));
            request.Headers.UserAgent.Add(new ProductInfoHeaderValue("Respool", null));
            request.Headers.CacheControl = new CacheControlHeaderValue { NoCache = true };
            using var response = await Client.SendAsync(request, timeout.Token).ConfigureAwait(false);
            if (response.StatusCode != System.Net.HttpStatusCode.OK) return null;
            var body = await response.Content.ReadAsStringAsync(timeout.Token).ConfigureAwait(false);
            return Parse(body);
        }
        catch (Exception exception) when (exception is HttpRequestException or OperationCanceledException or JsonException or InvalidOperationException or IOException)
        {
            return null;
        }
    }

    /// <summary>Reads the API's answer; drafts, pre-releases and untagged items are left out.</summary>
    public static IReadOnlyList<Release>? Parse(string json)
    {
        using var document = JsonDocument.Parse(json);
        if (document.RootElement.ValueKind != JsonValueKind.Array) return null;
        var releases = new List<Release>();
        foreach (var item in document.RootElement.EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.Object) continue;
            if (!item.TryGetProperty("tag_name", out var tag) || tag.ValueKind != JsonValueKind.String) continue;
            if (IsTrue(item, "draft") || IsTrue(item, "prerelease")) continue;
            var name = tag.GetString() ?? "";
            var version = name.StartsWith('v') || name.StartsWith('V') ? name[1..] : name;
            var notes = (Text(item, "body") ?? "").Replace("\r\n", "\n");
            DateTimeOffset? date = DateTimeOffset.TryParse(Text(item, "published_at"), System.Globalization.CultureInfo.InvariantCulture,
                System.Globalization.DateTimeStyles.AssumeUniversal, out var published) ? published : null;
            var url = Text(item, "html_url") is { Length: > 0 } link ? link : Page;
            releases.Add(new Release(version, notes, date, url));
        }
        return releases.OrderBy(release => release, Comparer<Release>.Create((a, b) =>
            IsNewer(a.Version, b.Version) ? -1 : IsNewer(b.Version, a.Version) ? 1 : 0)).ToList();
    }

    private static bool IsTrue(JsonElement item, string name) =>
        item.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.True;

    private static string? Text(JsonElement item, string name) =>
        item.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

    /// <summary>Whether version <paramref name="a"/> comes after <paramref name="b"/>, part by part.</summary>
    public static bool IsNewer(string a, string b)
    {
        var left = Parts(a);
        var right = Parts(b);
        for (var index = 0; index < Math.Max(left.Count, right.Count); index++)
        {
            var x = index < left.Count ? left[index] : 0;
            var y = index < right.Count ? right[index] : 0;
            if (x != y) return x > y;
        }
        return false;
    }

    private static List<int> Parts(string version) => version.Split('.').Select(part =>
    {
        var digits = new string(part.TakeWhile(char.IsAsciiDigit).ToArray());
        return int.TryParse(digits, out var value) ? value : 0;
    }).ToList();

    /// <summary>The newest release when it is newer than this one.</summary>
    public static Release? Available(IReadOnlyList<Release>? releases) =>
        releases is { Count: > 0 } && IsNewer(releases[0].Version, Installed) ? releases[0] : null;
}
