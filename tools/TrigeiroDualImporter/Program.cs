
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using System.Xml;
using System.Xml.Serialization;

using LotSizingDataModel.Core.Building;
using LotSizingDataModel.Core.DecisionModel.Constraints;
using LotSizingDataModel.Core.DecisionModel.Costs;
using LotSizingDataModel.Core.LogicalModel;
using LotSizingDataModel.Core.PhysicalModel;
using LotSizingDataModel.Core.Relationships;
using LotSizingDataModel.Instance;
using LotSizingDataModel.Instance.Common;
using LotSizingDataModel.Instance.Creation;

internal static class Program
{
    private const int PlantId = 1;
    private const int WorkCenterId = 1;
    private const int DistributionCenterId = 1;

    private static int Main(string[] args)
    {
        if (args.Length != 3)
        {
            Console.Error.WriteLine(
                "Usage: TrigeiroDualImporter <source-dir> <output-dir> <report-dir>");
            return 2;
        }

        string sourceDir = Path.GetFullPath(args[0]);
        string outputDir = Path.GetFullPath(args[1]);
        string reportDir = Path.GetFullPath(args[2]);

        Directory.CreateDirectory(outputDir);
        Directory.CreateDirectory(reportDir);

        string[] datFiles = Directory
            .EnumerateFiles(sourceDir, "*.dat", SearchOption.AllDirectories)
            .OrderBy(p => p, StringComparer.OrdinalIgnoreCase)
            .ToArray();

        string[] trigFiles = Directory
            .EnumerateFiles(sourceDir, "*.trig", SearchOption.AllDirectories)
            .OrderBy(p => p, StringComparer.OrdinalIgnoreCase)
            .ToArray();

        var datById = datFiles.ToDictionary(
            p => Path.GetFileNameWithoutExtension(p),
            StringComparer.OrdinalIgnoreCase);

        var trigById = trigFiles.ToDictionary(
            p => Path.GetFileNameWithoutExtension(p),
            StringComparer.OrdinalIgnoreCase);

        string[] ids = datById.Keys
            .Union(trigById.Keys, StringComparer.OrdinalIgnoreCase)
            .OrderBy(id => id, NaturalIdComparer.Instance)
            .ToArray();

        var report = new List<ReconciliationRow>();
        int converted = 0;
        int rejected = 0;

        foreach (string id in ids)
        {
            if (!datById.TryGetValue(id, out string? datPath))
            {
                rejected++;
                report.Add(ReconciliationRow.Missing(id, "MISSING_DAT"));
                continue;
            }

            if (!trigById.TryGetValue(id, out string? trigPath))
            {
                rejected++;
                report.Add(ReconciliationRow.Missing(id, "MISSING_TRIG"));
                continue;
            }

            try
            {
                DatData dat = DatReader.Read(datPath);
                TrigData trig = TrigReader.Read(trigPath);

                ReconciliationResult rec = Reconciler.Compare(dat, trig);

                if (!rec.Accepted)
                {
                    rejected++;
                    report.Add(new ReconciliationRow(
                        id,
                        datPath,
                        trigPath,
                        Sha(datPath),
                        Sha(trigPath),
                        dat.ItemCount,
                        dat.PeriodCount,
                        rec.Status,
                        rec.Diagnostic,
                        "",
                        ""));
                    Console.WriteLine(
                        $"REJECT|{id}|{rec.Status}|{rec.Diagnostic}");
                    continue;
                }

                LotSizingInstance instance = BuildInstance(
                    id,
                    datPath,
                    trigPath,
                    dat,
                    trig,
                    rec);

                string fileName =
                    $"LSDM_TRIGEIRO1989_CLSP_{dat.ItemCount}items_{dat.PeriodCount}periods_{id}.xml";

                string outputPath = Path.Combine(outputDir, fileName);
                Serialize(instance, outputPath);

                converted++;

                report.Add(new ReconciliationRow(
                    id,
                    datPath,
                    trigPath,
                    Sha(datPath),
                    Sha(trigPath),
                    dat.ItemCount,
                    dat.PeriodCount,
                    rec.Status,
                    rec.Diagnostic,
                    fileName,
                    Sha(outputPath)));

                Console.WriteLine(
                    $"OK|{id}|items={dat.ItemCount}|periods={dat.PeriodCount}|{rec.Status}|{fileName}");
            }
            catch (Exception ex)
            {
                rejected++;
                report.Add(new ReconciliationRow(
                    id,
                    datPath,
                    trigPath,
                    Sha(datPath),
                    Sha(trigPath),
                    0,
                    0,
                    "EXCEPTION",
                    ex.GetType().Name + ": " + ex.Message,
                    "",
                    ""));
                Console.WriteLine(
                    $"FAIL|{id}|{ex.GetType().Name}|{ex.Message}");
            }
        }

        string reportPath = Path.Combine(
            reportDir,
            "TRIGEIRO-DUAL-RECONCILIATION.csv");

        WriteReport(reportPath, report);

        Console.WriteLine(
            $"SUMMARY|ids={ids.Length}|dat={datFiles.Length}|trig={trigFiles.Length}|converted={converted}|rejected={rejected}|report={reportPath}");

        return rejected == 0 && converted == ids.Length ? 0 : 4;
    }

