
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
        if (args.Length != 4)
        {
            Console.Error.WriteLine(
                "Usage: TrigeiroAuthoritativeImporter <trig-dir> <dat-dir> <output-dir> <report-dir>");
            return 2;
        }

        string trigDirectory = Path.GetFullPath(args[0]);
        string datDirectory = Path.GetFullPath(args[1]);
        string outputDirectory = Path.GetFullPath(args[2]);
        string reportDirectory = Path.GetFullPath(args[3]);

        Directory.CreateDirectory(outputDirectory);
        Directory.CreateDirectory(reportDirectory);

        string[] trigFiles = Directory
            .EnumerateFiles(trigDirectory, "*.trig", SearchOption.AllDirectories)
            .OrderBy(path => path, StringComparer.OrdinalIgnoreCase)
            .ToArray();

        string[] datFiles = Directory.Exists(datDirectory)
            ? Directory
                .EnumerateFiles(datDirectory, "*.dat", SearchOption.AllDirectories)
                .OrderBy(path => path, StringComparer.OrdinalIgnoreCase)
                .ToArray()
            : Array.Empty<string>();

        var datById = datFiles.ToDictionary(
            path => Path.GetFileNameWithoutExtension(path),
            StringComparer.OrdinalIgnoreCase);

        var rows = new List<ValidationRow>();
        int converted = 0;
        int originalRejected = 0;

        foreach (string trigPath in trigFiles)
        {
            string id = Path.GetFileNameWithoutExtension(trigPath);

            try
            {
                TrigData trig = TrigReader.Read(trigPath);

                DerivedValidation validation;

                if (datById.TryGetValue(id, out string? datPath))
                {
                    try
                    {
                        DatData dat = DatReader.Read(datPath);
                        validation = Reconciler.ValidateDerived(dat, trig);
                    }
                    catch (Exception ex)
                    {
                        validation = new DerivedValidation(
                            "DERIVED_DAT_PARSE_FAILURE",
                            false,
                            ex.GetType().Name + ": " + ex.Message);
                    }
                }
                else
                {
                    datPath = "";
                    validation = new DerivedValidation(
                        "DERIVED_DAT_MISSING",
                        false,
                        "No derived DAT representation is available.");
                }

                LotSizingInstance instance = BuildFromOriginalTrig(
                    id,
                    trigPath,
                    datPath ?? "",
                    trig,
                    validation);

                string outputFile =
                    $"LSDM_TRIGEIRO1989_CLSP_{trig.ItemCount}items_{trig.PeriodCount}periods_{id.ToUpperInvariant()}.xml";

                string outputPath = Path.Combine(
                    outputDirectory,
                    outputFile);

                Serialize(instance, outputPath);

                converted++;

                rows.Add(new ValidationRow(
                    id,
                    trigPath,
                    datPath ?? "",
                    Sha(trigPath),
                    string.IsNullOrWhiteSpace(datPath) ? "" : Sha(datPath),
                    trig.ItemCount,
                    trig.PeriodCount,
                    "ORIGINAL_TRIG_AUTHORITATIVE",
                    validation.Status,
                    validation.SharedFieldsValid.ToString(),
                    validation.Diagnostic,
                    outputFile,
                    Sha(outputPath)));

                Console.WriteLine(
                    $"OK|{id}|items={trig.ItemCount}|periods={trig.PeriodCount}|{validation.Status}|{outputFile}");
            }
            catch (Exception ex)
            {
                originalRejected++;

                rows.Add(new ValidationRow(
                    id,
                    trigPath,
                    "",
                    Sha(trigPath),
                    "",
                    0,
                    0,
                    "ORIGINAL_TRIG_REJECTED",
                    "",
                    "False",
                    ex.GetType().Name + ": " + ex.Message,
                    "",
                    ""));

                Console.WriteLine(
                    $"REJECT_ORIGINAL|{id}|{ex.GetType().Name}|{ex.Message}");
            }
        }

        string reportPath = Path.Combine(
            reportDirectory,
            "TRIGEIRO-AUTHORITATIVE-VALIDATION.csv");

        WriteReport(reportPath, rows);

        Console.WriteLine(
            $"SUMMARY|trig={trigFiles.Length}|dat={datFiles.Length}|converted={converted}|originalRejected={originalRejected}|report={reportPath}");

        return originalRejected == 0 && converted == trigFiles.Length ? 0 : 4;
    }

    private static LotSizingInstance BuildFromOriginalTrig(
        string id,
        string trigPath,
        string datPath,
        TrigData trig,
        DerivedValidation validation)
    {
        var builder = new SupplyChainModelBuilder(trig.PeriodCount);

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
                trig.PeriodCount,
                trig.Capacity)
        };

        builder
            .AddPlant(plant)
            .AddWorkCenter(PlantId, workCenter)
            .AddDistributionCenter(
                new DistributionCenter(
                    DistributionCenterId,
                    "Trigeiro 1989 external demand"));

        for (int i = 0; i < trig.ItemCount; i++)
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
                    trig.PeriodCount,
                    trig.UnitProductionTime[i]),
                SetupTime = new SetupTime(
                    trig.PeriodCount,
                    trig.SetupTime[i]),
                FixedSetupCost = new FixedSetupCost(
                    trig.PeriodCount,
                    trig.SetupCost[i]),
                // Original TRIG contract has no unit production-cost field.
                // Do not import DAT-only fields into the canonical model.
                UnitUsageCost = new UnitUsageCost(
                    trig.PeriodCount,
                    0.0)
            };

            builder.AddProductionCharacteristic(characteristic);

            Inventory inventory = Inventory.ForPlantWarehouse(
                itemId,
                PlantId,
                initialInventory: 0.0);

            inventory.UnitUsageCost = new UnitUsageCost(
                trig.PeriodCount,
                trig.HoldingCost[i]);

            builder.AddInventory(inventory);

            var demand = new Demand(
                itemId,
                DistributionCenterId,
                planningHorizon: trig.PeriodCount);

            for (int t = 1; t <= trig.PeriodCount; t++)
            {
                demand.SetQuantity(
                    t,
                    trig.Demand[i, t - 1]);
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
            createdBy: "LotSizingDataModel.Benchmarks TrigeiroAuthoritativeImporter v0.11.0");

        instance.Description =
            "Canonical Trigeiro benchmark instance reconstructed exclusively from the original " +
            ".trig representation. The paired .dat file is a derived secondary representation " +
            "used only for validation and never as a canonical parameter source.";

        string datInfo = string.IsNullOrWhiteSpace(datPath)
            ? "DAT=missing"
            : $"DAT={Path.GetFileName(datPath)} SHA256={Sha(datPath)}";

        instance.SourceInformation =
            $"AUTHORITATIVE ORIGINAL: TRIG={Path.GetFileName(trigPath)} SHA256={Sha(trigPath)}. " +
            $"SECONDARY DERIVED VALIDATION: {datInfo}. " +
            $"Derived status={validation.Status}; {validation.Diagnostic}";

        instance.Tags.Add("Trigeiro-1989");
        instance.Tags.Add("CLSP");
        instance.Tags.Add("capacitated");
        instance.Tags.Add("setup-times");
        instance.Tags.Add("single-level");
        instance.Tags.Add("single-machine");
        instance.Tags.Add("ORIGINAL_TRIG_AUTHORITATIVE");
        instance.Tags.Add(validation.Status);

        return instance;
    }

    private static void Serialize(
        LotSizingInstance instance,
        string outputPath)
    {
        var serializer = new XmlSerializer(
            typeof(LotSizingInstance));

        var settings = new XmlWriterSettings
        {
            Indent = true,
            IndentChars = "    ",
            Encoding = new UTF8Encoding(false),
            OmitXmlDeclaration = false,
            NewLineHandling = NewLineHandling.Replace
        };

        using XmlWriter writer = XmlWriter.Create(
            outputPath,
            settings);

        serializer.Serialize(writer, instance);
    }

    private static string Sha(string path)
    {
        using var stream = File.OpenRead(path);
        using var sha =
            System.Security.Cryptography.SHA256.Create();

        return System.Convert.ToHexString(
            sha.ComputeHash(stream));
    }

    private static void WriteReport(
        string path,
        IReadOnlyList<ValidationRow> rows)
    {
        using var writer = new StreamWriter(
            path,
            false,
            new UTF8Encoding(false));

        writer.WriteLine(
            "instance_id,trig_path,dat_path,trig_sha256,dat_sha256,items,periods,canonical_source,derived_status,shared_fields_valid,diagnostic,xml_file,xml_sha256");

        foreach (ValidationRow row in rows)
        {
            writer.WriteLine(
                string.Join(
                    ",",
                    new[]
                    {
                        row.InstanceId,
                        row.TrigPath,
                        row.DatPath,
                        row.TrigSha256,
                        row.DatSha256,
                        row.Items.ToString(CultureInfo.InvariantCulture),
                        row.Periods.ToString(CultureInfo.InvariantCulture),
                        row.CanonicalSource,
                        row.DerivedStatus,
                        row.SharedFieldsValid,
                        row.Diagnostic,
                        row.XmlFile,
                        row.XmlSha256
                    }.Select(Csv)));
        }
    }

    private static string Csv(string value) =>
        "\"" + (value ?? "")
            .Replace("\"","\"\"") + "\"";
}

