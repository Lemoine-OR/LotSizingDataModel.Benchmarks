
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
using LotSizingDataModel.Instance.Creation;

internal static class Program
{
    private const int PlantId = 1;
    private const int DistributionCenterId = 1;

    private static int Main(string[] args)
    {
        if (args.Length < 3 || args.Length > 4)
        {
            Console.Error.WriteLine(
                "Usage: TD1996Importer <source-dir> <output-dir> <report-dir> [--audit-only]");
            return 2;
        }

        string sourceDir = Path.GetFullPath(args[0]);
        string outputDir = Path.GetFullPath(args[1]);
        string reportDir = Path.GetFullPath(args[2]);
        bool auditOnly = args.Length == 4 &&
            string.Equals(args[3], "--audit-only", StringComparison.OrdinalIgnoreCase);

        Directory.CreateDirectory(outputDir);
        Directory.CreateDirectory(reportDir);

        string[] files = Directory
            .EnumerateFiles(sourceDir, "*.dat", SearchOption.AllDirectories)
            .OrderBy(p => p, NaturalFileComparer.Instance)
            .ToArray();

        var report = new List<ReportRow>();
        int converted = 0;
        int rejected = 0;
        int ambiguousNoResource = 0;
        int ambiguousPositiveSetupTime = 0;

        foreach (string path in files)
        {
            string id = Path.GetFileNameWithoutExtension(path);

            try
            {
                SourceData data = Reader.Read(path);

                ambiguousNoResource += data.ItemsWithoutResourceSignal.Count;
                ambiguousPositiveSetupTime += data.ItemsWithoutResourceSignal
                    .Count(i => data.SetupTime[i - 1] > 0.0);

                string outputFile = "";

                if (!auditOnly)
                {
                    LotSizingInstance instance = BuildInstance(data, path);
                    outputFile =
                        $"LSDM_TD1996_MLCLSP_{data.ItemCount}items_{data.PeriodCount}periods_{id}.xml";

                    Serialize(
                        instance,
                        Path.Combine(outputDir, outputFile));

                    converted++;
                }

                report.Add(new ReportRow(
                    id,
                    path,
                    Sha(path),
                    data.ItemCount,
                    data.PeriodCount,
                    data.ResourceCount,
                    data.FinishedProductCount,
                    data.BomArcCount,
                    data.ItemsWithoutResourceSignal.Count,
                    data.ItemsWithoutResourceSignal.Count(
                        i => data.SetupTime[i - 1] > 0.0),
                    data.InferredResourceAssignments,
                    data.ResourceAssignmentEvidence,
                    data.ClassId,
                    auditOnly ? "AUDIT_VALID" : "CONVERTED",
                    outputFile,
                    ""));

                if (!auditOnly)
                {
                    Console.WriteLine(
                        $"OK|{id}|class={data.ClassId}|items={data.ItemCount}|periods={data.PeriodCount}|resources={data.ResourceCount}|finished={data.FinishedProductCount}|noResource={data.ItemsWithoutResourceSignal.Count}|{outputFile}");
                }
            }
            catch (Exception ex)
            {
                rejected++;

                report.Add(new ReportRow(
                    id,
                    path,
                    Sha(path),
                    0,0,0,0,0,0,0,0,
                    "",
                    "",
                    "REJECTED",
                    "",
                    ex.GetType().Name + ": " + ex.Message));

                Console.WriteLine(
                    $"FAIL|{id}|{ex.GetType().Name}|{ex.Message}");
            }
        }

        WriteReport(
            Path.Combine(reportDir, "TD1996-CONVERSION-MANIFEST.csv"),
            report);

        Console.WriteLine(
            $"SUMMARY|files={files.Length}|converted={converted}|rejected={rejected}|auditOnly={auditOnly}|noResourceSignals={ambiguousNoResource}|positiveSetupWithoutResourceSignal={ambiguousPositiveSetupTime}");

        if (files.Length != 3450 || rejected != 0)
            return 4;

        if (!auditOnly && converted != 3450)
            return 5;

        return 0;
    }