    private static LotSizingInstance BuildInstance(
        string id,
        string datPath,
        string trigPath,
        DatData dat,
        TrigData trig,
        ReconciliationResult rec)
    {
        var builder = new SupplyChainModelBuilder(dat.PeriodCount);

        var plantWarehouse = new PlantWarehouse(
            "Trigeiro 1989 plant warehouse");

        var plant = new Plant(
            PlantId,
            "Trigeiro 1989 single plant",
            plantWarehouse);

        var workCenter = new WorkCenter(
            WorkCenterId,
            "Trigeiro 1989 single capacitated machine")
        {
            CapacityConstraint = new CapacityConstraint(
                dat.PeriodCount,
                dat.Capacity)
        };

        builder
            .AddPlant(plant)
            .AddWorkCenter(PlantId, workCenter)
            .AddDistributionCenter(
                new DistributionCenter(
                    DistributionCenterId,
                    "Trigeiro 1989 external demand"));

        for (int i = 0; i < dat.ItemCount; i++)
        {
            int itemId = i + 1;

            builder.AddItem(
                itemId,
                $"Trigeiro item {itemId}",
                billOfMaterialsLevel: 0);

            var routing = new ProductionRouting
            {
                Id = itemId,
                ItemId = itemId,
                PlantId = PlantId,
                LeadTime = 0
            };

            routing.WorkCenters.Add(
                new WorkCenterReference
                {
                    PlantId = PlantId,
                    WorkCenterId = WorkCenterId
                });

            builder.AddProductionRouting(routing);

            var characteristic = new ProductionCharacteristic
            {
                ItemId = itemId,
                WorkCenter = new WorkCenterReference
                {
                    PlantId = PlantId,
                    WorkCenterId = WorkCenterId
                },
                UnitCapacityConsumption = new UnitCapacityConsumption(
                    dat.PeriodCount,
                    dat.UnitProductionTime[i]),
                SetupTime = new SetupTime(
                    dat.PeriodCount,
                    trig.SetupTime[i]),
                FixedSetupCost = new FixedSetupCost(
                    dat.PeriodCount,
                    dat.SetupCost[i]),
                UnitUsageCost = new UnitUsageCost(
                    dat.PeriodCount,
                    dat.ProductionCost[i])
            };

            builder.AddProductionCharacteristic(characteristic);

            Inventory inventory = Inventory.ForPlantWarehouse(
                itemId,
                PlantId,
                initialInventory: 0.0);

            inventory.UnitUsageCost = new UnitUsageCost(
                dat.PeriodCount,
                dat.HoldingCost[i]);

            builder.AddInventory(inventory);

            var demand = new Demand(
                itemId,
                DistributionCenterId,
                planningHorizon: dat.PeriodCount);

            for (int t = 1; t <= dat.PeriodCount; t++)
            {
                demand.SetQuantity(t, dat.Demand[i, t - 1]);
            }

            builder.AddDemand(demand);

            builder.AddDistributionCenterSourcing(
                new DistributionCenterSourcing
                {
                    DistributionCenterId = DistributionCenterId,
                    ItemId = itemId,
                    Warehouse = WarehouseReference.ForPlantWarehouse(
                        PlantId)
                });
        }

        var supplyChain = builder.Build(validate: true);

        LotSizingInstance instance = LotSizingInstanceFactory.Create(
            instanceId: $"TRIGEIRO1989-{id.ToUpperInvariant()}",
            supplyChain: supplyChain,
            name: $"Trigeiro et al. (1989) {id.ToUpperInvariant()}",
            declaredProductStructureType: ProductStructureType.IndependentItems,
            analyzeProductStructure: true,
            classifyProblem: true,
            createdBy: "LotSizingDataModel.Benchmarks TrigeiroDualImporter v0.10.0");

        instance.Description =
            "Dual-format reconciled Trigeiro benchmark instance. " +
            "DAT and TRIG representations agree on dimensions, demand, capacity, " +
            "unit production times, holding costs and setup costs. " +
            "The DAT representation systematically stores zero setup-time fields; " +
            "TRIG is therefore the canonical source for setup times.";

        instance.SourceInformation =
            $"User-provided E1.zip dual representation. DAT={Path.GetFileName(datPath)} " +
            $"SHA256={Sha(datPath)}; TRIG={Path.GetFileName(trigPath)} " +
            $"SHA256={Sha(trigPath)}; reconciliation={rec.Status}.";

        instance.Tags.Add("Trigeiro-1989");
        instance.Tags.Add("CLSP");
        instance.Tags.Add("capacitated");
        instance.Tags.Add("setup-times");
        instance.Tags.Add("single-level");
        instance.Tags.Add("single-machine");
        instance.Tags.Add("dual-format-reconciled");
        instance.Tags.Add(rec.Status);

        return instance;
    }