internal sealed record ValidationRow(
    string InstanceId,
    string TrigPath,
    string DatPath,
    string TrigSha256,
    string DatSha256,
    int Items,
    int Periods,
    string CanonicalSource,
    string DerivedStatus,
    string SharedFieldsValid,
    string Diagnostic,
    string XmlFile,
    string XmlSha256);

internal sealed record DerivedValidation(
    string Status,
    bool SharedFieldsValid,
    string Diagnostic);

internal static class Reconciler
{
    public static DerivedValidation ValidateDerived(
        DatData dat,
        TrigData trig)
    {
        var mismatches = new List<string>();

        if (dat.ItemCount != trig.ItemCount)
            mismatches.Add("item-count");

        if (dat.PeriodCount != trig.PeriodCount)
            mismatches.Add("period-count");

        if (!Near(dat.Capacity,trig.Capacity))
            mismatches.Add("capacity");

        int commonItems = Math.Min(
            dat.ItemCount,
            trig.ItemCount);

        int commonPeriods = Math.Min(
            dat.PeriodCount,
            trig.PeriodCount);

        for (int i = 0; i < commonItems; i++)
        {
            if (!Near(
                dat.UnitProductionTime[i],
                trig.UnitProductionTime[i]))
            {
                mismatches.Add(
                    $"unit-time[{i + 1}]");
            }

            if (!Near(
                dat.HoldingCost[i],
                trig.HoldingCost[i]))
            {
                mismatches.Add(
                    $"holding-cost[{i + 1}]");
            }

            if (!Near(
                dat.SetupCost[i],
                trig.SetupCost[i]))
            {
                mismatches.Add(
                    $"setup-cost[{i + 1}]");
            }

            for (int t = 0; t < commonPeriods; t++)
            {
                if (!Near(
                    dat.Demand[i,t],
                    trig.Demand[i,t]))
                {
                    mismatches.Add(
                        $"demand[{i + 1},{t + 1}]");
                }
            }
        }

        if (mismatches.Count > 0)
        {
            return new DerivedValidation(
                "DERIVED_DAT_OTHER_MISMATCH",
                false,
                "Derived DAT differs from authoritative TRIG on: " +
                string.Join(";",mismatches.Take(30)) +
                (mismatches.Count > 30
                    ? $";... total={mismatches.Count}"
                    : ""));
        }

        bool datSetupAllZero =
            dat.SetupTime.All(v => Near(v,0.0));

        bool setupEqual = true;

        for (int i = 0; i < commonItems; i++)
        {
            if (!Near(
                dat.SetupTime[i],
                trig.SetupTime[i]))
            {
                setupEqual = false;
                break;
            }
        }

        bool datProductionCostAllZero =
            dat.ProductionCost.All(v => Near(v,0.0));

        string productionNote =
            datProductionCostAllZero
                ? " DAT-only production-cost fields are all zero and are ignored canonically."
                : " DAT-only production-cost fields are nonzero and are ignored canonically because TRIG has no such field.";

        if (setupEqual)
        {
            return new DerivedValidation(
                "DERIVED_DAT_VALIDATED",
                true,
                "All shared fields, including setup time, agree." +
                productionNote);
        }

        if (datSetupAllZero)
        {
            return new DerivedValidation(
                "DERIVED_DAT_KNOWN_SETUP_TIME_LOSS",
                true,
                "All shared non-setup-time fields agree; DAT setup-time fields are systematically zero, so original TRIG setup times remain authoritative." +
                productionNote);
        }

        return new DerivedValidation(
            "DERIVED_DAT_SETUP_TIME_MISMATCH",
            true,
            "Shared non-setup-time fields agree, but DAT setup-time mismatch is not systematic zero loss. Original TRIG remains authoritative." +
            productionNote);
    }

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

