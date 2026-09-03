
using System.Globalization;
using System.Text.RegularExpressions;
using NPOI.SS.UserModel;

internal static class Program
{
    private static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
    private static readonly Regex CodeRegex =
        new(@"([GK])\s*([05])\s*([0-4])\s*([12])\s*([1-5])\s*([234])\s*([012])",
            RegexOptions.IgnoreCase | RegexOptions.Compiled);

    private static int Main(string[] args)
    {
        if (args.Length < 2)
        {
            Console.Error.WriteLine("Usage: StadtlerReferenceReader <xls> <output-dir>");
            return 2;
        }

        string input = Path.GetFullPath(args[0]);
        string output = Path.GetFullPath(args[1]);
        Directory.CreateDirectory(output);

        using var fs = File.OpenRead(input);
        IWorkbook wb = WorkbookFactory.Create(fs);

        var audit = new List<string> { "workbook,sheet,row,column,value" };
        var codeCells = new List<CodeCell>();

        for (int s = 0; s < wb.NumberOfSheets; s++)
        {
            ISheet sheet = wb.GetSheetAt(s);
            for (int r = 0; r <= sheet.LastRowNum; r++)
            {
                IRow? row = sheet.GetRow(r);
                if (row is null) continue;

                for (int c = 0; c < row.LastCellNum; c++)
                {
                    string value = CellText(row.GetCell(c)).Trim();
                    if (value.Length == 0) continue;
                    audit.Add(Csv(Path.GetFileName(input), sheet.SheetName,
                        r.ToString(Inv), c.ToString(Inv), value));

                    string code = ExtractCode(value);
                    if (code.Length == 7)
                        codeCells.Add(new CodeCell(s, sheet.SheetName, r, c, code));
                }

                for (int start = 0; start + 6 < row.LastCellNum; start++)
                {
                    string joined = "";
                    bool complete = true;
                    for (int k = 0; k < 7; k++)
                    {
                        string value = CellText(row.GetCell(start + k)).Trim();
                        if (value.Length == 0)
                        {
                            complete = false;
                            break;
                        }
                        joined += value;
                    }
                    if (!complete) continue;

                    string code = ExtractCode(joined);
                    if (code.Length == 7)
                        codeCells.Add(new CodeCell(s, sheet.SheetName, r, start, code));
                }
            }
        }

        File.WriteAllLines(
            Path.Combine(output, Path.GetFileNameWithoutExtension(input) + "-stadtler-audit.csv"),
            audit,
            new System.Text.UTF8Encoding(false));

        codeCells = codeCells
            .GroupBy(x => (x.SheetIndex, x.Row, x.Code))
            .Select(g => g.OrderBy(x => x.Column).First())
            .OrderBy(x => x.SheetIndex)
            .ThenBy(x => x.Row)
            .ToList();

        var resolved = new List<Resolved>();
        var layouts = new List<string>();

        foreach (var sheetGroup in codeCells.GroupBy(x => x.SheetIndex))
        {
            ISheet sheet = wb.GetSheetAt(sheetGroup.Key);
            var patterns = new List<HashSet<int>>();

            foreach (var cc in sheetGroup)
            {
                IRow? row = sheet.GetRow(cc.Row);
                if (row is null) continue;

                var cols = new HashSet<int>();
                for (int c = cc.Column + 1; c < row.LastCellNum; c++)
                    if (Numeric(row.GetCell(c)).HasValue)
                        cols.Add(c);

                if (cols.Count > 0)
                    patterns.Add(cols);

                layouts.Add(Csv(
                    Path.GetFileName(input),
                    cc.SheetName,
                    cc.Row.ToString(Inv),
                    cc.Code,
                    string.Join(";", cols.OrderBy(x => x))));
            }

            if (patterns.Count == 0) continue;

            var common = patterns[0].ToHashSet();
            foreach (var p in patterns.Skip(1))
                common.IntersectWith(p);

            int[] stableCols = common.OrderBy(x => x).ToArray();
            if (stableCols.Length == 0) continue;

            int objectiveCol = stableCols[0];
            int lowerCol = -1;

            if (stableCols.Length >= 2)
            {
                int candidate = stableCols[1];
                bool consistent = true;

                foreach (var cc in sheetGroup)
                {
                    IRow? row = sheet.GetRow(cc.Row);
                    double? obj = row is null ? null : Numeric(row.GetCell(objectiveCol));
                    double? lb = row is null ? null : Numeric(row.GetCell(candidate));

                    if (!obj.HasValue || !lb.HasValue || lb.Value > obj.Value + 1e-8)
                    {
                        consistent = false;
                        break;
                    }
                }

                if (consistent)
                    lowerCol = candidate;
            }

            foreach (var cc in sheetGroup)
            {
                IRow? row = sheet.GetRow(cc.Row);
                if (row is null) continue;

                double? objective = Numeric(row.GetCell(objectiveCol));
                if (!objective.HasValue) continue;

                double? lower = lowerCol >= 0 ? Numeric(row.GetCell(lowerCol)) : null;

                resolved.Add(new Resolved(
                    Path.GetFileName(input),
                    cc.SheetName,
                    cc.Code,
                    objective.Value,
                    lower,
                    $"stable-layout;code-col={cc.Column};objective-col={objectiveCol};lower-col={lowerCol}"));
            }
        }

        var resolvedLines = new List<string>
        {
            "workbook,sheet,source_instance_id,objective,lower_bound,resolution_evidence"
        };

        foreach (var x in resolved
            .GroupBy(x => (x.Workbook, x.Sheet, x.Code))
            .Select(g => g.First()))
        {
            resolvedLines.Add(Csv(
                x.Workbook, x.Sheet, x.Code,
                x.Objective.ToString("R", Inv),
                x.LowerBound?.ToString("R", Inv) ?? "",
                x.Evidence));
        }

        File.WriteAllLines(
            Path.Combine(output, Path.GetFileNameWithoutExtension(input) + "-stadtler-resolved.csv"),
            resolvedLines,
            new System.Text.UTF8Encoding(false));

        File.WriteAllLines(
            Path.Combine(output, Path.GetFileNameWithoutExtension(input) + "-stadtler-code-layout.csv"),
            new[] { "workbook,sheet,row,source_instance_id,numeric_columns_right" }.Concat(layouts),
            new System.Text.UTF8Encoding(false));

        Console.WriteLine(
            $"STADTLER_WORKBOOK|{Path.GetFileName(input)}|sheets={wb.NumberOfSheets}|codes={codeCells.Count}|resolved={resolved.Count}");
        return 0;
    }

