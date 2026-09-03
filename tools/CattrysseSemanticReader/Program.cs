
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using ExcelDataReader;

internal static class Program
{
    private static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

    private static readonly Dictionary<string,string[]> ReferenceMethods =
        new(StringComparer.OrdinalIgnoreCase)
        {
            ["lot50.xls"] = new[]
            {
                "LV","DS","ABCX","ABCX20","ABCXexp",
                "SC","HEUR1","HEUR2","HEUR3","HEUR4"
            },
            ["lot20b.xls"] = new[]
            {
                "LV","DS","ABCX","ABCX20","ABCXexp",
                "SC","HEUR1","HEUR2","HEUR3","HEUR4"
            },
            ["lot8.xls"] = new[]
            {
                "LV","DS","ABCX","ABCX20","ABCXexp",
                "HEUR2","OPL4"
            }
        };

    private sealed record BestRow(
        string InstanceId,
        string Workbook,
        double BestReportedObjective,
        string ReferenceMethods,
        string AchievingMethods,
        int ObjectiveMethodCount,
        int VerifiedDeviationCells,
        int TimingCells);

    private sealed record LongRow(
        string InstanceId,
        string Workbook,
        string Method,
        double Value,
        int SourceRow,
        int SourceColumn);

    private static int Main(string[] args)
    {
        if (args.Length != 2)
        {
            Console.Error.WriteLine(
                "Usage: CattrysseSemanticReader <workbook-dir> <output-dir>");
            return 2;
        }

        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);

        string workbookDir = Path.GetFullPath(args[0]);
        string outputDir = Path.GetFullPath(args[1]);
        Directory.CreateDirectory(outputDir);

        string[] files = Directory
            .EnumerateFiles(workbookDir, "*.xls", SearchOption.TopDirectoryOnly)
            .OrderBy(p => p, StringComparer.OrdinalIgnoreCase)
            .ToArray();

        var bestRows = new List<BestRow>();
        var objectives = new List<LongRow>();
        var deviations = new List<LongRow>();
        var timings = new List<LongRow>();