        var values =
            new Dictionary<string,string>(
                StringComparer.OrdinalIgnoreCase);

        foreach (string line in lines)
        {
            int eq = line.IndexOf('=');

            if (eq <= 0)
                continue;

            values[line[..eq].Trim()] =
                line[(eq + 1)..].Trim();
        }

        int periods = PositiveInt(
            Require(values,"NB_PERIODES"));

        int items = PositiveInt(
            Require(values,"NB_PRODUITS"));

        double[,] demand =
            new double[items,periods];

        for (int i = 0; i < items; i++)
        {
            double[] row = ParseVector(
                Require(
                    values,
                    $"Demande{i + 1}"));

            if (row.Length != periods)
                throw new InvalidDataException(
                    "DAT demand length mismatch.");

            for (int t = 0; t < periods; t++)
                demand[i,t] = row[t];
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
            throw new InvalidDataException(
                "DAT capacity length mismatch.");

        double capacity = capacityVector[0];

        if (capacityVector.Any(
            v => Math.Abs(v-capacity) > 1e-9))
        {
            throw new InvalidDataException(
                "DAT capacity is not stationary.");
        }

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
        if (!values.TryGetValue(
            key,
            out string? value))
        {
            throw new InvalidDataException(
                "DAT missing key: " + key);
        }

        return value;
    }

