
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
        if (args.Length < 2 || args.Length > 3)
        {
            Console.Error.WriteLine(
                "Usage: TrigeiroImporter <input-dir> <output-dir> [manifest.csv]");
            return 2;
        }

        string inputDirectory = Path.GetFullPath(args[0]);
        string outputDirectory = Path.GetFullPath(args[1]);
        string manifestPath = args.Length == 3
            ? Path.GetFullPath(args[2])
            : Path.Combine(outputDirectory, "TRIGEIRO-CONVERSION-MANIFEST.csv");

        if (!Directory.Exists(inputDirectory))
        {
            Console.Error.WriteLine("Input directory not found: " + inputDirectory);
            return 3;
        }

        Directory.CreateDirectory(outputDirectory);
        Directory.CreateDirectory(Path.GetDirectoryName(manifestPath)!);

        string[] sourceFiles = Directory
            .EnumerateFiles(inputDirectory, "*.*", SearchOption.AllDirectories)
            .Where(path =>
                string.Equals(Path.GetExtension(path), ".dat", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(Path.GetExtension(path), ".txt", StringComparison.OrdinalIgnoreCase))
            .OrderBy(path => path, StringComparer.OrdinalIgnoreCase)
            .ToArray();

        var manifest = new List<ManifestRow>();
        var successfulHashes = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        int converted = 0;
        int rejected = 0;
        int duplicate = 0;

        foreach (string sourceFile in sourceFiles)
        {
            string sha256 = ComputeSha256(sourceFile);

            if (!successfulHashes.Add(sha256))
            {
                duplicate++;
                manifest.Add(new ManifestRow(
                    SourcePath: sourceFile,
                    SourceFile: Path.GetFileName(sourceFile),
                    Sha256: sha256,
                    Status: "DUPLICATE_SOURCE_CONTENT",
                    Items: 0,
                    Periods: 0,
                    Capacity: 0,
                    OutputFile: "",
                    Diagnostic: "Same raw content as an already accepted/rejected source."));
                continue;
            }

            try
            {
                if (!TrigeiroReader.TryRead(sourceFile, out TrigeiroData? data, out string diagnostic) ||
                    data is null)
                {
                    rejected++;
                    manifest.Add(new ManifestRow(
                        SourcePath: sourceFile,
                        SourceFile: Path.GetFileName(sourceFile),
                        Sha256: sha256,
                        Status: "REJECTED_NOT_TRIGEIRO_CONTRACT",
                        Items: 0,
                        Periods: 0,
                        Capacity: 0,
                        OutputFile: "",
                        Diagnostic: diagnostic));
                    continue;
                }

                LotSizingInstance instance = Convert(data, sourceFile, sha256);

                string sourceId = Path.GetFileNameWithoutExtension(sourceFile).ToUpperInvariant();
                string outputFileName =
                    $"LSDM_TRIGEIRO1989_CLSP_{data.ItemCount}items_{data.PeriodCount}periods_{sourceId}.xml";

                string outputPath = Path.Combine(outputDirectory, outputFileName);

                Serialize(instance, outputPath);

                converted++;

                manifest.Add(new ManifestRow(
                    SourcePath: sourceFile,
                    SourceFile: Path.GetFileName(sourceFile),
                    Sha256: sha256,
                    Status: "CONVERTED",
                    Items: data.ItemCount,
                    Periods: data.PeriodCount,
                    Capacity: data.Capacity,
                    OutputFile: outputFileName,
                    Diagnostic: data.ParserDiagnostic));

                Console.WriteLine(
                    $"OK|{Path.GetFileName(sourceFile)}|items={data.ItemCount}|periods={data.PeriodCount}|capacity={data.Capacity}|{outputFileName}");
            }
            catch (Exception ex)
            {
                rejected++;

                manifest.Add(new ManifestRow(
                    SourcePath: sourceFile,
                    SourceFile: Path.GetFileName(sourceFile),
                    Sha256: sha256,
                    Status: "REJECTED_CONVERSION_FAILURE",
                    Items: 0,
                    Periods: 0,
                    Capacity: 0,
                    OutputFile: "",
                    Diagnostic: $"{ex.GetType().Name}: {ex.Message}"));

                Console.WriteLine(
                    $"FAIL|{Path.GetFileName(sourceFile)}|{ex.GetType().Name}|{ex.Message}");
            }
        }

        WriteManifest(manifestPath, manifest);

        Console.WriteLine(
            $"SUMMARY|files={sourceFiles.Length}|converted={converted}|rejected={rejected}|duplicates={duplicate}|manifest={manifestPath}");

        return converted > 0 ? 0 : 4;
    }

    private static LotSizingInstance Convert(
        TrigeiroData data,
        string sourceFile,
        string sourceSha256)
    {
        var builder = new SupplyChainModelBuilder(data.PeriodCount);

        var plantWarehouse = new PlantWarehouse(
            "Trigeiro 1989 plant warehouse");

        var plant = new Plant(
            PlantId,
            "Trigeiro 1989 synthetic single plant",
            plantWarehouse);

        var workCenter = new WorkCenter(
            WorkCenterId,
            "Trigeiro 1989 single capacitated machine")
        {
            CapacityConstraint = new CapacityConstraint(
                data.PeriodCount,
                data.Capacity)
        };

        builder
            .AddPlant(plant)
            .AddWorkCenter(PlantId, workCenter)
            .AddDistributionCenter(
                new DistributionCenter(
                    DistributionCenterId,
                    "Trigeiro 1989 external demand"));

        for (int i = 0; i < data.ItemCount; i++)
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
                    data.PeriodCount,
                    data.UnitProductionTime[i]),
                SetupTime = new SetupTime(
                    data.PeriodCount,
                    data.SetupTime[i]),
                FixedSetupCost = new FixedSetupCost(
                    data.PeriodCount,
                    data.SetupCost[i]),
                UnitUsageCost = new UnitUsageCost(
                    data.PeriodCount,
                    0.0)
            };

            builder.AddProductionCharacteristic(characteristic);

            Inventory inventory = Inventory.ForPlantWarehouse(
                itemId,
                PlantId,
                initialInventory: 0.0);

            inventory.UnitUsageCost = new UnitUsageCost(
                data.PeriodCount,
                data.HoldingCost[i]);

            builder.AddInventory(inventory);

            var demand = new Demand(
                itemId,
                DistributionCenterId,
                planningHorizon: data.PeriodCount);

            for (int t = 1; t <= data.PeriodCount; t++)
            {
                demand.SetQuantity(t, data.Demand[i, t - 1]);
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

        string sourceName =
            Path.GetFileNameWithoutExtension(sourceFile).ToUpperInvariant();

        LotSizingInstance instance = LotSizingInstanceFactory.Create(
            instanceId: $"TRIGEIRO1989-{sourceName}",
            supplyChain: supplyChain,
            name: $"Trigeiro et al. (1989) {sourceName}",
            declaredProductStructureType: ProductStructureType.IndependentItems,
            analyzeProductStructure: true,
            classifyProblem: true,
            createdBy: "LotSizingDataModel.Benchmarks TrigeiroImporter v0.9.0");

        instance.Description =
            "Single-machine multi-item capacitated lot-sizing instance " +
            "with setup times from the Trigeiro, Thomas and McClain (1989) benchmark family.";

        instance.SourceInformation =
            "Source family: Trigeiro et al. (1989). " +
            $"Raw file: {Path.GetFileName(sourceFile)}. " +
            $"SHA256: {sourceSha256}. " +
            "Raw contract reconstructed from the public gsamaro/trigeiro_fdata reader: " +
            "item count, period count, scalar regular capacity, item unit production time, " +
            "holding cost, setup time, setup cost, and item-period demand.";

        instance.Tags.Add("Trigeiro-1989");
        instance.Tags.Add("CLSP");
        instance.Tags.Add("capacitated");
        instance.Tags.Add("setup-times");
        instance.Tags.Add("single-level");
        instance.Tags.Add("single-machine");
        instance.Tags.Add("raw-source-preserved");

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

    private static string ComputeSha256(string path)
    {
        using var stream = File.OpenRead(path);
        using var sha = System.Security.Cryptography.SHA256.Create();
        return System.Convert.ToHexString(sha.ComputeHash(stream));
    }

    private static void WriteManifest(
        string path,
        IReadOnlyList<ManifestRow> rows)
    {
        using var writer = new StreamWriter(
            path,
            false,
            new UTF8Encoding(false));

        writer.WriteLine(
            "source_path,source_file,sha256,status,items,periods,capacity,output_file,diagnostic");

        foreach (ManifestRow row in rows)
        {
            writer.WriteLine(Csv(
                row.SourcePath,
                row.SourceFile,
                row.Sha256,
                row.Status,
                row.Items.ToString(CultureInfo.InvariantCulture),
                row.Periods.ToString(CultureInfo.InvariantCulture),
                row.Capacity.ToString(CultureInfo.InvariantCulture),
                row.OutputFile,
                row.Diagnostic));
        }
    }

    private static string Csv(params string[] values) =>
        string.Join(
            ",",
            values.Select(value =>
                "\"" + (value ?? "").Replace("\"", "\"\"") + "\""));

    private sealed record ManifestRow(
        string SourcePath,
        string SourceFile,
        string Sha256,
        string Status,
        int Items,
        int Periods,
        double Capacity,
        string OutputFile,
        string Diagnostic);
}