    private static void Serialize(
        LotSizingInstance instance,
        string outputPath)
    {
        var serializer = new XmlSerializer(typeof(LotSizingInstance));

        var settings = new XmlWriterSettings
        {
            Indent = true,
            IndentChars = "    ",
            Encoding = new UTF8Encoding(false),
            OmitXmlDeclaration = false,
            NewLineHandling = NewLineHandling.Replace
        };

        using XmlWriter writer = XmlWriter.Create(outputPath, settings);
        serializer.Serialize(writer, instance);
    }

    private static string Sha(string path)
    {
        using var stream = File.OpenRead(path);
        using var sha = System.Security.Cryptography.SHA256.Create();
        return System.Convert.ToHexString(sha.ComputeHash(stream));
    }

    private static void WriteReport(
        string path,
        IReadOnlyList<ReconciliationRow> rows)
    {
        using var writer = new StreamWriter(
            path,
            false,
            new UTF8Encoding(false));

        writer.WriteLine(
            "instance_id,dat_path,trig_path,dat_sha256,trig_sha256,items,periods,status,diagnostic,xml_file,xml_sha256");

        foreach (ReconciliationRow row in rows)
        {
            writer.WriteLine(
                string.Join(
                    ",",
                    new[]
                    {
                        row.InstanceId,
                        row.DatPath,
                        row.TrigPath,
                        row.DatSha256,
                        row.TrigSha256,
                        row.Items.ToString(CultureInfo.InvariantCulture),
                        row.Periods.ToString(CultureInfo.InvariantCulture),
                        row.Status,
                        row.Diagnostic,
                        row.XmlFile,
                        row.XmlSha256
                    }.Select(Csv)));
        }
    }

    private static string Csv(string value) =>
        "\"" + (value ?? "").Replace("\"", "\"\"") + "\"";
}

internal sealed record ReconciliationRow(
    string InstanceId,
    string DatPath,
    string TrigPath,
    string DatSha256,
    string TrigSha256,
    int Items,
    int Periods,
    string Status,
    string Diagnostic,
    string XmlFile,
    string XmlSha256)
{
    public static ReconciliationRow Missing(
        string id,
        string status) =>
        new(
            id,
            "",
            "",
            "",
            "",
            0,
            0,
            status,
            "Dual-format pair is incomplete.",
            "",
            "");
}

internal sealed record ReconciliationResult(
    bool Accepted,
    string Status,
    string Diagnostic);

