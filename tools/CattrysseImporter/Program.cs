
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
        if (args.Length < 3 || args.Length > 4)
        {
            Console.Error.WriteLine(
                "Usage: CattrysseImporter <source-dir> <output-dir> <report-dir> [--audit-only]");
            return 2;
        }

        string sourceDir = Path.GetFullPath(args[0]);
        string outputDir = Path.GetFullPath(args[1]);
        string reportDir = Path.GetFullPath(args[2]);

        bool auditOnly =
            args.Length == 4 &&
            string.Equals(
                args[3],
                "--audit-only",
                StringComparison.OrdinalIgnoreCase);

        Directory.CreateDirectory(outputDir);
        Directory.CreateDirectory(reportDir);

        string[] files = Directory
            .EnumerateFiles(sourceDir, "TEST*", SearchOption.AllDirectories)
            .Where(path => Regex.IsMatch(
                Path.GetFileName(path),
                @"^TEST\d+$",
                RegexOptions.IgnoreCase))
            .OrderBy(path => TestNumber(path))
            .ToArray();

        var report = new List<ReportRow>();

        int converted = 0;
        int rejected = 0;

        foreach (string path in files)
        {
            string id =
                Path.GetFileName(path).ToUpperInvariant();

            try
            {
                SourceData data = Reader.Read(path);

                string outputFile = "";

                if (!auditOnly)
                {
                    LotSizingInstance instance =
                        BuildInstance(
                            data,
                            path);

                    outputFile =
                        $"LSDM_CATTRYSSE1990_CLSP_{data.ItemCount}items_{data.PeriodCount}periods_{id}.xml";

                    Serialize(
                        instance,
                        Path.Combine(
                            outputDir,
                            outputFile));

                    converted++;
                }

                report.Add(
                    new ReportRow(
                        id,
                        path,
                        Sha(path),
                        data.ItemCount,
                        data.PeriodCount,
                        data.ClassId,
                        data.CapacityIsStationary,
                        data.MinCapacity,
                        data.MaxCapacity,
                        data.SetupCostMin,
                        data.SetupCostMax,
                        data.HoldingCostMin,
                        data.HoldingCostMax,
                        data.UnitTimeMin,
                        data.UnitTimeMax,
                        auditOnly
                            ? "AUDIT_VALID"
                            : "CONVERTED",
                        outputFile,
                        ""));

                Console.WriteLine(
                    $"OK|{id}|class={data.ClassId}|items={data.ItemCount}|periods={data.PeriodCount}|capacityStationary={data.CapacityIsStationary}|{outputFile}");
            }
            catch (Exception ex)
            {
                rejected++;

                report.Add(
                    new ReportRow(
                        id,
                        path,
                        Sha(path),
                        0,0,"",
                        false,
                        0,0,0,0,0,0,0,0,
                        "REJECTED",
                        "",
                        ex.GetType().Name + ": " + ex.Message));

                Console.WriteLine(
                    $"FAIL|{id}|{ex.GetType().Name}|{ex.Message}");
            }
        }

        string reportPath =
            Path.Combine(
                reportDir,
                "CATTRYSSE-CONVERSION-MANIFEST.csv");

        WriteReport(
            reportPath,
            report);

        Console.WriteLine(
            $"SUMMARY|files={files.Length}|converted={converted}|rejected={rejected}|auditOnly={auditOnly}|report={reportPath}");

        if (files.Length != 120 ||
            rejected != 0)
        {
            return 4;
        }

        if (!auditOnly &&
            converted != 120)
        {
            return 5;
        }

        return 0;
    }

    private static LotSizingInstance BuildInstance(
        SourceData d,
        string sourcePath)
    {
        var builder =
            new SupplyChainModelBuilder(
                d.PeriodCount);

        var warehouse =
            new PlantWarehouse(
                "Cattrysse benchmark plant warehouse");

        var plant =
            new Plant(
                PlantId,
                "Cattrysse benchmark plant",
                warehouse);

        builder.AddPlant(plant);

        var wc =
            new WorkCenter(
                WorkCenterId,
                "Single capacitated resource")
            {
                CapacityConstraint =
                    new CapacityConstraint(
                        d.PeriodCount)
            };

        for (int t = 1;
             t <= d.PeriodCount;
             t++)
        {
            wc.CapacityConstraint
                .SetMaximumCapacity(
                    t,
                    d.Capacity[t - 1]);
        }

        builder.AddWorkCenter(
            PlantId,
            wc);

        builder.AddDistributionCenter(
            new DistributionCenter(
                DistributionCenterId,
                "External demand"));

        for (int j = 1;
             j <= d.ItemCount;
             j++)
        {
            builder.AddItem(
                j,
                "Item " + j,
                0);

            var routing =
                new ProductionRouting(
                    j,
                    j,
                    PlantId,
                    0);

            routing.AddWorkCenter(
                new WorkCenterReference(
                    PlantId,
                    WorkCenterId));

            builder.AddProductionRouting(
                routing);

            var characteristic =
                new ProductionCharacteristic
                {
                    ItemId = j,
                    WorkCenter =
                        new WorkCenterReference(
                            PlantId,
                            WorkCenterId),
                    UnitCapacityConsumption =
                        new UnitCapacityConsumption(
                            d.PeriodCount,
                            d.UnitProductionTime[j - 1]),
                    SetupTime =
                        new SetupTime(
                            d.PeriodCount,
                            0.0),
                    FixedSetupCost =
                        new FixedSetupCost(
                            d.PeriodCount,
                            d.SetupCost[j - 1]),
                    UnitUsageCost =
                        new UnitUsageCost(
                            d.PeriodCount,
                            0.0)
                };

            builder.AddProductionCharacteristic(
                characteristic);

            Inventory inventory =
                Inventory.ForPlantWarehouse(
                    j,
                    PlantId,
                    0.0);

            inventory.UnitUsageCost =
                new UnitUsageCost(
                    d.PeriodCount,
                    d.HoldingCost[j - 1]);

            builder.AddInventory(
                inventory);

            var demand =
                new Demand(
                    j,
                    DistributionCenterId,
                    d.PeriodCount);

            for (int t = 1;
                 t <= d.PeriodCount;
                 t++)
            {
                demand.SetQuantity(
                    t,
                    d.Demand[
                        j - 1,
                        t - 1]);
            }

            builder.AddDemand(
                demand);

            builder.AddDistributionCenterSourcing(
                new DistributionCenterSourcing
                {
                    DistributionCenterId =
                        DistributionCenterId,
                    ItemId = j,
                    Warehouse =
                        WarehouseReference
                            .ForPlantWarehouse(
                                PlantId)
                });
        }

        var chain =
            builder.Build(
                validate: true);

        string id =
            Path.GetFileName(sourcePath)
                .ToUpperInvariant();

        LotSizingInstance instance =
            LotSizingInstanceFactory.Create(
                instanceId:
                    "CATTRYSSE1990-" + id,
                supplyChain: chain,
                name:
                    "Cattrysse-Maes-Van Wassenhove " +
                    id,
                declaredProductStructureType:
                    ProductStructureType.IndependentItems,
                analyzeProductStructure: true,
                classifyProblem: true,
                createdBy:
                    "LotSizingDataModel.Benchmarks CattrysseImporter v0.14.0");

        instance.Description =
            "Single-level multi-item single-resource capacitated dynamic lot-sizing benchmark from the user-provided Cattrysse archive.";

        instance.SourceInformation =
            $"Source archive: Cattrysse.zip. Original nested set: {d.ClassId}. Source file: {id}. SHA256={Sha(sourcePath)}. " +
            "Token contract observed on all 120 originals: item count, period count, item-period demand matrix, period capacity vector, then one item row containing fixed setup cost, unit holding cost, and unit capacity consumption. No setup-time field is present in the source, therefore canonical setup time is zero.";

        instance.Tags.Add(
            "Cattrysse-Maes-Van-Wassenhove");
        instance.Tags.Add(
            "Cattrysse-1990");
        instance.Tags.Add("CLSP");
        instance.Tags.Add("single-level");
        instance.Tags.Add("capacitated");
        instance.Tags.Add("single-resource");
        instance.Tags.Add(d.ClassId);

        return instance;
    }

    private static void Serialize(
        LotSizingInstance instance,
        string path)
    {
        var serializer =
            new XmlSerializer(
                typeof(LotSizingInstance));

        var settings =
            new XmlWriterSettings
            {
                Indent = true,
                IndentChars = "    ",
                Encoding =
                    new UTF8Encoding(false),
                OmitXmlDeclaration =
                    false,
                NewLineHandling =
                    NewLineHandling.Replace
            };

        using XmlWriter writer =
            XmlWriter.Create(
                path,
                settings);

        serializer.Serialize(
            writer,
            instance);
    }

    private static int TestNumber(
        string path)
    {
        Match m =
            Regex.Match(
                Path.GetFileName(path),
                @"(\d+)");

        return m.Success
            ? int.Parse(
                m.Groups[1].Value,
                CultureInfo.InvariantCulture)
            : int.MaxValue;
    }

    private static string Sha(
        string path)
    {
        using var stream =
            File.OpenRead(path);

        using var sha =
            System.Security.Cryptography
                .SHA256.Create();

        return System.Convert
            .ToHexString(
                sha.ComputeHash(stream));
    }

    private static void WriteReport(
        string path,
        IReadOnlyList<ReportRow> rows)
    {
        using var writer =
            new StreamWriter(
                path,
                false,
                new UTF8Encoding(false));

        writer.WriteLine(
            "instance_id,source_path,source_sha256,items,periods,class_id,capacity_stationary,min_capacity,max_capacity,min_setup_cost,max_setup_cost,min_holding_cost,max_holding_cost,min_unit_time,max_unit_time,status,xml_file,diagnostic");

        foreach (ReportRow row in rows)
        {
            writer.WriteLine(
                string.Join(
                    ",",
                    new[]
                    {
                        row.InstanceId,
                        row.SourcePath,
                        row.SourceSha256,
                        row.Items.ToString(CultureInfo.InvariantCulture),
                        row.Periods.ToString(CultureInfo.InvariantCulture),
                        row.ClassId,
                        row.CapacityStationary.ToString(),
                        row.MinCapacity.ToString("R",CultureInfo.InvariantCulture),
                        row.MaxCapacity.ToString("R",CultureInfo.InvariantCulture),
                        row.MinSetupCost.ToString("R",CultureInfo.InvariantCulture),
                        row.MaxSetupCost.ToString("R",CultureInfo.InvariantCulture),
                        row.MinHoldingCost.ToString("R",CultureInfo.InvariantCulture),
                        row.MaxHoldingCost.ToString("R",CultureInfo.InvariantCulture),
                        row.MinUnitTime.ToString("R",CultureInfo.InvariantCulture),
                        row.MaxUnitTime.ToString("R",CultureInfo.InvariantCulture),
                        row.Status,
                        row.XmlFile,
                        row.Diagnostic
                    }.Select(Csv)));
        }
    }

    private static string Csv(
        string value) =>
        "\"" +
        (value ?? "")
            .Replace(
                "\"",
                "\"\"") +
        "\"";
}

