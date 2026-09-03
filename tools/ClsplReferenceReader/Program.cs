
using System.Globalization;
using NPOI.SS.UserModel;

internal static class Program
{
    private static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

    private static int Main(string[] args)
    {
        if (args.Length < 2)
        {
            Console.Error.WriteLine("Usage: ClsplReferenceReader <xls-file> <output-directory>");
            return 2;
        }

        string input = Path.GetFullPath(args[0]);
        string output = Path.GetFullPath(args[1]);
        Directory.CreateDirectory(output);

        using var stream = File.OpenRead(input);
        IWorkbook wb = WorkbookFactory.Create(stream);

        var audit = new List<string>
        {
            "workbook,sheet,row,column,type,value"
        };

        var extracted = new List<Record>();
        bool anyResolved = false;

        for (int s = 0; s < wb.NumberOfSheets; s++)
        {
            ISheet sheet = wb.GetSheetAt(s);
            var header = DetectHeader(sheet);

            for (int r = 0; r <= sheet.LastRowNum; r++)
            {
                IRow? row = sheet.GetRow(r);
                if (row is null) continue;

                for (int c = 0; c < row.LastCellNum; c++)
                {
                    ICell? cell = row.GetCell(c);
                    if (cell is null) continue;
                    string value = CellText(cell);
                    if (value.Length == 0) continue;

                    audit.Add(Csv(
                        Path.GetFileName(input),
                        sheet.SheetName,
                        r.ToString(Inv),
                        c.ToString(Inv),
                        cell.CellType.ToString(),
                        value));
                }
            }

            if (header is null)
                continue;

            anyResolved = true;
            for (int r = header.RowIndex + 1; r <= sheet.LastRowNum; r++)
            {
                IRow? row = sheet.GetRow(r);
                if (row is null) continue;

                string id = GetText(row, header.InstanceColumn);
                if (string.IsNullOrWhiteSpace(id)) continue;

                double? objective = GetNumeric(row, header.ObjectiveColumn);
                double? lowerBound = header.LowerBoundColumn >= 0
                    ? GetNumeric(row, header.LowerBoundColumn)
                    : null;

                if (objective is null && lowerBound is null)
                    continue;

                extracted.Add(new Record(
                    Path.GetFileName(input),
                    sheet.SheetName,
                    id.Trim(),
                    objective,
                    lowerBound,
                    header.HeaderDescription));
            }
        }

        File.WriteAllLines(
            Path.Combine(output, Path.GetFileNameWithoutExtension(input) + "-workbook-audit.csv"),
            audit,
            new System.Text.UTF8Encoding(false));

        string outCsv = Path.Combine(
            output,
            Path.GetFileNameWithoutExtension(input) + "-resolved-references.csv");

        var lines = new List<string>
        {
            "workbook,sheet,source_instance_id,objective,lower_bound,resolution_evidence"
        };

        foreach (var x in extracted)
        {
            lines.Add(Csv(
                x.Workbook,
                x.Sheet,
                x.InstanceId,
                x.Objective?.ToString("R", Inv) ?? "",
                x.LowerBound?.ToString("R", Inv) ?? "",
                x.Evidence));
        }

        File.WriteAllLines(outCsv, lines, new System.Text.UTF8Encoding(false));

        Console.WriteLine($"WORKBOOK|{Path.GetFileName(input)}|sheets={wb.NumberOfSheets}|resolvedRows={extracted.Count}|headerResolved={anyResolved}");
        return 0;
    }

    private static Header? DetectHeader(ISheet sheet)
    {
        int maxRow = Math.Min(sheet.LastRowNum, 30);

        for (int r = 0; r <= maxRow; r++)
        {
            IRow? row = sheet.GetRow(r);
            if (row is null) continue;

            int instance = -1;
            int objective = -1;
            int lower = -1;
            var tokens = new List<string>();

            for (int c = 0; c < row.LastCellNum; c++)
            {
                string text = GetText(row, c).Trim();
                if (text.Length == 0) continue;

                string n = Normalize(text);
                tokens.Add($"{c}:{text}");

                if (instance < 0 &&
                    (n.Contains("instance") || n.Contains("problem") ||
                     n.Contains("name") || n.Contains("file") ||
                     n == "id" || n.Contains("bezeichnung")))
                    instance = c;

                if (objective < 0 &&
                    (n.Contains("objective") || n.Contains("best") ||
                     n.Contains("upperbound") || n == "ub" ||
                     n.Contains("zielfunktion") || n.Contains("zielwert") ||
                     n.Contains("solutionvalue")))
                    objective = c;

                if (lower < 0 &&
                    (n.Contains("lowerbound") || n == "lb" ||
                     n.Contains("untere") || n.Contains("bound")))
                {
                    if (!(n.Contains("upper") || n == "ub"))
                        lower = c;
                }
            }

            if (instance >= 0 && objective >= 0)
            {
                return new Header(
                    r,
                    instance,
                    objective,
                    lower,
                    string.Join(" | ", tokens));
            }
        }

        return null;
    }

    private static string Normalize(string value)
    {
        string x = value.ToLowerInvariant();
        x = new string(x.Where(char.IsLetterOrDigit).ToArray());
        return x;
    }

    private static string GetText(IRow row, int col)
    {
        if (col < 0) return "";
        ICell? cell = row.GetCell(col);
        return cell is null ? "" : CellText(cell);
    }

    private static double? GetNumeric(IRow row, int col)
    {
        if (col < 0) return null;
        ICell? cell = row.GetCell(col);
        if (cell is null) return null;

        if (cell.CellType == CellType.Numeric)
            return cell.NumericCellValue;

        string text = CellText(cell).Trim().Replace(',', '.');
        if (double.TryParse(text, NumberStyles.Float, Inv, out double v))
            return v;

        return null;
    }

    private static string CellText(ICell cell)
    {
        return cell.CellType switch
        {
            CellType.String => cell.StringCellValue?.Trim() ?? "",
            CellType.Numeric => cell.NumericCellValue.ToString("R", Inv),
            CellType.Boolean => cell.BooleanCellValue ? "true" : "false",
            CellType.Formula => FormulaText(cell),
            _ => cell.ToString()?.Trim() ?? ""
        };
    }

    private static string FormulaText(ICell cell)
    {
        try
        {
            return cell.CachedFormulaResultType switch
            {
                CellType.Numeric => cell.NumericCellValue.ToString("R", Inv),
                CellType.String => cell.StringCellValue?.Trim() ?? "",
                _ => cell.ToString()?.Trim() ?? ""
            };
        }
        catch
        {
            return cell.ToString()?.Trim() ?? "";
        }
    }

    private static string Csv(params string[] values)
    {
        return string.Join(",", values.Select(v =>
            "\"" + (v ?? "").Replace("\"", "\"\"") + "\""));
    }

    private sealed record Header(
        int RowIndex,
        int InstanceColumn,
        int ObjectiveColumn,
        int LowerBoundColumn,
        string HeaderDescription);

    private sealed record Record(
        string Workbook,
        string Sheet,
        string InstanceId,
        double? Objective,
        double? LowerBound,
        string Evidence);
}