    private static LotSizingInstance BuildInstance(
        SourceData d,
        string sourcePath)
    {
        var builder = new SupplyChainModelBuilder(d.PeriodCount);

        var warehouse = new PlantWarehouse(
            "Tempelmeier-Derstroff benchmark plant warehouse");

        var plant = new Plant(
            PlantId,
            "Tempelmeier-Derstroff benchmark plant",
            warehouse);

        builder.AddPlant(plant);

        for (int m = 1; m <= d.ResourceCount; m++)
        {
            var wc = new WorkCenter(
                m,
                "Resource " + m)
            {
                CapacityConstraint =
                    new CapacityConstraint(d.PeriodCount)
            };

            for (int t = 1; t <= d.PeriodCount; t++)
            {
                wc.CapacityConstraint.SetMaximumCapacity(
                    t,
                    d.Capacity[m - 1, t - 1]);
            }

            builder.AddWorkCenter(
                PlantId,
                wc);
        }

        builder.AddDistributionCenter(
            new DistributionCenter(
                DistributionCenterId,
                "External demand"));

        for (int j = 1; j <= d.ItemCount; j++)
        {
            builder.AddItem(
                j,
                "Item " + j,
                0);
        }

        foreach (BomArc arc in d.Bom)
        {
            builder.AddComponentRequirement(
                arc.Parent,
                arc.Component,
                arc.Quantity);
        }

        for (int j = 1; j <= d.ItemCount; j++)
        {
            var routing = new ProductionRouting(
                j,
                j,
                PlantId,
                0);

            int[] resources = d.ResourcesForItem(j).ToArray();

            foreach (int m in resources)
            {
                routing.AddWorkCenter(
                    new WorkCenterReference(
                        PlantId,
                        m));
            }

            builder.AddProductionRouting(routing);

            foreach (int m in resources)
            {
                var characteristic =
                    new ProductionCharacteristic
                    {
                        ItemId = j,
                        WorkCenter =
                            new WorkCenterReference(
                                PlantId,
                                m),
                        UnitCapacityConsumption =
                            new UnitCapacityConsumption(
                                d.PeriodCount,
                                d.UnitProductionTime[j - 1]),
                        SetupTime =
                            new SetupTime(
                                d.PeriodCount,
                                d.SetupTime[j - 1]),
                        FixedSetupCost =
                            new FixedSetupCost(
                                d.PeriodCount,
                                d.SetupCostByResource[j - 1, m - 1]),
                        UnitUsageCost =
                            new UnitUsageCost(
                                d.PeriodCount,
                                d.UnitProductionCost[j - 1])
                    };

                builder.AddProductionCharacteristic(
                    characteristic);
            }

            Inventory inventory =
                Inventory.ForPlantWarehouse(
                    j,
                    PlantId,
                    0.0);

            inventory.UnitUsageCost =
                new UnitUsageCost(
                    d.PeriodCount,
                    d.HoldingCost[j - 1]);

            builder.AddInventory(inventory);

            if (j <= d.FinishedProductCount)
            {
                var demand = new Demand(
                    j,
                    DistributionCenterId,
                    d.PeriodCount);

                for (int t = 1; t <= d.PeriodCount; t++)
                {
                    demand.SetQuantity(
                        t,
                        d.Demand[j - 1, t - 1]);
                }

                builder.AddDemand(demand);

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
        }

        var chain = builder.Build(validate: true);

        string id =
            Path.GetFileNameWithoutExtension(sourcePath);

        LotSizingInstance instance =
            LotSizingInstanceFactory.Create(
                instanceId: "TD1996-" + id,
                supplyChain: chain,
                name: "Tempelmeier-Derstroff 1996 " + id,
                analyzeProductStructure: true,
                classifyProblem: true,
                createdBy:
                    "LotSizingDataModel.Benchmarks TD1996Importer v0.13.0");

        instance.Description =
            "Multi-level multi-item capacitated lot-sizing instance from the user-provided Tempelmeier-Derstroff corpus.";

        instance.SourceInformation =
            $"User-provided archive 'tempelmeir destroff.zip'; source file={Path.GetFileName(sourcePath)}; SHA256={Sha(sourcePath)}; class={d.ClassId}. " +
            "Gozinto rows are interpreted as parent-to-component binary requirements. " +
            "A nonzero CL_Produit resource component is used as the direct resource-membership signal. " +
            "For the documented 40-item Test Set C structures, item 29 has a zero setup-cost vector in the supplied derived DAT representation. " +
            "Its resource is reconstructed only after the other 39 observed resource signals uniquely match one published Tempelmeier/Stadtler general-or-assembly cyclic/non-cyclic resource map.";

        instance.Tags.Add("Tempelmeier-Derstroff-1996");
        instance.Tags.Add("TD1996");
        instance.Tags.Add("MLCLSP");
        instance.Tags.Add("multi-level");
        instance.Tags.Add("capacitated");
        instance.Tags.Add(d.ClassId);

        if (d.InferredResourceAssignments > 0)
        {
            instance.Tags.Add(
                "RESOURCE_ASSIGNMENT_RECONSTRUCTED_FROM_DOCUMENTED_TEST_SET_C_MAP");
        }

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
                OmitXmlDeclaration = false,
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

    private static string Sha(
        string path)
    {
        using var stream =
            File.OpenRead(path);

        using var sha =
            System.Security.Cryptography
                .SHA256.Create();

        return System.Convert.ToHexString(
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
            "instance_id,source_path,source_sha256,items,periods,resources,finished_products,bom_arcs,items_without_resource_signal,positive_setup_time_without_resource_signal,inferred_resource_assignments,resource_assignment_evidence,class_id,status,xml_file,diagnostic");

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
                        row.Resources.ToString(CultureInfo.InvariantCulture),
                        row.FinishedProducts.ToString(CultureInfo.InvariantCulture),
                        row.BomArcs.ToString(CultureInfo.InvariantCulture),
                        row.ItemsWithoutResourceSignal.ToString(CultureInfo.InvariantCulture),
                        row.PositiveSetupTimeWithoutResourceSignal.ToString(CultureInfo.InvariantCulture),
                        row.InferredResourceAssignments.ToString(CultureInfo.InvariantCulture),
                        row.ResourceAssignmentEvidence,
                        row.ClassId,
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
            .Replace("\"","\"\"") +
        "\"";
}

internal sealed record ReportRow(
    string InstanceId,
    string SourcePath,
    string SourceSha256,
    int Items,
    int Periods,
    int Resources,
    int FinishedProducts,
    int BomArcs,
    int ItemsWithoutResourceSignal,
    int PositiveSetupTimeWithoutResourceSignal,
    int InferredResourceAssignments,
    string ResourceAssignmentEvidence,
    string ClassId,
    string Status,
    string XmlFile,
    string Diagnostic);

internal sealed record BomArc(
    int Parent,
    int Component,
    int Quantity);

internal sealed class SourceData
{
    public required int ItemCount { get; init; }
    public required int PeriodCount { get; init; }
    public required int ResourceCount { get; init; }
    public required int FinishedProductCount { get; init; }
    public required double[,] Demand { get; init; }
    public required double[,] SetupCostByResource { get; init; }
    public required double[] HoldingCost { get; init; }
    public required double[] UnitProductionCost { get; init; }
    public required double[,] Capacity { get; init; }
    public required double[] UnitProductionTime { get; init; }
    public required double[] SetupTime { get; init; }
    public required List<BomArc> Bom { get; init; }
    public required List<int> ItemsWithoutResourceSignal { get; init; }
    public required int[] ResourceAssignment { get; init; }
    public required int InferredResourceAssignments { get; init; }
    public required string ResourceAssignmentEvidence { get; init; }
    public required string ClassId { get; init; }

    public int BomArcCount => Bom.Count;

    public IEnumerable<int> ResourcesForItem(
        int item)
    {
        int resource = ResourceAssignment[item - 1];

        if (resource <= 0 || resource > ResourceCount)
        {
            throw new InvalidDataException(
                $"Item {item} has no valid resource assignment.");
        }

        yield return resource;
    }
}

internal static class Reader
{
    public static SourceData Read(
        string path)
    {
        string[] lines =
            File.ReadAllLines(
                path,
                Encoding.Latin1);

        string text =
            string.Join(
                "\n",
                lines);

        if (!text.Contains(
            "MLSCLSP Tempelmeier",
            StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidDataException(
                "Missing internal Tempelmeier MLSCLSP source signature.");
        }

        var values =
            new Dictionary<string,string>(
                StringComparer.OrdinalIgnoreCase);

        foreach (string line in lines)
        {
            int eq =
                line.IndexOf('=');

            if (eq <= 0)
                continue;

            values[
                line[..eq].Trim()] =
                line[(eq + 1)..].Trim();
        }

        int periods =
            PositiveInt(
                Require(
                    values,
                    "NB_PERIODES"));

        int items =
            PositiveInt(
                Require(
                    values,
                    "NB_PRODUITS"));

        int finished =
            PositiveInt(
                Require(
                    values,
                    "NB_PRODUITS_FINIS"));

        int resources =
            PositiveInt(
                Require(
                    values,
                    "NB_RESSOURCES"));

        if (finished > items)
            throw new InvalidDataException(
                "Finished-product count exceeds item count.");

        double[,] demand =
            new double[items,periods];

        for (int j = 1; j <= finished; j++)
        {
            double[] row =
                ParseVector(
                    Require(
                        values,
                        "DEMANDE" + j));

            if (row.Length != periods)
                throw new InvalidDataException(
                    $"Demand length mismatch for item {j}.");

            for (int t = 0; t < periods; t++)
                demand[j - 1,t] = row[t];
        }

        double[,] setup =
            new double[items,resources];

        var missingResourceSignal =
            new List<int>();

        for (int j = 1; j <= items; j++)
        {
            double[] row =
                ParseVector(
                    Require(
                        values,
                        "CL_Produit" + j));

            if (row.Length != resources)
                throw new InvalidDataException(
                    $"CL_Produit{j} resource-vector length mismatch.");

            int nonZero = 0;

            for (int m = 0; m < resources; m++)
            {
                setup[j - 1,m] = row[m];

                if (Math.Abs(row[m]) > 1e-12)
                    nonZero++;
            }

            if (nonZero > 1)
                throw new InvalidDataException(
                    $"Item {j} has multiple nonzero CL resource signals.");

            if (nonZero == 0)
                missingResourceSignal.Add(j);
        }

        double[] holding =
            new double[items];

        double[] productionCost =
            new double[items];

        double[] unitTime =
            new double[items];

        double[] setupTime =
            new double[items];

        for (int j = 1; j <= items; j++)
        {
            holding[j - 1] =
                Number(
                    Require(
                        values,
                        "CS_Produit" + j));

            productionCost[j - 1] =
                Number(
                    Require(
                        values,
                        "CP_Produit" + j));

            unitTime[j - 1] =
                Number(
                    Require(
                        values,
                        "C_t_p_Produit" + j));

            setupTime[j - 1] =
                Number(
                    Require(
                        values,
                        "C_t_l_Produit" + j));
        }

        double[,] capacity =
            new double[resources,periods];

        for (int m = 1; m <= resources; m++)
        {
            double[] row =
                ParseVector(
                    Require(
                        values,
                        "RESSOURCE" + m));

            if (row.Length != periods)
                throw new InvalidDataException(
                    $"RESSOURCE{m} period-vector length mismatch.");

            for (int t = 0; t < periods; t++)
                capacity[m - 1,t] = row[t];
        }

        var bom =
            new List<BomArc>();

        for (int parent = 1; parent <= items; parent++)
        {
            double[] row =
                ParseVector(
                    Require(
                        values,
                        "Gozinto" + parent));

            if (row.Length != items)
                throw new InvalidDataException(
                    $"Gozinto{parent} width mismatch.");

            for (int component = 1;
                 component <= items;
                 component++)
            {
                double q =
                    row[component - 1];

                if (Math.Abs(q) <= 1e-12)
                    continue;

                if (Math.Abs(q - 1.0) > 1e-12)
                    throw new InvalidDataException(
                        "The supplied TD1996 Gozinto corpus is expected to be binary.");

                if (parent == component)
                    throw new InvalidDataException(
                        "Self-loop in Gozinto matrix.");

                bom.Add(
                    new BomArc(
                        parent,
                        component,
                        1));
            }
        }

        ResourceAssignmentResult resourceAssignment =
            ResolveResourceAssignment(
                items,
                periods,
                resources,
                finished,
                setup,
                missingResourceSignal);

        ValidateNonNegative(
            demand.Cast<double>()
                .Concat(setup.Cast<double>())
                .Concat(holding)
                .Concat(productionCost)
                .Concat(capacity.Cast<double>())
                .Concat(unitTime)
                .Concat(setupTime));

        string classId =
            ClassId(
                items,
                periods,
                resources,
                finished);

        return new SourceData
        {
            ItemCount = items,
            PeriodCount = periods,
            ResourceCount = resources,
            FinishedProductCount = finished,
            Demand = demand,
            SetupCostByResource = setup,
            HoldingCost = holding,
            UnitProductionCost = productionCost,
            Capacity = capacity,
            UnitProductionTime = unitTime,
            SetupTime = setupTime,
            Bom = bom,
            ItemsWithoutResourceSignal =
                missingResourceSignal,
            ResourceAssignment =
                resourceAssignment.Assignment,
            InferredResourceAssignments =
                resourceAssignment.InferredCount,
            ResourceAssignmentEvidence =
                resourceAssignment.Evidence,
            ClassId = classId
        };
    }


    private sealed record ResourceAssignmentResult(
        int[] Assignment,
        int InferredCount,
        string Evidence);

    private static ResourceAssignmentResult ResolveResourceAssignment(
        int items,
        int periods,
        int resources,
        int finished,
        double[,] setupCostByResource,
        IReadOnlyList<int> missingResourceSignal)
    {
        int[] directlyObserved = new int[items];

        for (int j = 0; j < items; j++)
        {
            int found = 0;

            for (int m = 0; m < resources; m++)
            {
                if (Math.Abs(setupCostByResource[j,m]) <= 1e-12)
                    continue;

                if (found != 0)
                {
                    throw new InvalidDataException(
                        $"Item {j + 1} has more than one nonzero CL_Produit resource component.");
                }

                found = m + 1;
            }

            directlyObserved[j] = found;
        }

        if (missingResourceSignal.Count == 0)
        {
            if (directlyObserved.Any(x => x == 0))
            {
                throw new InvalidDataException(
                    "Internal resource-assignment inconsistency.");
            }

            return new ResourceAssignmentResult(
                directlyObserved,
                0,
                "DIRECT_CL_PRODUIT_RESOURCE_SIGNAL");
        }

        if (items == 40 &&
            periods == 16 &&
            resources == 6 &&
            (finished == 2 || finished == 6))
        {
            if (missingResourceSignal.Count != 1 ||
                missingResourceSignal[0] != 29)
            {
                throw new InvalidDataException(
                    "The documented 40-item source-repair rule only applies when item 29 is the sole all-zero CL_Produit row.");
            }

            int[][] candidates =
                finished == 6
                    ? new[]
                    {
                        GeneralNonCyclic40(),
                        GeneralCyclic40()
                    }
                    : new[]
                    {
                        AssemblyNonCyclic40(),
                        AssemblyCyclic40()
                    };

            var matches = new List<int[]>();

            foreach (int[] candidate in candidates)
            {
                bool compatible = true;

                for (int j = 0; j < items; j++)
                {
                    if (directlyObserved[j] == 0)
                        continue;

                    if (directlyObserved[j] != candidate[j])
                    {
                        compatible = false;
                        break;
                    }
                }

                if (compatible)
                    matches.Add(candidate);
            }

            if (matches.Count != 1)
            {
                throw new InvalidDataException(
                    $"Documented Test Set C resource-assignment reconciliation is not unique: matches={matches.Count}.");
            }

            int[] assignment = matches[0];
            string structure =
                finished == 6
                    ? "GENERAL"
                    : "ASSEMBLY";

            string cycle =
                ReferenceEquals(assignment,candidates[0])
                    ? "NON_CYCLIC"
                    : "CYCLIC";

            return new ResourceAssignmentResult(
                assignment,
                1,
                "DOCUMENTED_TEST_SET_C_" +
                structure +
                "_" +
                cycle +
                "_RESOURCE_MAP;ITEM29_INFERRED_FROM_PUBLISHED_MAP;ALL_39_NONZERO_CL_SIGNALS_MATCH");
        }

        throw new InvalidDataException(
            "Source contains an all-zero CL_Produit resource row outside the only documented repair case.");
    }

    private static int[] GeneralNonCyclic40() =>
        new[]
        {
            1,1,1, 2,2,2, 3,3,3,3,
            4,4,4,4,4,4,4,4,4,
            5,5,5,5,5,5,5,5,5,5,
            6,6,6,6,6,6,6,6,6,6,6
        };

    private static int[] GeneralCyclic40() =>
        new[]
        {
            1,1,1,2,1,2, 3,3,3,3,
            4,4,4,4,4, 5,5, 2,2,
            5,5,5,5,5, 4,4,4,4,4,
            6,5, 6,6,6,6,6,6,6, 4,4
        };

    private static int[] AssemblyNonCyclic40() =>
        new[]
        {
            1,1, 2,2,2,2, 3,3,3,3,3,3,3,3,
            4,4,4,4,4,4,4,4,
            5,5,5,5,5,5,5,5,
            6,6,6,6,6,6,6,6,6,6
        };

    private static int[] AssemblyCyclic40() =>
        new[]
        {
            1,1,1,2,3,2, 3,3,3,3,3,3,3,3,3,3,
            4,4,4,4, 5,5,5, 6,6,6, 4,4, 6,6,
            4,4, 5,5,5,5, 4,4, 6,6
        };

    private static string ClassId(
        int items,
        int periods,
        int resources,
        int finished)
    {
        return (items,periods,resources,finished) switch
        {
            (10,4,3,1) =>
                "TD-C10-T4-R3-F1",
            (10,4,3,4) =>
                "TD-C10-T4-R3-F4",
            (40,16,6,2) =>
                "TD-C40-T16-R6-F2",
            (40,16,6,6) =>
                "TD-C40-T16-R6-F6",
            (100,16,10,15) =>
                "TD-C100-T16-R10-F15",
            _ =>
                throw new InvalidDataException(
                    $"Unexpected TD1996 structural class: {items}/{periods}/{resources}/{finished}.")
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
                "Missing source key: " +
                key);
        }

        return value;
    }

    private static double[] ParseVector(
        string value) =>
        Regex.Split(
            value.Trim(),
            @"\s+")
        .Where(x => x.Length > 0)
        .Select(Number)
        .ToArray();

    private static int PositiveInt(
        string value)
    {
        double x =
            Number(value);

        if (x <= 0 ||
            Math.Abs(x - Math.Round(x)) > 1e-9 ||
            x > int.MaxValue)
        {
            throw new InvalidDataException(
                "Expected positive integer.");
        }

        return checked(
            (int)Math.Round(x));
    }

    private static double Number(
        string value)
    {
        string normalized =
            value.Trim()
                .Replace(',','.');

        if (!double.TryParse(
            normalized,
            NumberStyles.Float,
            CultureInfo.InvariantCulture,
            out double result))
        {
            throw new InvalidDataException(
                "Invalid numeric value: " +
                value);
        }

        return result;
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

internal sealed class NaturalFileComparer :
    IComparer<string>
{
    public static readonly
        NaturalFileComparer Instance =
            new();

    public int Compare(
        string? x,
        string? y)
    {
        if (ReferenceEquals(x,y))
            return 0;

        if (x is null)
            return -1;

        if (y is null)
            return 1;

        return string.Compare(
            Path.GetFileName(x),
            Path.GetFileName(y),
            StringComparison.OrdinalIgnoreCase);
    }
}
