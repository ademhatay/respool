using Microsoft.Data.Sqlite;

namespace Respool.Core;

/// <summary>Where Respool keeps its own files, and where it reads Claude Code's.</summary>
public static class Paths
{
    /// <summary><c>CLAUDE_CONFIG_DIR</c>, or <c>%USERPROFILE%\.claude</c>.</summary>
    public static string ClaudeRoot
    {
        get
        {
            var config = Environment.GetEnvironmentVariable("CLAUDE_CONFIG_DIR");
            return string.IsNullOrEmpty(config)
                ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude")
                : config;
        }
    }

    /// <summary>The transcripts. <c>RESPOOL_TRANSCRIPTS</c> points elsewhere, for the check program.</summary>
    public static string Transcripts =>
        Environment.GetEnvironmentVariable("RESPOOL_TRANSCRIPTS") is { Length: > 0 } other ? other : Path.Combine(ClaudeRoot, "projects");

    /// <summary><c>%APPDATA%\Respool</c>, made when first asked for.</summary>
    public static string Support
    {
        get
        {
            var folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Respool");
            Directory.CreateDirectory(folder);
            return folder;
        }
    }

    /// <summary>The index and the user's own data. <c>RESPOOL_DB</c> points elsewhere, for the check program.</summary>
    public static string Database =>
        Environment.GetEnvironmentVariable("RESPOOL_DB") is { Length: > 0 } other ? other : Path.Combine(Support, "respool.db");
}

/// <summary>
/// One SQLite connection, with the macOS app's schema: the same tables, so what one learns
/// about the data applies to the other. Each connection is used from one thread at a time.
/// </summary>
public sealed class Database : IDisposable
{
    private readonly SqliteConnection _connection;

    public Database(string path)
    {
        _connection = new SqliteConnection(new SqliteConnectionStringBuilder
        {
            DataSource = path,
            Mode = SqliteOpenMode.ReadWriteCreate,
            Cache = SqliteCacheMode.Private,
            DefaultTimeout = 8,
        }.ToString());
        _connection.Open();
        Exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA busy_timeout=8000;");
    }

    public void Dispose() => _connection.Dispose();

    public void Exec(string sql)
    {
        using var command = _connection.CreateCommand();
        command.CommandText = sql;
        command.ExecuteNonQuery();
    }

    public int Run(string sql, params object?[] parameters)
    {
        using var command = Command(sql, parameters);
        return command.ExecuteNonQuery();
    }

    public long Insert(string sql, params object?[] parameters)
    {
        Run(sql, parameters);
        using var command = _connection.CreateCommand();
        command.CommandText = "SELECT last_insert_rowid()";
        return (long)command.ExecuteScalar()!;
    }

    public IEnumerable<SqliteDataReader> Query(string sql, params object?[] parameters)
    {
        using var command = Command(sql, parameters);
        using var reader = command.ExecuteReader();
        while (reader.Read()) yield return reader;
    }

    public T? Scalar<T>(string sql, params object?[] parameters)
    {
        using var command = Command(sql, parameters);
        var value = command.ExecuteScalar();
        return value is null or DBNull ? default : (T)Convert.ChangeType(value, Nullable.GetUnderlyingType(typeof(T)) ?? typeof(T));
    }

    /// <summary>Runs <paramref name="body"/> in one transaction, rolled back if it throws.</summary>
    public void Transaction(Action body)
    {
        using var transaction = _connection.BeginTransaction();
        body();
        transaction.Commit();
    }

    private SqliteCommand Command(string sql, object?[] parameters)
    {
        var command = _connection.CreateCommand();
        command.CommandText = sql;
        for (var index = 0; index < parameters.Length; index++)
        {
            command.Parameters.AddWithValue("$" + (index + 1), parameters[index] switch
            {
                null => DBNull.Value,
                bool flag => flag ? 1 : 0,
                DateTimeOffset date => date.ToUnixTimeMilliseconds() / 1000.0,
                var value => value,
            });
        }
        return command;
    }
}

