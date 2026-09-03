
using System.Globalization;
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
    private static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

    private static int Main(string[] args)
    {
        if (args.Length < 3)
        {
            Console.Error.WriteLine("Usage: TempelmeierConverter <stadtler|clspl|datab> <source-root> <output-root>");
            return 2;
        }

        string mode = args[0].Trim().ToLowerInvariant();
        string sourceRoot = Path.GetFullPath(args[1]);
        string outputRoot = Path.GetFullPath(args[2]);
        Directory.CreateDirectory(outputRoot);

        var candidates = Directory.EnumerateFiles(sourceRoot, "INDEX.PRN", SearchOption.AllDirectories)
            .Select(Path.GetDirectoryName)
            .Where(x => !string.IsNullOrWhiteSpace(x))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(x => x, StringComparer.OrdinalIgnoreCase)
            .ToList();

        int converted = 0;
        int failed = 0;

        foreach (string directory in candidates!)
        {
            try
            {
                SourceData data = mode switch
                {
                    "stadtler" => SourceData.ReadStadtler(directory, "STADTLER2003", "MLCLSP"),
                    "clspl" => SourceData.ReadClsplWithFallback(directory),
                    "datab" => SourceData.ReadStadtler(directory, "SUERIE_CLSPL", "CLSPL"),
                    _ => throw new InvalidOperationException("Unknown mode: " + mode)
                };

                LotSizingInstance instance = Convert(data);
                string id = BuildSourceId(directory, sourceRoot);
                string family = data.FamilyId;
                string file = $"LSDM_{family}_{data.ProblemType}_{data.T}_unknown_{Safe(id)}.xml";
                string path = Path.Combine(outputRoot, file);
                Serialize(instance, path);

                Console.WriteLine($"OK|{directory}|{path}|contract={data.SourceContract}");
                converted++;
            }
            catch (Exception ex)
            {
                Console.WriteLine($"FAIL|{directory}|{ex.GetType().Name}|{ex.Message}");
                failed++;
            }
        }

        Console.WriteLine($"SUMMARY|candidates={candidates.Count}|converted={converted}|failed={failed}");
        return failed == 0 ? 0 : 1;
    }

    private static LotSizingInstance Convert(SourceData d)
    {
        var builder = new SupplyChainModelBuilder(d.T);

        var warehouse = new PlantWarehouse("Benchmark plant warehouse");
        var plant = new Plant(1, "Benchmark plant", warehouse);
        builder.AddPlant(plant);

        for (int m = 1; m <= d.M; m++)
        {
            var wc = new WorkCenter(m, "Resource " + m)
            {
                CapacityConstraint = new CapacityConstraint(d.T)
            };

            for (int t = 1; t <= d.T; t++)
                wc.CapacityConstraint.SetMaximumCapacity(t, d.Capacity[m - 1, t - 1]);

            if (d.OvertimeCost[m - 1] > 0)
            {
                double safeBound = d.GetTechnicalAdditionalCapacityUpperBound(m);
                wc.AdditionalCapacity = new AdditionalCapacity(d.T, safeBound);
                wc.AdditionalCapacityCost = new AdditionalCapacityCost(d.T, d.OvertimeCost[m - 1]);
            }

            builder.AddWorkCenter(1, wc);
        }

        builder.AddDistributionCenter(new DistributionCenter(1, "External demand"));

        for (int j = 1; j <= d.J; j++)
            builder.AddItem(j, "Item " + j, 0);

        foreach (var bom in d.Bom)
            builder.AddComponentRequirement(bom.Parent, bom.Component, checked((int)Math.Round(bom.Quantity)));

        for (int j = 1; j <= d.J; j++)
        {
            var routing = new ProductionRouting(j, j, 1, 0);
            foreach (int m in d.ResourcesForItem(j))
                routing.AddWorkCenter(new WorkCenterReference(1, m));
            builder.AddProductionRouting(routing);

            foreach (int m in d.ResourcesForItem(j))
            {
                var pc = new ProductionCharacteristic
                {
                    ItemId = j,
                    WorkCenter = new WorkCenterReference(1, m),
                    UnitCapacityConsumption = new UnitCapacityConsumption(d.T, d.ProductionCoeff[m - 1, j - 1]),
                    SetupTime = new SetupTime(d.T, d.SetupTime[m - 1, j - 1]),
                    FixedSetupCost = new FixedSetupCost(d.T, d.SetupCost[j - 1])
                };
                builder.AddProductionCharacteristic(pc);
            }

            var inv = Inventory.ForPlantWarehouse(j, 1, d.InitialInventory[j - 1]);
            inv.UnitUsageCost = new UnitUsageCost(d.T, d.HoldingCost[j - 1]);
            builder.AddInventory(inv);

            bool hasDemand = false;
            var demand = new Demand(j, 1, d.T);
            for (int t = 1; t <= d.T; t++)
            {
                double q = d.Demand[j - 1, t - 1];
                demand.SetQuantity(t, q);
                if (q > 0) hasDemand = true;
            }

            if (hasDemand)
            {
                builder.AddDemand(demand);
                builder.AddDistributionCenterSourcing(new DistributionCenterSourcing
                {
                    DistributionCenterId = 1,
                    ItemId = j,
                    Warehouse = WarehouseReference.ForPlantWarehouse(1)
                });
            }
        }

        var chain = builder.Build(validate: true);
        var instance = LotSizingInstanceFactory.Create(
            instanceId: d.InstanceId,
            supplyChain: chain,
            name: d.InstanceName,
            analyzeProductStructure: true,
            classifyProblem: true,
            createdBy: "LotSizingDataModel Tempelmeier ecosystem converter");

        instance.Description = d.Description;
        instance.SourceInformation = d.SourceInformation;
        instance.Tags.Add(d.FamilyId);
        instance.Tags.Add(d.ProblemType);
        instance.Tags.Add(d.SourceContract);

        var comments = new List<string>
        {
            "Source contract: " + d.SourceContract + "."
        };

        if (d.ReconstructedFromStadtlerMasterData)
            comments.Add("KAPAZ/LAGKOST/RUESTK were not present in the source directory and were reconstructed from the official Stadtler MLCLSP generation formulas using AUSLAST, MITT_BED, TBO and ZFKOEF.");

        if (d.UsesDerivedTechnicalOvertimeBound)
            comments.Add("The source model has nonnegative overtime without an explicit finite maximum. LotSizingDataModel requires a finite AdditionalCapacity upper bound; a conservative horizon-demand-derived technical bound is used and is intended never to bind.");

        if (File.Exists(Path.Combine(d.SourceInformation, "FLAGS.PRN")) ||
            File.Exists(Path.Combine(d.SourceInformation, "YFIX.PRN")) ||
            File.Exists(Path.Combine(d.SourceInformation, "ZFIX.PRN")))
            comments.Add("Source-specific FLAGS/YFIX/ZFIX files are preserved as raw provenance but are not treated as core benchmark parameters because the published CLSPL data contract does not define them as instance coefficients.");

        instance.Comment = string.Join(" ", comments);
        return instance;
    }

    private static void Serialize(LotSizingInstance instance, string path)
    {
        var serializer = new XmlSerializer(typeof(LotSizingInstance));
        var settings = new System.Xml.XmlWriterSettings
        {
            Indent = true,
            Encoding = new System.Text.UTF8Encoding(false)
        };

        using var writer = System.Xml.XmlWriter.Create(path, settings);
        serializer.Serialize(writer, instance);
    }

    private static string BuildSourceId(string directory, string root)
    {
        string rel = Path.GetRelativePath(root, directory);
        if (rel == ".") rel = Path.GetFileName(directory);
        return rel.Replace(Path.DirectorySeparatorChar, '-').Replace(Path.AltDirectorySeparatorChar, '-');
    }

    private static string Safe(string value)
    {
        var chars = value.Select(c => char.IsLetterOrDigit(c) || c is '-' or '_' or '.' ? c : '-').ToArray();
        return new string(chars);
    }

    private sealed class SourceData
    {
        public string FamilyId { get; init; } = "";
        public string ProblemType { get; init; } = "";
        public string SourceContract { get; init; } = "";
        public string InstanceId { get; init; } = "";
        public string InstanceName { get; init; } = "";
        public string Description { get; init; } = "";
        public string SourceInformation { get; init; } = "";
        public int J { get; init; }
        public int T { get; init; }
        public int M { get; init; }
        public double[,] Demand { get; init; } = default!;
        public double[,] ProductionCoeff { get; init; } = default!;
        public double[,] SetupTime { get; init; } = default!;
        public double[,] Capacity { get; init; } = default!;
        public double[] HoldingCost { get; init; } = default!;
        public double[] SetupCost { get; init; } = default!;
        public double[] InitialInventory { get; init; } = default!;
        public double[] EndingInventory { get; init; } = default!;
        public double[] OvertimeCost { get; init; } = default!;
        public List<BomArc> Bom { get; init; } = new();
        public bool UsesDerivedTechnicalOvertimeBound { get; init; }
        public bool ReconstructedFromStadtlerMasterData { get; init; }

        public IEnumerable<int> ResourcesForItem(int j)
        {
            for (int m = 1; m <= M; m++)
                if (ProductionCoeff[m - 1, j - 1] > 0 || SetupTime[m - 1, j - 1] > 0)
                    yield return m;
        }

        public double GetTechnicalAdditionalCapacityUpperBound(int m)
        {
            double total = 0;
            for (int j = 0; j < J; j++)
            {
                double totalDemand = 0;
                for (int t = 0; t < T; t++) totalDemand += Demand[j, t];
                total += ProductionCoeff[m - 1, j] * totalDemand + SetupTime[m - 1, j];
            }
            return Math.Max(1.0, total);
        }

        public static SourceData ReadClsplWithFallback(string dir)
        {
            bool explicitContract =
                File.Exists(Path.Combine(dir, "KAPAZ.PRN")) &&
                File.Exists(Path.Combine(dir, "LAGKOST.PRN")) &&
                File.Exists(Path.Combine(dir, "RUESTK.PRN"));

            if (!explicitContract)
                return ReadStadtler(dir, "SUERIE_CLSPL", "CLSPL");

            var idx = ReadNumbers(Path.Combine(dir, "INDEX.PRN"));
            int j = I(idx[0]), t = I(idx[1]), m = I(idx[2]);

            return new SourceData
            {
                FamilyId = "SUERIE_CLSPL",
                ProblemType = "CLSPL",
                SourceContract = "CLSPL_EXPLICIT_11_FILE",
                InstanceId = "SUERIE-CLSPL-" + Path.GetFileName(dir),
                InstanceName = Path.GetFileName(dir),
                Description = "Converted from the official Suerie-Stadtler CLSPL explicit data format.",
                SourceInformation = dir,
                J = j, T = t, M = m,
                Demand = ReadMatrix(Path.Combine(dir, "P-BEDARF.PRN"), j, t),
                Capacity = ReadMatrix(Path.Combine(dir, "KAPAZ.PRN"), m, t),
                HoldingCost = ReadVector(Path.Combine(dir, "LAGKOST.PRN"), j),
                InitialInventory = ReadVector(Path.Combine(dir, "L0.PRN"), j),
                EndingInventory = ReadVector(Path.Combine(dir, "LT.PRN"), j),
                SetupCost = ReadVector(Path.Combine(dir, "RUESTK.PRN"), j),
                OvertimeCost = ReadVector(Path.Combine(dir, "UEBER-KS.PRN"), m),
                ProductionCoeff = ReadSparseMatrix(Path.Combine(dir, "PRODKOEF.PRN"), m, j),
                SetupTime = ReadSparseMatrix(Path.Combine(dir, "RUESTZ.PRN"), m, j),
                Bom = ReadBom(Path.Combine(dir, "DIREKT-B.PRN")),
                UsesDerivedTechnicalOvertimeBound = ReadVector(Path.Combine(dir, "UEBER-KS.PRN"), m).Any(x => x > 0),
                ReconstructedFromStadtlerMasterData = false
            };
        }

        public static SourceData ReadStadtler(string dir, string familyId, string problemType)
        {
            var idx = ReadNumbers(Path.Combine(dir, "INDEX.PRN"));
            int j = I(idx[0]), t = I(idx[1]), m = I(idx[2]);

            double[,] demand = ReadMatrix(Path.Combine(dir, "P-BEDARF.PRN"), j, t);
            double[] initial = ReadVector(Path.Combine(dir, "L0.PRN"), j);
            double[] ending = ReadVector(Path.Combine(dir, "LT.PRN"), j);
            double[] meanPrimary = ReadVector(Path.Combine(dir, "MITT_BED.PRN"), j);
            double[] tbo = ReadVector(Path.Combine(dir, "TBO.PRN"), j);
            double[] marginalHolding = ReadVector(Path.Combine(dir, "ZFKOEF.PRN"), j);
            double[] utilization = ReadVector(Path.Combine(dir, "AUSLAST.PRN"), m);
            double[] overtime = ReadVector(Path.Combine(dir, "UEBER-KS.PRN"), m);

            var bom = ReadBom(Path.Combine(dir, "DIREKT-B.PRN"));
            double[,] prod = ReadSparseMatrix(Path.Combine(dir, "PRODKOEF.PRN"), m, j);
            double[,] setup = ReadSparseMatrix(Path.Combine(dir, "RUESTZ.PRN"), m, j);

            double[] netMean = ComputeNetMeanDemand(meanPrimary, bom, j);
            double[] holding = ComputeHoldingCosts(marginalHolding, bom, j);
            double[] setupCost = new double[j];

            for (int x = 0; x < j; x++)
                setupCost[x] = 0.5 * marginalHolding[x] * tbo[x] * tbo[x] * netMean[x];

            double[,] capacity = new double[m, t];

            for (int mm = 0; mm < m; mm++)
            {
                double load = 0;

                for (int x = 0; x < j; x++)
                {
                    load += prod[mm, x] * netMean[x];
                    if (tbo[x] > 0)
                        load += setup[mm, x] / tbo[x];
                }

                double ru = utilization[mm];
                if (ru > 1.0) ru /= 100.0;
                if (ru <= 0) throw new InvalidDataException("Invalid resource utilization.");

                double c = load / ru;
                for (int tt = 0; tt < t; tt++) capacity[mm, tt] = c;
            }

            string leaf = Path.GetFileName(dir);

            return new SourceData
            {
                FamilyId = familyId,
                ProblemType = problemType,
                SourceContract = familyId == "SUERIE_CLSPL"
                    ? "CLSPL_DATAB_STADTLER_BPLUS_DERIVED"
                    : "STADTLER_MLCLSP_DERIVED",
                InstanceId = familyId + "-" + leaf,
                InstanceName = leaf,
                Description = familyId == "SUERIE_CLSPL"
                    ? "Converted from the official CLSPL datab test set, which contains 60 Stadtler B+ MLCLSP instances. Missing explicit capacity/holding/setup-cost files are reconstructed from the official Stadtler generation data."
                    : "Converted from the official Stadtler MLCLSP benchmark generation data.",
                SourceInformation = dir,
                J = j, T = t, M = m,
                Demand = demand,
                Capacity = capacity,
                HoldingCost = holding,
                InitialInventory = initial,
                EndingInventory = ending,
                SetupCost = setupCost,
                OvertimeCost = overtime,
                ProductionCoeff = prod,
                SetupTime = setup,
                Bom = bom,
                UsesDerivedTechnicalOvertimeBound = overtime.Any(x => x > 0),
                ReconstructedFromStadtlerMasterData = true
            };
        }

        private static double[] ComputeNetMeanDemand(double[] meanPrimary, List<BomArc> bom, int j)
        {
            double[] net = (double[])meanPrimary.Clone();

            for (int pass = 0; pass < j; pass++)
            {
                bool changed = false;

                for (int component = j; component >= 1; component--)
                {
                    double candidate = meanPrimary[component - 1] +
                        bom.Where(x => x.Component == component)
                           .Sum(x => x.Quantity * net[x.Parent - 1]);

                    if (Math.Abs(candidate - net[component - 1]) > 1e-9)
                    {
                        net[component - 1] = candidate;
                        changed = true;
                    }
                }

                if (!changed) break;
            }

            return net;
        }

        private static double[] ComputeHoldingCosts(double[] marginal, List<BomArc> bom, int j)
        {
            double[] holding = (double[])marginal.Clone();

            for (int pass = 0; pass < j; pass++)
            {
                bool changed = false;

                for (int component = j; component >= 1; component--)
                {
                    double candidate = marginal[component - 1] +
                        bom.Where(x => x.Component == component)
                           .Sum(x => x.Quantity * holding[x.Parent - 1]);

                    if (Math.Abs(candidate - holding[component - 1]) > 1e-9)
                    {
                        holding[component - 1] = candidate;
                        changed = true;
                    }
                }

                if (!changed) break;
            }

            return holding;
        }

        private static double[,] ReadSparseMatrix(string path, int rows, int cols)
        {
            double[,] result = new double[rows, cols];

            foreach (var row in ReadRows(path))
                if (row.Length >= 3)
                    result[I(row[0]) - 1, I(row[1]) - 1] = row[2];

            return result;
        }

        private static List<BomArc> ReadBom(string path)
        {
            if (!File.Exists(path)) return new();

            var arcs = new List<BomArc>();

            foreach (var row in ReadRows(path))
            {
                if (row.Length < 3) continue;

                int component = I(row[0]);
                int parent = I(row[1]);
                double q = row[2];

                arcs.Add(new BomArc(parent, component, q));
            }

            return arcs;
        }

        private static double[,] ReadMatrix(string path, int rows, int cols)
        {
            var src = ReadRows(path);

            if (src.Count < rows)
                throw new InvalidDataException($"{Path.GetFileName(path)} has {src.Count} rows; expected {rows}.");

            var result = new double[rows, cols];

            for (int r = 0; r < rows; r++)
            {
                if (src[r].Length < cols)
                    throw new InvalidDataException($"{Path.GetFileName(path)} row {r + 1} has {src[r].Length} columns; expected {cols}.");

                for (int c = 0; c < cols; c++)
                    result[r, c] = src[r][c];
            }

            return result;
        }

        private static double[] ReadVector(string path, int count)
        {
            var values = ReadRows(path).SelectMany(x => x).ToArray();

            if (values.Length < count)
                throw new InvalidDataException($"{Path.GetFileName(path)} has {values.Length} values; expected {count}.");

            return values.Take(count).ToArray();
        }

        private static double[] ReadNumbers(string path)
            => ReadRows(path).SelectMany(x => x).ToArray();

        private static List<double[]> ReadRows(string path)
        {
            if (!File.Exists(path))
                throw new FileNotFoundException("Required source file missing.", path);

            var result = new List<double[]>();

            foreach (string raw in File.ReadLines(path))
            {
                string line = raw.Trim();
                if (line.Length == 0) continue;

                string[] tokens = line.Split(
                    new[] { ' ', '\t', ';', ',' },
                    StringSplitOptions.RemoveEmptyEntries);

                var nums = new List<double>();

                foreach (string token in tokens)
                {
                    string normalized = token.Replace(',', '.');

                    if (double.TryParse(
                        normalized,
                        NumberStyles.Float,
                        Inv,
                        out double value))
                    {
                        nums.Add(value);
                    }
                }

                if (nums.Count > 0)
                    result.Add(nums.ToArray());
            }

            return result;
        }

        private static int I(double value)
            => checked((int)Math.Round(value));
    }

    private sealed record BomArc(int Parent, int Component, double Quantity);
}