internal static class Reconciler
{
    public static ReconciliationResult Compare(
        DatData dat,
        TrigData trig)
    {
        if (dat.ItemCount != trig.ItemCount ||
            dat.PeriodCount != trig.PeriodCount)
        {
            return Reject("DIMENSION_MISMATCH");
        }

        if (!Near(dat.Capacity, trig.Capacity))
        {
            return Reject("CAPACITY_MISMATCH");
        }

        for (int i = 0; i < dat.ItemCount; i++)
        {
            if (!Near(dat.UnitProductionTime[i], trig.UnitProductionTime[i]))
                return Reject($"UNIT_TIME_MISMATCH item={i + 1}");

            if (!Near(dat.HoldingCost[i], trig.HoldingCost[i]))
                return Reject($"HOLDING_COST_MISMATCH item={i + 1}");

            if (!Near(dat.SetupCost[i], trig.SetupCost[i]))
                return Reject($"SETUP_COST_MISMATCH item={i + 1}");

            for (int t = 0; t < dat.PeriodCount; t++)
            {
                if (!Near(dat.Demand[i, t], trig.Demand[i, t]))
                {
                    return Reject(
                        $"DEMAND_MISMATCH item={i + 1} period={t + 1} dat={dat.Demand[i,t]} trig={trig.Demand[i,t]}");
                }
            }
        }

        bool datSetupAllZero = dat.SetupTime.All(v => Near(v, 0.0));
        bool setupEqual = true;

        for (int i = 0; i < dat.ItemCount; i++)
        {
            if (!Near(dat.SetupTime[i], trig.SetupTime[i]))
            {
                setupEqual = false;
                break;
            }
        }

        if (setupEqual)
        {
            return new ReconciliationResult(
                true,
                "DUAL_FORMAT_EXACT",
                "DAT and TRIG agree on all canonical fields.");
        }

        if (datSetupAllZero)
        {
            return new ReconciliationResult(
                true,
                "DUAL_FORMAT_RECONCILED_DAT_SETUP_TIME_LOSS",
                "All DAT setup-time fields are zero while shared fields match TRIG; TRIG setup time is retained canonically.");
        }

        return Reject("SETUP_TIME_MISMATCH_NOT_SYSTEMATIC_ZERO_LOSS");
    }

    private static ReconciliationResult Reject(
        string diagnostic) =>
        new(false, "DUAL_FORMAT_REJECTED", diagnostic);

    private static bool Near(
        double a,
        double b) =>
        Math.Abs(a - b) <= 1e-9;
}

internal sealed class DatData
{
    public required int ItemCount { get; init; }
    public required int PeriodCount { get; init; }
    public required double[,] Demand { get; init; }
    public required double[] SetupCost { get; init; }
    public required double[] HoldingCost { get; init; }
    public required double[] ProductionCost { get; init; }
    public required double Capacity { get; init; }
    public required double[] UnitProductionTime { get; init; }
    public required double[] SetupTime { get; init; }
}

internal static class DatReader
{
    public static DatData Read(string path)
    {
        string[] lines = File.ReadAllLines(
            path,
            Encoding.Latin1);

        var values = new Dictionary<string,string>(
            StringComparer.OrdinalIgnoreCase);

        foreach (string line in lines)
        {
            int eq = line.IndexOf('=');

            if (eq <= 0)
                continue;

            string key = line[..eq].Trim();
            string value = line[(eq + 1)..].Trim();
            values[key] = value;
        }

        int periods = PositiveInt(
            Require(values,"NB_PERIODES"));

        int items = PositiveInt(
            Require(values,"NB_PRODUITS"));

        double[,] demand = new double[items, periods];

        for (int i = 0; i < items; i++)
        {
            double[] row = ParseVector(
                Require(values,$"Demande{i + 1}"));

            if (row.Length != periods)
            {
                throw new InvalidDataException(
                    $"DAT demand length mismatch for item {i + 1}: {row.Length} vs {periods}.");
            }

            for (int t = 0; t < periods; t++)
            {
                demand[i,t] = row[t];
            }
        }

        double[] setupCost = new double[items];
        double[] holding = new double[items];
        double[] production = new double[items];
        double[] unitTime = new double[items];
        double[] setupTime = new double[items];

        for (int i = 0; i < items; i++)
        {
            int k = i + 1;

            setupCost[i] = Number(
                Require(values,$"CL_Produit{k}"));

            holding[i] = Number(
                Require(values,$"CS_Produit{k}"));

            production[i] = Number(
                Require(values,$"CP_Produit{k}"));

            unitTime[i] = Number(
                Require(values,$"C_t_p_Produit{k}"));

            setupTime[i] = Number(
                Require(values,$"C_t_l_Produit{k}"));
        }

        double[] capacityVector = ParseVector(
            Require(values,"Capacite_machine"));

        if (capacityVector.Length != periods)
        {
            throw new InvalidDataException(
                $"DAT capacity vector length {capacityVector.Length} vs periods {periods}.");
        }

        double capacity = capacityVector[0];

        if (capacityVector.Any(v => Math.Abs(v - capacity) > 1e-9))
        {
            throw new InvalidDataException(
                "DAT capacity is not stationary; current Trigeiro contract expects scalar capacity.");
        }

        ValidateNonNegative(
            demand.Cast<double>()
                .Concat(setupCost)
                .Concat(holding)
                .Concat(production)
                .Concat(unitTime)
                .Concat(setupTime)
                .Append(capacity));

        return new DatData
        {
            ItemCount = items,
            PeriodCount = periods,
            Demand = demand,
            SetupCost = setupCost,
            HoldingCost = holding,
            ProductionCost = production,
            Capacity = capacity,
            UnitProductionTime = unitTime,
            SetupTime = setupTime
        };
    }