internal sealed class TrigeiroData
{
    public required int ItemCount { get; init; }
    public required int PeriodCount { get; init; }
    public required double Capacity { get; init; }
    public required double[] UnitProductionTime { get; init; }
    public required double[] HoldingCost { get; init; }
    public required double[] SetupTime { get; init; }
    public required double[] SetupCost { get; init; }
    public required double[,] Demand { get; init; }
    public required string ParserDiagnostic { get; init; }
}

internal static class TrigeiroReader
{
    public static bool TryRead(
        string path,
        out TrigeiroData? data,
        out string diagnostic)
    {
        data = null;
        diagnostic = "";

        string[] lines;

        try
        {
            lines = File.ReadAllLines(path);
        }
        catch (Exception ex)
        {
            diagnostic = "Could not read source: " + ex.Message;
            return false;
        }

        List<double[]> numericRows = new();

        foreach (string line in lines)
        {
            string trimmed = line.Trim();

            if (trimmed.Length == 0)
                continue;

            string[] tokens = Regex
                .Split(trimmed, @"\s+")
                .Where(token => token.Length > 0)
                .ToArray();

            var values = new List<double>();
            bool allNumeric = true;

            foreach (string token in tokens)
            {
                if (!double.TryParse(
                        token,
                        NumberStyles.Float,
                        CultureInfo.InvariantCulture,
                        out double value))
                {
                    allNumeric = false;
                    break;
                }

                values.Add(value);
            }

            if (allNumeric && values.Count > 0)
                numericRows.Add(values.ToArray());
        }

        if (numericRows.Count < 5)
        {
            diagnostic = "Too few numeric rows.";
            return false;
        }

        if (numericRows[0].Length < 2)
        {
            diagnostic = "First numeric row does not contain item and period counts.";
            return false;
        }

        int itemCount = CheckedPositiveInt(numericRows[0][0], "item count");
        int periodCount = CheckedPositiveInt(numericRows[0][1], "period count");

        // Public reference reader contract:
        // numeric row 0: item count, period count
        // numeric row 1: legacy/single-machine marker (ignored by original reader)
        // numeric row 2: scalar regular capacity
        // next itemCount rows: unit production time, holding cost, setup time, setup cost
        // remaining numeric rows: demand matrix stored period-major, possibly split horizontally
        if (numericRows.Count < 3 + itemCount + periodCount)
        {
            diagnostic =
                $"Numeric contract too short for n={itemCount}, T={periodCount}.";
            return false;
        }

        if (numericRows[2].Length < 1)
        {
            diagnostic = "Capacity row is missing.";
            return false;
        }

        double capacity = numericRows[2][0];

        if (!double.IsFinite(capacity) || capacity <= 0)
        {
            diagnostic = "Capacity is not strictly positive finite.";
            return false;
        }

        double[] vt = new double[itemCount];
        double[] hc = new double[itemCount];
        double[] st = new double[itemCount];
        double[] sc = new double[itemCount];

        int itemStart = 3;

        for (int i = 0; i < itemCount; i++)
        {
            double[] row = numericRows[itemStart + i];

            if (row.Length < 4)
            {
                diagnostic =
                    $"Item row {i + 1} has fewer than four numeric fields.";
                return false;
            }

            vt[i] = row[0];
            hc[i] = row[1];
            st[i] = row[2];
            sc[i] = row[3];

            if (!AllFiniteNonNegative(vt[i], hc[i], st[i], sc[i]))
            {
                diagnostic =
                    $"Item row {i + 1} contains negative or non-finite parameters.";
                return false;
            }
        }

        int demandStart = itemStart + itemCount;

        List<double[]> demandRows = numericRows
            .Skip(demandStart)
            .ToList();

        if (demandRows.Count < periodCount)
        {
            diagnostic = "Not enough demand rows.";
            return false;
        }

        var periodVectors = new List<double[]>();

        // Standard small-instance layout: T rows with N values.
        if (itemCount <= 15)
        {
            for (int t = 0; t < periodCount; t++)
            {
                double[] row = demandRows[t];

                if (row.Length < itemCount)
                {
                    diagnostic =
                        $"Demand row {t + 1} contains {row.Length}, expected at least {itemCount}.";
                    return false;
                }

                periodVectors.Add(row.Take(itemCount).ToArray());
            }
        }
        else
        {
            // Public Python reader documents the large layout as two T-row
            // horizontal blocks. Reconstruct each period by concatenation.
            if (demandRows.Count < periodCount * 2)
            {
                diagnostic =
                    "Large-instance demand layout requires two period blocks.";
                return false;
            }

            for (int t = 0; t < periodCount; t++)
            {
                double[] left = demandRows[t];
                double[] right = demandRows[periodCount + t];

                double[] combined = left
                    .Concat(right)
                    .Take(itemCount)
                    .ToArray();

                if (combined.Length != itemCount)
                {
                    diagnostic =
                        $"Large demand period {t + 1} reconstructed {combined.Length}, expected {itemCount}.";
                    return false;
                }

                periodVectors.Add(combined);
            }
        }

        double[,] demand = new double[itemCount, periodCount];

        for (int t = 0; t < periodCount; t++)
        {
            for (int i = 0; i < itemCount; i++)
            {
                double value = periodVectors[t][i];

                if (!double.IsFinite(value) || value < 0)
                {
                    diagnostic =
                        $"Demand[{i + 1},{t + 1}] is negative or non-finite.";
                    return false;
                }

                demand[i, t] = value;
            }
        }

        data = new TrigeiroData
        {
            ItemCount = itemCount,
            PeriodCount = periodCount,
            Capacity = capacity,
            UnitProductionTime = vt,
            HoldingCost = hc,
            SetupTime = st,
            SetupCost = sc,
            Demand = demand,
            ParserDiagnostic =
                $"Validated public Trigeiro contract: n={itemCount}, T={periodCount}, capacity={capacity.ToString(CultureInfo.InvariantCulture)}."
        };

        diagnostic = data.ParserDiagnostic;
        return true;
    }

    private static int CheckedPositiveInt(
        double value,
        string label)
    {
        if (!double.IsFinite(value) ||
            value <= 0 ||
            Math.Abs(value - Math.Round(value)) > 1e-9 ||
            value > int.MaxValue)
        {
            throw new InvalidDataException(
                $"{label} is not a strictly positive integer.");
        }

        return checked((int)Math.Round(value));
    }

    private static bool AllFiniteNonNegative(
        params double[] values) =>
        values.All(value =>
            double.IsFinite(value) &&
            value >= 0.0);
}