internal sealed record ReportRow(
    string InstanceId,
    string SourcePath,
    string SourceSha256,
    int Items,
    int Periods,
    string ClassId,
    bool CapacityStationary,
    double MinCapacity,
    double MaxCapacity,
    double MinSetupCost,
    double MaxSetupCost,
    double MinHoldingCost,
    double MaxHoldingCost,
    double MinUnitTime,
    double MaxUnitTime,
    string Status,
    string XmlFile,
    string Diagnostic);

internal sealed class SourceData
{
    public required int ItemCount { get; init; }
    public required int PeriodCount { get; init; }
    public required double[,] Demand { get; init; }
    public required double[] Capacity { get; init; }
    public required double[] SetupCost { get; init; }
    public required double[] HoldingCost { get; init; }
    public required double[] UnitProductionTime { get; init; }
    public required string ClassId { get; init; }

    public bool CapacityIsStationary =>
        Capacity.All(
            x => Math.Abs(
                x - Capacity[0]) <= 1e-12);

    public double MinCapacity =>
        Capacity.Min();

    public double MaxCapacity =>
        Capacity.Max();

    public double SetupCostMin =>
        SetupCost.Min();

    public double SetupCostMax =>
        SetupCost.Max();

    public double HoldingCostMin =>
        HoldingCost.Min();

