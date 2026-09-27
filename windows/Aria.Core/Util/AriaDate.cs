using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Aria.Core.Util;

/// <summary>
/// Date parsing/formatting identical to AriaKit's <c>AriaDate</c> (Swift): lenient RFC 3339
/// parsing (any fraction precision, Z / ±HH:MM / ±HHMM / ±HH, 'T' or space, optional
/// seconds, bare dates), UTC output with milliseconds for Supabase, and local output with
/// an explicit offset for the language model.
/// </summary>
public static class AriaDate
{
    public static DateTimeOffset? ParseTimestamp(string? text, TimeZoneInfo? defaultZone = null)
    {
        if (text is null) return null;
        var s = text.Trim();
        var i = 0;

        int? Digits(int count)
        {
            if (i + count > s.Length) return null;
            var value = 0;
            for (var k = 0; k < count; k++)
            {
                var c = s[i + k];
                if (c < '0' || c > '9') return null;
                value = value * 10 + (c - '0');
            }
            i += count;
            return value;
        }

        bool Consume(char c)
        {
            if (i >= s.Length || s[i] != c) return false;
            i++;
            return true;
        }

        if (Digits(4) is not int year || !Consume('-') || Digits(2) is not int month || !Consume('-') || Digits(2) is not int day)
            return null;
        int hour = 0, minute = 0, second = 0;
        long ticks = 0;
        int? offsetMinutes = null;

        if (i < s.Length)
        {
            var sep = s[i];
            if (sep != 'T' && sep != 't' && sep != ' ') return null;
            i++;
            if (Digits(2) is not int h || !Consume(':') || Digits(2) is not int m) return null;
            hour = h;
            minute = m;
            if (Consume(':'))
            {
                if (Digits(2) is not int sec) return null;
                second = sec;
            }
            if (i < s.Length && (s[i] == '.' || s[i] == ','))
            {
                i++;
                var count = 0;
                long fraction = 0;
                while (i < s.Length && s[i] >= '0' && s[i] <= '9')
                {
                    if (count < 7)
                    {
                        fraction = fraction * 10 + (s[i] - '0');
                        count++;
                    }
                    i++;
                }
                if (count == 0) return null;
                for (var k = count; k < 7; k++) fraction *= 10;
                ticks = fraction; // 100 ns units
            }
            if (i < s.Length)
            {
                var marker = s[i];
                if (marker == 'Z' || marker == 'z')
                {
                    offsetMinutes = 0;
                    i++;
                }
                else if (marker == '+' || marker == '-')
                {
                    var sign = marker == '-' ? -1 : 1;
                    i++;
                    if (Digits(2) is not int oh) return null;
                    var om = 0;
                    if (i < s.Length)
                    {
                        Consume(':');
                        if (Digits(2) is not int parsed) return null;
                        om = parsed;
                    }
                    if (oh > 23 || om > 59) return null;
                    offsetMinutes = sign * (oh * 60 + om);
                }
                else
                {
                    return null;
                }
            }
            if (i != s.Length) return null;
        }

        if (month is < 1 or > 12 || day < 1 || hour > 23 || minute > 59 || second > 60) return null;
        if (day > DateTime.DaysInMonth(year, month) || year < 1) return null;
        second = Math.Min(second, 59);
        var wallClock = new DateTime(year, month, day, hour, minute, second, DateTimeKind.Unspecified).AddTicks(ticks);

        if (offsetMinutes is int offset)
            return new DateTimeOffset(wallClock, TimeSpan.FromMinutes(offset));
        var zone = defaultZone ?? TimeZoneInfo.Local;
        return FromLocal(wallClock, zone);
    }

    /// <summary>Wall-clock time in <paramref name="zone"/> to an instant (DST gaps move forward).</summary>
    public static DateTimeOffset FromLocal(DateTime wallClock, TimeZoneInfo zone)
    {
        var unspecified = DateTime.SpecifyKind(wallClock, DateTimeKind.Unspecified);
        while (zone.IsInvalidTime(unspecified)) unspecified = unspecified.AddMinutes(30);
        var offset = zone.GetUtcOffset(unspecified);
        return new DateTimeOffset(unspecified, offset);
    }

    /// <summary>UTC with millisecond precision, e.g. <c>2026-09-27T06:58:28.594Z</c>.</summary>
    public static string FormatUtc(DateTimeOffset value) =>
        value.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);

    /// <summary>Local wall-clock time with offset, e.g. <c>2026-10-02T17:00:00-04:00</c>.</summary>
    public static string FormatLocal(DateTimeOffset value, TimeZoneInfo zone)
    {
        var local = TimeZoneInfo.ConvertTime(value, zone);
        var offset = local.Offset;
        var sign = offset < TimeSpan.Zero ? "-" : "+";
        var abs = offset.Duration();
        return local.ToString("yyyy-MM-dd'T'HH:mm:ss", CultureInfo.InvariantCulture) + $"{sign}{abs.Hours:D2}:{abs.Minutes:D2}";
    }

    /// <summary><c>Friday, 2 October 2026 17:00</c> (for the system prompt).</summary>
    public static string FormatReadable(DateTimeOffset value, TimeZoneInfo zone, bool includeTime = true)
    {
        var local = TimeZoneInfo.ConvertTime(value, zone);
        return local.ToString(includeTime ? "dddd, d MMMM yyyy HH:mm" : "dddd, d MMMM yyyy", CultureInfo.InvariantCulture);
    }

    /// <summary>The IANA name of a zone when available ("America/New_York" rather than "Eastern Standard Time").</summary>
    public static string ZoneName(TimeZoneInfo zone)
    {
        if (zone.Id.Contains('/')) return zone.Id;
        return TimeZoneInfo.TryConvertWindowsIdToIanaId(zone.Id, out var iana) ? iana : zone.Id;
    }
}