    private static double[] ParseVector(
        string value) =>
        Regex.Split(value.Trim(),@"\s+")
            .Where(x => x.Length > 0)
            .Select(Number)
            .ToArray();

    private static int PositiveInt(
        string value)
    {
        double number = Number(value);

        if (number <= 0 ||
            Math.Abs(number-Math.Round(number)) > 1e-9 ||
            number > int.MaxValue)
        {
            throw new InvalidDataException(
                "Expected positive integer.");
        }

        return checked((int)Math.Round(number));
    }

    private static double Number(
        string value)
    {
        string normalized =
            value.Trim().Replace(',','.');

        if (!double.TryParse(
            normalized,
            NumberStyles.Float,
            CultureInfo.InvariantCulture,
            out double result))
        {
            throw new InvalidDataException(
                "Invalid DAT number: " +
                value);
        }

        return result;
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
    private static readonly Regex ItemRegex =
        new(
            @"^\s*(?<ut>[+-]?\d+(?:[.,]\d+)?)\s+" +
            @"(?<hc>[+-]?\d+(?:[.,]\d+)?)\s+" +
            @"(?<st>[+-]?\d+\.)\s*" +
            @"(?<sc>[+-]?\d+\.)\s*$",
            RegexOptions.Compiled);

    public static TrigData Read(
        string path)
    {
        string[] lines = File.ReadAllLines(
            path,
            Encoding.Latin1);

        int cursor = 0;

        int[] dimensions = Integers(
            NextNonEmpty(
                lines,
                ref cursor));

        if (dimensions.Length < 2)
            throw new InvalidDataException(
                "TRIG dimensions missing.");

        int items = dimensions[0];
        int periods = dimensions[1];

        _ = NextNonEmpty(lines,ref cursor);
        double capacity = Number(
            NextNonEmpty(lines,ref cursor));

        double[] unitTime =
            new double[items];
        double[] holding =
            new double[items];
        double[] setupTime =
            new double[items];
        double[] setupCost =
            new double[items];

        for (int i = 0; i < items; i++)
        {
            string line =
                NextNonEmpty(
                    lines,
                    ref cursor);

            Match match =
                ItemRegex.Match(line);

            if (!match.Success)
            {
                throw new InvalidDataException(
                    $"TRIG item row {i + 1} invalid: {line}");
            }

            unitTime[i] =
                Number(match.Groups["ut"].Value);

            holding[i] =
                Number(match.Groups["hc"].Value);

            setupTime[i] =
                Number(match.Groups["st"].Value);

            setupCost[i] =
                Number(match.Groups["sc"].Value);
        }

        var numericRows =
            new List<int[]>();

        while (cursor < lines.Length)
        {
            string line =
                lines[cursor++];

            if (string.IsNullOrWhiteSpace(line))
                continue;

            if (Regex.IsMatch(
                line,
                @"[A-Za-z]"))
            {
                break;
            }

            int[] row = Integers(line);

            if (row.Length > 0)
                numericRows.Add(row);
        }

        int blocks =
            (int)Math.Ceiling(items/15.0);

        int expectedRows =
            periods * blocks;

        if (numericRows.Count < expectedRows)
        {
            throw new InvalidDataException(
                $"TRIG demand rows={numericRows.Count}, expected={expectedRows}.");
        }

        double[,] demand =
            new double[items,periods];

        for (int t = 0; t < periods; t++)
        {
            int offset = 0;

            for (int b = 0; b < blocks; b++)
            {
                int[] row =
                    numericRows[b*periods+t];

                int required =
                    Math.Min(
                        15,
                        items-offset);

                if (row.Length < required)
                {
                    throw new InvalidDataException(
                        "TRIG demand block width mismatch.");
                }

                for (int j = 0; j < required; j++)
                    demand[offset+j,t] =
                        row[j];

                offset += required;
            }
        }

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
            string line =
                lines[cursor++];

            if (!string.IsNullOrWhiteSpace(line))
                return line;
        }

        throw new EndOfStreamException();
    }

    private static int[] Integers(
        string line) =>
        Regex.Matches(
            line,
            @"[+-]?\d+")
        .Select(
            m => int.Parse(
                m.Value,
                CultureInfo.InvariantCulture))
        .ToArray();

    private static double Number(
        string value)
    {
        string normalized =
            value.Trim()
                .TrimEnd('.')
                .Replace(',','.');

        if (!double.TryParse(
            normalized,
            NumberStyles.Float,
            CultureInfo.InvariantCulture,
            out double result))
        {
            throw new InvalidDataException(
                "Invalid TRIG number: " +
                value);
        }

        return result;
    }
}
