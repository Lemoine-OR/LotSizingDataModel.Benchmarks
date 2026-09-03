
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using ExcelDataReader;

internal static class Program
{
    private static readonly CultureInfo Inv =
        CultureInfo.InvariantCulture;

    private static int Main(string[] args)
    {
        if (args.Length != 2)
        {
            Console.Error.WriteLine(
                "Usage: CattrysseResultReader <workbook-dir> <output-dir>");
            return 2;
        }

        Encoding.RegisterProvider(
            CodePagesEncodingProvider.Instance);

        string workbookDir =
            Path.GetFullPath(args[0]);

        string outputDir =
            Path.GetFullPath(args[1]);

        Directory.CreateDirectory(
            outputDir);

        string[] files =
            Directory
                .EnumerateFiles(
                    workbookDir,
                    "*.xls",
                    SearchOption.TopDirectoryOnly)
                .OrderBy(
                    p => p,
                    StringComparer.OrdinalIgnoreCase)
                .ToArray();

        var evidence =
            new List<EvidenceRow>();

        var audit =
            new List<string>
            {
                "workbook,sheet,row,column,type,value"
            };

        foreach (string path in files)
        {
            using var stream =
                File.Open(
                    path,
                    FileMode.Open,
                    FileAccess.Read,
                    FileShare.ReadWrite);

            using IExcelDataReader reader =
                ExcelReaderFactory.CreateReader(
                    stream,
                    new ExcelReaderConfiguration
                    {
                        FallbackEncoding =
                            Encoding.GetEncoding(1252),
                        LeaveOpen = false
                    });

            int sheetIndex = 0;

            do
            {
                string sheetName =
                    string.IsNullOrWhiteSpace(reader.Name)
                        ? "Sheet" +
                          (sheetIndex + 1)
                              .ToString(Inv)
                        : reader.Name;

                var rows =
                    new List<object?[]>();

                int rowIndex = 0;

                while (reader.Read())
                {
                    int fieldCount =
                        reader.FieldCount;

                    object?[] values =
                        new object?[fieldCount];

                    for (int c = 0;
                         c < fieldCount;
                         c++)
                    {
                        object? value =
                            reader.GetValue(c);

                        values[c] =
                            value;

                        string text =
                            CellText(value);

                        if (text.Length == 0)
                            continue;

                        audit.Add(
                            Csv(
                                Path.GetFileName(path),
                                sheetName,
                                rowIndex.ToString(Inv),
                                c.ToString(Inv),
                                value?.GetType().Name ?? "",
                                text));
                    }

                    rows.Add(values);
                    rowIndex++;
                }

                Dictionary<int,string> headers =
                    BuildColumnHeaders(rows);

                for (int r = 0;
                     r < rows.Count;
                     r++)
                {
                    object?[] row =
                        rows[r];

                    string testId =
                        FindTestId(row);

                    if (testId.Length == 0)
                        continue;

                    for (int c = 0;
                         c < row.Length;
                         c++)
                    {
                        double? numeric =
                            CellNumeric(row[c]);

                        if (numeric is null)
                            continue;

                        string header =
                            headers.TryGetValue(
                                c,
                                out string? h)
                                ? h
                                : "";

                        evidence.Add(
                            new EvidenceRow(
                                Path.GetFileName(path),
                                sheetName,
                                testId,
                                r,
                                c,
                                header,
                                numeric.Value,
                                "LITERATURE_WORKBOOK_RESULT_CELL"));
                    }
                }

                Console.WriteLine(
                    $"SHEET|{Path.GetFileName(path)}|{sheetName}|rows={rows.Count}");

                sheetIndex++;
            }
            while (reader.NextResult());

            Console.WriteLine(
                $"WORKBOOK|{Path.GetFileName(path)}|sheets={sheetIndex}");
        }

        File.WriteAllLines(
            Path.Combine(
                outputDir,
                "CATTRYSSE-WORKBOOK-AUDIT.csv"),
            audit,
            new UTF8Encoding(false));

        var lines =
            new List<string>
            {
                "workbook,sheet,instance_id,row,column,column_header,numeric_value,evidence_status"
            };

        foreach (EvidenceRow row in evidence)
        {
            lines.Add(
                Csv(
                    row.Workbook,
                    row.Sheet,
                    row.InstanceId,
                    row.Row.ToString(Inv),
                    row.Column.ToString(Inv),
                    row.ColumnHeader,
                    row.NumericValue
                        .ToString("R",Inv),
                    row.EvidenceStatus));
        }

        File.WriteAllLines(
            Path.Combine(
                outputDir,
                "CATTRYSSE-RESULT-EVIDENCE.csv"),
            lines,
            new UTF8Encoding(false));

        string[] distinctTests =
            evidence
                .Select(x => x.InstanceId)
                .Distinct(
                    StringComparer.OrdinalIgnoreCase)
                .OrderBy(TestNumber)
                .ToArray();

        string range =
            distinctTests.Length == 0
                ? ""
                : distinctTests[0] +
                  ".." +
                  distinctTests[^1];

        Console.WriteLine(
            $"SUMMARY|workbooks={files.Length}|evidenceCells={evidence.Count}|distinctTests={distinctTests.Length}|range={range}");

        if (files.Length != 3)
            return 4;

        if (distinctTests.Length != 120)
            return 5;

        int[] numbers =
            distinctTests
                .Select(TestNumber)
                .ToArray();

        if (!numbers.SequenceEqual(
                Enumerable.Range(1,120)))
        {
            Console.Error.WriteLine(
                "TEST identity set is not exactly TEST1..TEST120.");
            return 6;
        }

        return 0;
    }