    public double HoldingCostMax =>
        HoldingCost.Max();

    public double UnitTimeMin =>
        UnitProductionTime.Min();

    public double UnitTimeMax =>
        UnitProductionTime.Max();
}

internal static class Reader
{
    public static SourceData Read(
        string path)
    {
        string text =
            File.ReadAllText(
                    path,
                    Encoding.Latin1)
                .Replace(
                    "\u001A",
                    " ");

        double[] values =
            Regex.Matches(
                    text,
                    @"[+-]?\d+(?:\.\d*)?")
                .Select(
                    match =>
                        ParseNumber(
                            match.Value))
                .ToArray();

        if (values.Length < 2)
            throw new InvalidDataException(
                "Source file has no dimension header.");

        int items =
            PositiveInt(
                values[0]);

        int periods =
            PositiveInt(
                values[1]);

        int expected =
            2 +
            items * periods +
            periods +
            items * 3;

        if (values.Length != expected)
        {
            throw new InvalidDataException(
                $"Numeric token count mismatch: observed={values.Length}, expected={expected}.");
        }

        int cursor = 2;

        double[,] demand =
            new double[
                items,
                periods];

        for (int j = 0;
             j < items;
             j++)
        {
            for (int t = 0;
                 t < periods;
                 t++)
            {
                demand[j,t] =
                    values[cursor++];
            }
        }

        double[] capacity =
            new double[periods];

        for (int t = 0;
             t < periods;
             t++)
        {
            capacity[t] =
                values[cursor++];
        }

        double[] setupCost =
            new double[items];

        double[] holdingCost =
            new double[items];

        double[] unitTime =
            new double[items];

        for (int j = 0;
             j < items;
             j++)
        {
            setupCost[j] =
                values[cursor++];

            holdingCost[j] =
                values[cursor++];

            unitTime[j] =
                values[cursor++];
        }

        if (cursor != values.Length)
            throw new InvalidDataException(
                "Internal cursor mismatch.");

        ValidateNonNegative(
            demand.Cast<double>()
                .Concat(capacity)
                .Concat(setupCost)
                .Concat(holdingCost)
                .Concat(unitTime));

        string id =
            Path.GetFileName(path)
                .ToUpperInvariant();

        int number =
            int.Parse(
                Regex.Match(
                    id,
                    @"\d+").Value,
                CultureInfo.InvariantCulture);

        string classId =
            number switch
            {
                >= 1 and <= 40 =>
                    "CAT-SET1-50x8",
                >= 41 and <= 80 =>
                    "CAT-SET2-20x20",
                >= 81 and <= 120 =>
                    "CAT-SET3-8x50",
                _ =>
                    throw new InvalidDataException(
                        "Unexpected TEST identifier.")
            };

        if (classId == "CAT-SET1-50x8" &&
            (items != 50 ||
             periods != 8))
        {
            throw new InvalidDataException(
                "Set 1 dimension mismatch.");
        }

        if (classId == "CAT-SET2-20x20" &&
            (items != 20 ||
             periods != 20))
        {
            throw new InvalidDataException(
                "Set 2 dimension mismatch.");
        }

        if (classId == "CAT-SET3-8x50" &&
            (items != 8 ||
             periods != 50))
        {
            throw new InvalidDataException(
                "Set 3 dimension mismatch.");
        }

        return new SourceData
        {
            ItemCount =
                items,
            PeriodCount =
                periods,
            Demand =
                demand,
            Capacity =
                capacity,
            SetupCost =
                setupCost,
            HoldingCost =
                holdingCost,
            UnitProductionTime =
                unitTime,
            ClassId =
                classId
        };
    }

    private static int PositiveInt(
        double value)
    {
        if (!double.IsFinite(value) ||
            value <= 0 ||
            Math.Abs(
                value -
                Math.Round(value)) > 1e-9 ||
            value > int.MaxValue)
        {
            throw new InvalidDataException(
                "Expected positive integer.");
        }

        return checked(
            (int)Math.Round(value));
    }

    private static double ParseNumber(
        string token)
    {
        string normalized =
            token.Trim()
                .TrimEnd('.');

        if (!double.TryParse(
            normalized,
            NumberStyles.Float,
            CultureInfo.InvariantCulture,
            out double value))
        {
            throw new InvalidDataException(
                "Invalid source number: " +
                token);
        }

        return value;
    }

    private static void ValidateNonNegative(
        IEnumerable<double> values)
    {
        foreach (double x in values)
        {
            if (!double.IsFinite(x) ||
                x < 0.0)
            {
                throw new InvalidDataException(
                    "Negative or non-finite source value.");
            }
        }
    }
}