public static class Rows
{
    public static string? Text(this SqliteDataReader row, int index) => row.IsDBNull(index) ? null : row.GetString(index);
    public static long Long(this SqliteDataReader row, int index) => row.IsDBNull(index) ? 0 : row.GetInt64(index);
    public static long? OptionalLong(this SqliteDataReader row, int index) => row.IsDBNull(index) ? null : row.GetInt64(index);
    public static double? Double(this SqliteDataReader row, int index) => row.IsDBNull(index) ? null : row.GetDouble(index);
    public static bool Flag(this SqliteDataReader row, int index) => !row.IsDBNull(index) && row.GetInt64(index) != 0;

    public static DateTimeOffset? Date(this SqliteDataReader row, int index) =>
        row.IsDBNull(index) ? null : Time.FromSeconds(row.GetDouble(index));
}

public static class Time
{
    public static DateTimeOffset FromSeconds(double seconds) =>
        DateTimeOffset.FromUnixTimeMilliseconds((long)Math.Round(seconds * 1000)).ToLocalTime();

    public static double Seconds(DateTimeOffset date) => date.ToUnixTimeMilliseconds() / 1000.0;
}

/// <summary>The macOS app's schema, table for table.</summary>
public static class Schema
{
    public const int Version = 2;

    public const string Sql = """
        CREATE TABLE IF NOT EXISTS sessions(
            id TEXT PRIMARY KEY,
            path TEXT NOT NULL,
            cwd TEXT,
            custom_title TEXT,
            ai_title TEXT,
            last_prompt TEXT,
            first_prompt TEXT,
            first_ts REAL,
            last_ts REAL,
            entrypoint TEXT,
            branch TEXT,
            pr_url TEXT,
            pr_number INTEGER,
            msg_count INTEGER NOT NULL DEFAULT 0,
            file_size INTEGER NOT NULL DEFAULT 0,
            file_mtime REAL NOT NULL DEFAULT 0,
            indexed_offset INTEGER NOT NULL DEFAULT 0,
            tok_input INTEGER NOT NULL DEFAULT 0,
            tok_cached INTEGER NOT NULL DEFAULT 0,
            tok_output INTEGER NOT NULL DEFAULT 0,
            context_tokens INTEGER,
            model TEXT
        );
        CREATE VIRTUAL TABLE IF NOT EXISTS messages USING fts5(
            text, session_id UNINDEXED, role UNINDEXED, ts UNINDEXED,
            tokenize='unicode61 remove_diacritics 2'
        );
        CREATE TABLE IF NOT EXISTS cwd_projects(
            cwd TEXT PRIMARY KEY, key TEXT NOT NULL, name TEXT NOT NULL, durable INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS pins(session_id TEXT PRIMARY KEY, position REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS notes(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            text TEXT NOT NULL,
            created REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS tasks(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL,
            text TEXT NOT NULL,
            done INTEGER NOT NULL DEFAULT 0,
            created REAL NOT NULL,
            done_at REAL,
            bucket TEXT,
            due TEXT,
            project_key TEXT,
            position REAL
        );
        CREATE TABLE IF NOT EXISTS project_names(key TEXT PRIMARY KEY, name TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS project_merges(key TEXT PRIMARY KEY, target TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS tags(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL UNIQUE,
            color INTEGER NOT NULL DEFAULT 4
        );
        CREATE TABLE IF NOT EXISTS session_tags(
            session_id TEXT NOT NULL, tag_id INTEGER NOT NULL, PRIMARY KEY(session_id, tag_id)
        );
        CREATE TABLE IF NOT EXISTS organization_names(id TEXT PRIMARY KEY, name TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS time_entries(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            project_key TEXT NOT NULL,
            started REAL NOT NULL,
            ended REAL NOT NULL,
            open INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS project_open(key TEXT PRIMARY KEY, method TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS session_names(session_id TEXT PRIMARY KEY, name TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS session_hosts(session_id TEXT PRIMARY KEY, method TEXT NOT NULL, seen REAL NOT NULL);
        """;

    /// <summary>Opens the database at <paramref name="path"/> with every table in place.</summary>
    public static Database Open(string path)
    {
        var db = new Database(path);
        db.Exec(Sql);
        var current = db.Scalar<long>("PRAGMA user_version");
        if (current < Version)
        {
            // The index only mirrors the transcripts, so it is rebuilt; the user's own data is kept.
            db.Exec($"DELETE FROM sessions; DELETE FROM messages; PRAGMA user_version = {Version};");
        }
        return db;
    }
}