    private static Dictionary<int,string>
        BuildColumnHeaders(
            IReadOnlyList<object?[]> rows)
    {
        var headers =
            new Dictionary<int,string>();

        int maxRow =
            Math.Min(
                rows.Count,
                30);

        for (int r = 0;
             r < maxRow;
             r++)
        {
            object?[] row =
                rows[r];

            for (int c = 0;
                 c < row.Length;
                 c++)
            {
                object? value =
                    row[c];

                if (value is not string)
                    continue;

                string text =
                    CellText(value);

                if (text.Length == 0)
                    continue;

                if (Regex.IsMatch(
                    text,
                    @"^\s*test\s*\d+\s*$",
                    RegexOptions.IgnoreCase))
                {
                    continue;
                }

                headers[c] =
                    text;
            }
        }

        return headers;
    }

    private static string FindTestId(
        IReadOnlyList<object?> row)
    {
        foreach (object? value in row)
        {
            string text =
                CellText(value);

            Match match =
                Regex.Match(
                    text,
                    @"\btest\s*(?<n>\d{1,3})\b",
                    RegexOptions.IgnoreCase);

            if (!match.Success)
                continue;

            int n =
                int.Parse(
                    match.Groups["n"].Value,
                    Inv);

            return "TEST" +
                n.ToString(Inv);
        }

        return "";
    }

    private static int TestNumber(
        string testId)
    {
        Match match =
            Regex.Match(
                testId,
                @"\d+");

        return match.Success
            ? int.Parse(
                match.Value,
                Inv)
            : int.MaxValue;
    }

    private static double? CellNumeric(
        object? value)
    {
        if (value is null)
            return null;

        switch (value)
        {
            case double d:
                return d;

            case float f:
                return f;

            case decimal m:
                return (double)m;

            case byte b:
                return b;

            case sbyte sb:
                return sb;

            case short s:
                return s;

            case ushort us:
                return us;

            case int i:
                return i;

            case uint ui:
                return ui;

            case long l:
                return l;

            case ulong ul
                when ul <=
                     9007199254740992UL:
                return ul;

            default:
                return null;
        }
    }

    private static string CellText(
        object? value)
    {
        if (value is null)
            return "";

        return value switch
        {
            DateTime date =>
                date.ToString(
                    "O",
                    Inv),

            double d =>
                d.ToString(
                    "R",
                    Inv),

            float f =>
                f.ToString(
                    "R",
                    Inv),

            decimal m =>
                m.ToString(
                    Inv),

            bool b =>
                b
                    ? "true"
                    : "false",

            _ =>
                System.Convert
                    .ToString(
                        value,
                        Inv)?
                    .Trim() ?? ""
        };
    }

    private static string Csv(
        params string[] values) =>
        string.Join(
            ",",
            values.Select(
                v =>
                    "\"" +
                    (v ?? "")
                        .Replace(
                            "\"",
                            "\"\"") +
                    "\""));

    private sealed record EvidenceRow(
        string Workbook,
        string Sheet,
        string InstanceId,
        int Row,
        int Column,
        string ColumnHeader,
        double NumericValue,
        string EvidenceStatus);
}