    private static string Require(
        IReadOnlyDictionary<string,string> values,
        string key)
    {
        if (!values.TryGetValue(key,out string? value))
            throw new InvalidDataException("DAT missing key: " + key);

        return value;
    }

    private static double[] ParseVector(string value) =>
        Regex.Split(value.Trim(),@"\s+")
            .Where(s => s.Length > 0)
            .Select(Number)
            .ToArray();

    private static int PositiveInt(string value)
    {
        double x = Number(value);

        if (x <= 0 ||
            Math.Abs(x - Math.Round(x)) > 1e-9 ||
            x > int.MaxValue)
        {
            throw new InvalidDataException(
                "Expected positive integer: " + value);
        }

        return checked((int)Math.Round(x));
    }

    private static double Number(string value)
    {
        string normalized = value.Trim().Replace(',','.');

        if (!double.TryParse(
            normalized,
            NumberStyles.Float,
            CultureInfo.InvariantCulture,
            out double result))
        {
            throw new InvalidDataException(
                "Invalid DAT number: " + value);
        }

        return result;
    }

    private static void ValidateNonNegative(
        IEnumerable<double> values)
    {
        foreach (double value in values)
        {
            if (!double.IsFinite(value) || value < 0)
                throw new InvalidDataException(
                    "DAT contains negative or non-finite data.");
        }
    }
}

internal sealed class TrigData
{
    public required int ItemCount { get; init; }
    public required int PeriodCount { get; init; }
    public required double Capacity { get; init; }
    public required double[] UnitProductionTime { get; init; }
    public required double[] HoldingCost { get; init; }
    public required double[] SetupTime { get; init; }
    public required double[] SetupCost { get; init; }
    public required double[,] Demand { get; init; }
}

internal static class TrigReader
{
    private static readonly Regex ItemRegex = new(
        @"^\s*(?<ut>[+-]?\d+(?:[.,]\d+)?)\s+" +
        @"(?<hc>[+-]?\d+(?:[.,]\d+)?)\s+" +
        @"(?<st>[+-]?\d+\.)\s*" +
        @"(?<sc>[+-]?\d+\.)\s*$",
        RegexOptions.Compiled);