    private static string ExtractCode(string value)
    {
        string v = value.ToUpperInvariant();
        var m = CodeRegex.Match(v);

        if (!m.Success)
        {
            string compact = new(v.Where(char.IsLetterOrDigit).ToArray());
            m = CodeRegex.Match(compact);
        }

        if (!m.Success) return "";

        return string.Concat(
            Enumerable.Range(1, 7)
                .Select(i => m.Groups[i].Value.ToUpperInvariant()));
    }

    private static double? Numeric(ICell? cell)
    {
        if (cell is null) return null;
        if (cell.CellType == CellType.Numeric) return cell.NumericCellValue;
        if (cell.CellType == CellType.Formula &&
            cell.CachedFormulaResultType == CellType.Numeric)
            return cell.NumericCellValue;

        string s = CellText(cell).Trim().Replace(',', '.');
        return double.TryParse(s, NumberStyles.Float, Inv, out double value)
            ? value
            : null;
    }

    private static string CellText(ICell? cell)
    {
        if (cell is null) return "";
        return cell.CellType switch
        {
            CellType.String => cell.StringCellValue ?? "",
            CellType.Numeric => cell.NumericCellValue.ToString("R", Inv),
            CellType.Boolean => cell.BooleanCellValue ? "true" : "false",
            CellType.Formula when cell.CachedFormulaResultType == CellType.Numeric =>
                cell.NumericCellValue.ToString("R", Inv),
            _ => cell.ToString() ?? ""
        };
    }

    private static string Csv(params string[] values)
        => string.Join(",", values.Select(v =>
            "\"" + (v ?? "").Replace("\"", "\"\"") + "\""));

    private sealed record CodeCell(int SheetIndex, string SheetName, int Row, int Column, string Code);
    private sealed record Resolved(string Workbook, string Sheet, string Code, double Objective, double? LowerBound, string Evidence);
}