        foreach (string path in files)
        {
            string workbookName = Path.GetFileName(path);

            if (!ReferenceMethods.TryGetValue(workbookName, out string[]? referenceMethods))
            {
                throw new InvalidDataException("Unexpected workbook: " + workbookName);
            }

            List<object?[]> rows = ReadFirstSheet(path);
            int headerRow = FindHeaderRow(rows);
            Dictionary<int,string> headers = ReadHeaders(rows[headerRow]);

            var occurrences = new Dictionary<string,List<int>>(
                StringComparer.OrdinalIgnoreCase);

            for (int r = 0; r < rows.Count; r++)
            {
                string id = FindTestId(rows[r]);

                if (id.Length == 0)
                    continue;

                if (!occurrences.TryGetValue(id, out List<int>? list))
                {
                    list = new List<int>();
                    occurrences[id] = list;
                }

                list.Add(r);
            }

            if (occurrences.Count != 40)
            {
                throw new InvalidDataException(
                    workbookName + " must contain 40 TEST identities.");
            }

            foreach (var pair in occurrences)
            {
                string id = pair.Key.ToUpperInvariant();
                int[] rr = pair.Value.OrderBy(x => x).ToArray();

                if (rr.Length != 3)
                {
                    throw new InvalidDataException(
                        id + " must occur exactly three times in " + workbookName);
                }

                int objectiveRow = rr[0];
                int deviationRow = rr[1];
                int timingRow = rr[2];

                var methodValues = new Dictionary<string,double>(
                    StringComparer.OrdinalIgnoreCase);

                foreach (var h in headers)
                {
                    double? value = Numeric(Get(rows[objectiveRow], h.Key));

                    if (value is null)
                        continue;

                    methodValues[h.Value] = value.Value;

                    objectives.Add(
                        new LongRow(
                            id,
                            workbookName,
                            h.Value,
                            value.Value,
                            objectiveRow + 1,
                            h.Key + 1));
                }

                // Historical workbook hidden/reference column: BIFF column 25,
                // i.e. human-readable column 26.
                double? reference = Numeric(Get(rows[objectiveRow], 25));

                if (reference is null)
                {
                    throw new InvalidDataException(
                        id + " has no numeric workbook reference cell.");
                }

                var selected = new List<double>();

                foreach (string method in referenceMethods)
                {
                    if (methodValues.TryGetValue(method, out double value))
                        selected.Add(value);
                }

                if (selected.Count == 0)
                    throw new InvalidDataException(id + " has no reference-method values.");

                double expectedReference = selected.Min();

                if (!Near(expectedReference, reference.Value))
                {
                    throw new InvalidDataException(
                        id + " reference value is not the minimum of the defined reference-method set.");
                }

                string[] achievers = referenceMethods
                    .Where(m =>
                        methodValues.TryGetValue(m, out double v) &&
                        Near(v, reference.Value))
                    .OrderBy(m => m, StringComparer.OrdinalIgnoreCase)
                    .ToArray();

                int verifiedDeviationCells = 0;

                foreach (var h in headers)
                {
                    double? deviation = Numeric(Get(rows[deviationRow], h.Key));

                    if (deviation is null)
                        continue;

                    if (!methodValues.TryGetValue(h.Value, out double objective))
                        continue;

                    double expectedDeviation =
                        objective / reference.Value - 1.0;

                    if (!Near(
                        deviation.Value,
                        expectedDeviation,
                        2e-9))
                    {
                        throw new InvalidDataException(
                            id + " inconsistent deviation for " + h.Value);
                    }

                    verifiedDeviationCells++;

                    deviations.Add(
                        new LongRow(
                            id,
                            workbookName,
                            h.Value,
                            deviation.Value,
                            deviationRow + 1,
                            h.Key + 1));
                }

                int timingCells = 0;

                foreach (var h in headers)
                {
                    double? timing = Numeric(Get(rows[timingRow], h.Key));

                    if (timing is null)
                        continue;

                    timingCells++;

                    timings.Add(
                        new LongRow(
                            id,
                            workbookName,
                            h.Value,
                            timing.Value,
                            timingRow + 1,
                            h.Key + 1));
                }

                bestRows.Add(
                    new BestRow(
                        id,
                        workbookName,
                        reference.Value,
                        string.Join(";", referenceMethods),
                        string.Join(";", achievers),
                        methodValues.Count,
                        verifiedDeviationCells,
                        timingCells));
            }

            Console.WriteLine(
                $"WORKBOOK|{workbookName}|tests={occurrences.Count}|rows={rows.Count}");
        }

        WriteBest(
            Path.Combine(outputDir, "CATTRYSSE-BEST-REPORTED-v0.15.0.csv"),
            bestRows);

        WriteLong(
            Path.Combine(outputDir, "CATTRYSSE-OBJECTIVES-LONG-v0.15.0.csv"),
            objectives,
            "objective_value");

        WriteLong(
            Path.Combine(outputDir, "CATTRYSSE-DEVIATIONS-v0.15.0.csv"),
            deviations,
            "relative_deviation");

        WriteLong(
            Path.Combine(outputDir, "CATTRYSSE-TIMINGS-v0.15.0.csv"),
            timings,
            "reported_time");

        int distinct = bestRows
            .Select(x => x.InstanceId)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Count();

        Console.WriteLine(
            $"SUMMARY|workbooks={files.Length}|bestRows={bestRows.Count}|distinctTests={distinct}|objectiveCells={objectives.Count}|verifiedDeviationCells={deviations.Count}|timingCells={timings.Count}");