    public static TrigData Read(string path)
    {
        string[] lines = File.ReadAllLines(
            path,
            Encoding.Latin1);

        int cursor = 0;

        string dimensionsLine = NextNonEmpty(lines,ref cursor);
        int[] dimensions = Integers(dimensionsLine);

        if (dimensions.Length < 2)
            throw new InvalidDataException("TRIG dimensions missing.");

        int items = dimensions[0];
        int periods = dimensions[1];

        _ = NextNonEmpty(lines,ref cursor); // machine marker
        string capacityLine = NextNonEmpty(lines,ref cursor);
        double capacity = Number(capacityLine);

        double[] unitTime = new double[items];
        double[] holding = new double[items];
        double[] setupTime = new double[items];
        double[] setupCost = new double[items];

        for (int i = 0; i < items; i++)
        {
            string line = NextNonEmpty(lines,ref cursor);
            Match match = ItemRegex.Match(line);

            if (!match.Success)
            {
                throw new InvalidDataException(
                    $"TRIG item row {i + 1} does not match fixed contract: '{line}'.");
            }

            unitTime[i] = Number(match.Groups["ut"].Value);
            holding[i] = Number(match.Groups["hc"].Value);
            setupTime[i] = Number(match.Groups["st"].Value);
            setupCost[i] = Number(match.Groups["sc"].Value);
        }

        var numericDemandRows = new List<int[]>();

        while (cursor < lines.Length)
        {
            string line = lines[cursor++];

            if (string.IsNullOrWhiteSpace(line))
                continue;

            // Footer such as "Bi hi su su" terminates demand data.
            if (Regex.IsMatch(line,@"[A-Za-z]"))
                break;

            int[] values = Integers(line);

            if (values.Length > 0)
                numericDemandRows.Add(values);
        }

        int blockWidth = Math.Min(15,items);
        int blocks = (int)Math.Ceiling(items / 15.0);
        int expectedRows = periods * blocks;

        if (numericDemandRows.Count < expectedRows)
        {
            throw new InvalidDataException(
                $"TRIG demand rows {numericDemandRows.Count}, expected at least {expectedRows}.");
        }

        double[,] demand = new double[items,periods];

        for (int t = 0; t < periods; t++)
        {
            int offset = 0;

            for (int b = 0; b < blocks; b++)
            {
                int[] row = numericDemandRows[b * periods + t];
                int required = Math.Min(15,items - offset);

                if (row.Length < required)
                {
                    throw new InvalidDataException(
                        $"TRIG demand block {b + 1}, period {t + 1} contains {row.Length}, expected {required}.");
                }

                for (int j = 0; j < required; j++)
                {
                    demand[offset + j,t] = row[j];
                }

                offset += required;
            }
        }

        ValidateNonNegative(
            demand.Cast<double>()
                .Concat(unitTime)
                .Concat(holding)
                .Concat(setupTime)
                .Concat(setupCost)
                .Append(capacity));

        return new TrigData
        {
            ItemCount = items,
            PeriodCount = periods,
            Capacity = capacity,
            UnitProductionTime = unitTime,
            HoldingCost = holding,
            SetupTime = setupTime,
            SetupCost = setupCost,
            Demand = demand
        };
    }

    private static string NextNonEmpty(
        string[] lines,
        ref int cursor)
    {
        while (cursor < lines.Length)
        {
            string line = lines[cursor++];

            if (!string.IsNullOrWhiteSpace(line))
                return line;
        }

        throw new EndOfStreamException(
            "Unexpected end of TRIG file.");
    }

    private static int[] Integers(string line) =>
        Regex.Matches(line,@"[+-]?\d+")
            .Select(m => int.Parse(
                m.Value,
                CultureInfo.InvariantCulture))
            .ToArray();

    private static double Number(string value)
    {
        string normalized = value
            .Trim()
            .TrimEnd('.')
            .Replace(',','.');

        if (!double.TryParse(
            normalized,
            NumberStyles.Float,
            CultureInfo.InvariantCulture,
            out double result))
        {
            throw new InvalidDataException(
                "Invalid TRIG number: " + value);
        }

        return result;
    }

    private static void ValidateNonNegative(
        IEnumerable<double> values)
    {
        foreach (double value in values)
        {
            if (!double.IsFinite(value) || value < 0)
                throw new InvalidDataException(
                    "TRIG contains negative or non-finite data.");
        }
    }
}

internal sealed class NaturalIdComparer : IComparer<string>
{
    public static readonly NaturalIdComparer Instance = new();

    public int Compare(string? x,string? y)
    {
        if (ReferenceEquals(x,y)) return 0;
        if (x is null) return -1;
        if (y is null) return 1;

        Match mx = Regex.Match(x,@"^(?<p>[A-Za-z]+)(?<n>\d+)(?<s>.*)$");
        Match my = Regex.Match(y,@"^(?<p>[A-Za-z]+)(?<n>\d+)(?<s>.*)$");

        if (mx.Success && my.Success)
        {
            int p = string.Compare(
                mx.Groups["p"].Value,
                my.Groups["p"].Value,
                StringComparison.OrdinalIgnoreCase);

            if (p != 0) return p;

            int nx = int.Parse(mx.Groups["n"].Value,CultureInfo.InvariantCulture);
            int ny = int.Parse(my.Groups["n"].Value,CultureInfo.InvariantCulture);

            int n = nx.CompareTo(ny);
            if (n != 0) return n;

            return string.Compare(
                mx.Groups["s"].Value,
                my.Groups["s"].Value,
                StringComparison.OrdinalIgnoreCase);
        }

        return string.Compare(
            x,y,StringComparison.OrdinalIgnoreCase);
    }
}