/// <summary>
/// A calendar day (<c>yyyy-MM-dd</c>), independent of time zone: <c>planner_days.date</c>,
/// tool-call date ranges and all-day events use this.
/// </summary>
[JsonConverter(typeof(DayKeyJsonConverter))]
public readonly record struct DayKey(int Year, int Month, int Day) : IComparable<DayKey>
{
    private static readonly DateOnly Epoch = new(1970, 1, 1);

    public static DayKey? Parse(string? text)
    {
        if (text is null) return null;
        var trimmed = text.Trim();
        if (trimmed.Length < 10) return null;
        if (trimmed.Length > 10 && trimmed[10] is not ('T' or 't' or ' ')) return null;
        var datePart = trimmed[..10];
        if (datePart[4] != '-' || datePart[7] != '-') return null;
        if (!int.TryParse(datePart[..4], NumberStyles.None, CultureInfo.InvariantCulture, out var y) ||
            !int.TryParse(datePart.AsSpan(5, 2), NumberStyles.None, CultureInfo.InvariantCulture, out var m) ||
            !int.TryParse(datePart.AsSpan(8, 2), NumberStyles.None, CultureInfo.InvariantCulture, out var d)) return null;
        if (y < 1 || m is < 1 or > 12 || d < 1 || d > DateTime.DaysInMonth(y, m)) return null;
        return new DayKey(y, m, d);
    }

    public static DayKey From(DateOnly date) => new(date.Year, date.Month, date.Day);

    /// <summary>The day <paramref name="instant"/> falls on in <paramref name="zone"/>.</summary>
    public static DayKey From(DateTimeOffset instant, TimeZoneInfo zone)
    {
        var local = TimeZoneInfo.ConvertTime(instant, zone);
        return new DayKey(local.Year, local.Month, local.Day);
    }

    /// <summary>The day <paramref name="instant"/> falls on in UTC (all-day events are stored as UTC midnights).</summary>
    public static DayKey FromUtc(DateTimeOffset instant)
    {
        var utc = instant.UtcDateTime;
        return new DayKey(utc.Year, utc.Month, utc.Day);
    }

    public DateOnly Date => new(Year, Month, Day);
    public int DaysSinceEpoch => Date.DayNumber - Epoch.DayNumber;
    public DayKey AddDays(int days) => From(Date.AddDays(days));

    /// <summary>Midnight at the start of this day in <paramref name="zone"/>.</summary>
    public DateTimeOffset StartIn(TimeZoneInfo zone) => AriaDate.FromLocal(new DateTime(Year, Month, Day), zone);

    /// <summary>[start of this day, start of the next day) in <paramref name="zone"/>.</summary>
    public DateRange RangeIn(TimeZoneInfo zone) => new(StartIn(zone), AddDays(1).StartIn(zone));

    public DateTimeOffset UtcMidnight => new(Year, Month, Day, 0, 0, 0, TimeSpan.Zero);

    public int CompareTo(DayKey other) => DaysSinceEpoch.CompareTo(other.DaysSinceEpoch);
    public static bool operator <(DayKey a, DayKey b) => a.CompareTo(b) < 0;
    public static bool operator >(DayKey a, DayKey b) => a.CompareTo(b) > 0;
    public static bool operator <=(DayKey a, DayKey b) => a.CompareTo(b) <= 0;
    public static bool operator >=(DayKey a, DayKey b) => a.CompareTo(b) >= 0;
    public static DayKey Max(DayKey a, DayKey b) => a >= b ? a : b;

    public override string ToString() => $"{Year:D4}-{Month:D2}-{Day:D2}";
}

/// <summary>A half-open span of time [Start, End).</summary>
public readonly record struct DateRange(DateTimeOffset Start, DateTimeOffset End)
{
    public bool Contains(DateTimeOffset instant) => Start <= instant && instant < End;
    public TimeSpan Duration => End - Start;
}

public sealed class DayKeyJsonConverter : JsonConverter<DayKey>
{
    public override DayKey Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        DayKey.Parse(reader.GetString()) ?? throw new JsonException($"Invalid date '{reader.GetString()}'");

    public override void Write(Utf8JsonWriter writer, DayKey value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value.ToString());
}

/// <summary>Writes timestamps as UTC RFC 3339 (milliseconds) and reads them leniently.</summary>
public sealed class TimestampJsonConverter : JsonConverter<DateTimeOffset>
{
    public override DateTimeOffset Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        var text = reader.GetString();
        return AriaDate.ParseTimestamp(text, TimeZoneInfo.Utc) ?? throw new JsonException($"Invalid timestamp '{text}'");
    }

    public override void Write(Utf8JsonWriter writer, DateTimeOffset value, JsonSerializerOptions options) =>
        writer.WriteStringValue(AriaDate.FormatUtc(value));
}