        return files.Length == 3 &&
               bestRows.Count == 120 &&
               distinct == 120
            ? 0
            : 4;
    }

    private static List<object?[]> ReadFirstSheet(string path)
    {
        using var stream = File.Open(
            path,
            FileMode.Open,
            FileAccess.Read,
            FileShare.ReadWrite);

        using IExcelDataReader reader =
            ExcelReaderFactory.CreateReader(
                stream,
                new ExcelReaderConfiguration
                {
                    FallbackEncoding = Encoding.GetEncoding(1252),
                    LeaveOpen = false
                });

        var rows = new List<object?[]>();

        while (reader.Read())
        {
            object?[] values = new object?[reader.FieldCount];

            for (int c = 0; c < reader.FieldCount; c++)
                values[c] = reader.GetValue(c);

            rows.Add(values);
        }

        return rows;
    }

    private static int FindHeaderRow(IReadOnlyList<object?[]> rows)
    {
        for (int r = 0; r < Math.Min(rows.Count, 20); r++)
        {
            string joined = string.Join(
                "|",
                rows[r].Select(Text));

            if (joined.Contains("ABCX", StringComparison.OrdinalIgnoreCase) &&
                joined.Contains("LV", StringComparison.OrdinalIgnoreCase) &&
                joined.Contains("DS", StringComparison.OrdinalIgnoreCase))
            {
                return r;
            }
        }

        throw new InvalidDataException("Method header row not found.");
    }

    private static Dictionary<int,string> ReadHeaders(
        IReadOnlyList<object?> row)
    {
        var result = new Dictionary<int,string>();

        for (int c = 0; c < row.Count; c++)
        {
            string text = Text(row[c]);

            if (text.Length == 0 ||
                text == "||" ||
                text == "|||")
            {
                continue;
            }

            result[c] = text;
        }

        return result;
    }

    private static string FindTestId(IReadOnlyList<object?> row)
    {
        foreach (object? value in row)
        {
            Match match = Regex.Match(
                Text(value),
                @"\btest\s*(?<n>\d{1,3})\b",
                RegexOptions.IgnoreCase);

            if (!match.Success)
                continue;

            int n = int.Parse(match.Groups["n"].Value, Inv);
            return "TEST" + n.ToString(Inv);
        }

        return "";
    }

    private static object? Get(
        IReadOnlyList<object?> row,
        int column) =>
        column >= 0 && column < row.Count
            ? row[column]
            : null;

    private static string Text(object? value)
    {
        if (value is null)
            return "";

        return System.Convert
            .ToString(value, Inv)?
            .Trim() ?? "";
    }

    private static double? Numeric(object? value)
    {
        if (value is null)
            return null;

        return value switch
        {
            double d => d,
            float f => f,
            decimal m => (double)m,
            byte b => b,
            sbyte b => b,
            short s => s,
            ushort s => s,
            int i => i,
            uint i => i,
            long l => l,
            ulong ul when ul <= 9007199254740992UL => ul,
            _ => null
        };
    }

    private static bool Near(
        double a,
        double b,
        double tolerance = 1e-7) =>
        Math.Abs(a-b) <= tolerance;

    private static string Csv(string value) =>
        "\"" + (value ?? "").Replace("\"","\"\"") + "\"";

    private static void WriteBest(
        string path,
        IEnumerable<BestRow> rows)
    {
        using var writer = new StreamWriter(
            path,
            false,
            new UTF8Encoding(false));

        writer.WriteLine(
            "instance_id,workbook,best_reported_objective,reference_methods,achieving_methods,objective_method_count,verified_deviation_cells,timing_cells,trust_status,checker_verified,optimality_status,semantic_note");

        foreach (BestRow r in rows)
        {
            writer.WriteLine(
                string.Join(
                    ",",
                    new[]
                    {
                        Csv(r.InstanceId),
                        Csv(r.Workbook),
                        r.BestReportedObjective.ToString("R",Inv),
                        Csv(r.ReferenceMethods),
                        Csv(r.AchievingMethods),
                        r.ObjectiveMethodCount.ToString(Inv),
                        r.VerifiedDeviationCells.ToString(Inv),
                        r.TimingCells.ToString(Inv),
                        Csv("LITERATURE_BEST_REPORTED"),
                        "False",
                        Csv("NOT_PROVEN"),
                        Csv("Workbook reference equals MIN of its defined reference-method set; no complete solution certificate is present.")
                    }));
        }
    }

    private static void WriteLong(
        string path,
        IEnumerable<LongRow> rows,
        string valueHeader)
    {
        using var writer = new StreamWriter(
            path,
            false,
            new UTF8Encoding(false));

        writer.WriteLine(
            "instance_id,workbook,method," +
            valueHeader +
            ",source_row,source_column");

        foreach (LongRow r in rows)
        {
            writer.WriteLine(
                string.Join(
                    ",",
                    new[]
                    {
                        Csv(r.InstanceId),
                        Csv(r.Workbook),
                        Csv(r.Method),
                        r.Value.ToString("R",Inv),
                        r.SourceRow.ToString(Inv),
                        r.SourceColumn.ToString(Inv)
                    }));
        }
    }
}
