using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using System.Xml;
using System.Xml.Linq;
using System.Xml.Serialization;
using LotSizingDataModel.Instance;
using LotSizingDataModel.Instance.Creation;
using LotSizingDataModel.Instance.Classification;
using LotSizingDataModel.Instance.Descriptors;
using LotSizingDataModel.Instance.Notation;
using LotSizingDataModel.Instance.Notation.Lsi;

internal static class Program
{
    static readonly JsonSerializerOptions Json = new() { WriteIndented = true, Converters = { new JsonStringEnumConverter() } };
    static readonly XmlSerializer Serializer = new(typeof(LotSizingInstance));
    static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes));
    static XElement Normalize(XElement e) => new XElement(e.Name.LocalName,
        e.Attributes().Where(a => !a.IsNamespaceDeclaration).OrderBy(a => a.Name.ToString(), StringComparer.Ordinal)
            .Select(a => new XAttribute(a.Name.NamespaceName == "http://www.w3.org/2001/XMLSchema-instance" ? a.Name : a.Name.LocalName, a.Value)),
        e.HasElements ? e.Elements().Select(x => (object)Normalize(x)) : e.Value);
    static string Canonical(XElement e) => Normalize(e).ToString(SaveOptions.DisableFormatting);
    static LotSizingInstance Load(byte[] bytes)
    {
        using var stream = new MemoryStream(bytes);
        using var reader = XmlReader.Create(stream, new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null });
        return (LotSizingInstance)(Serializer.Deserialize(reader) ?? throw new InvalidDataException("Null instance"));
    }
    static byte[] Save(LotSizingInstance instance)
    {
        using var stream = new MemoryStream();
        using (var writer = XmlWriter.Create(stream, new XmlWriterSettings { Encoding = new UTF8Encoding(false), Indent = false })) Serializer.Serialize(writer, instance);
        return stream.ToArray();
    }
    static XElement Element(byte[] bytes, string name) => XDocument.Load(new MemoryStream(bytes)).Root!.Elements().Single(x => x.Name.LocalName == name);
    static void MainGuard(bool ok, string message) { if (!ok) throw new InvalidDataException(message); }
    static int Main(string[] args)
    {
        if (args.Length < 3) { Console.Error.WriteLine("DataModelAlignment <registry.json> <output> <expected-count> [probe]"); return 2; }
        string output = Path.GetFullPath(args[1]); Directory.CreateDirectory(output);
        var rows = JsonNode.Parse(File.ReadAllText(args[0]))!.AsArray();
        MainGuard(rows.Count == int.Parse(args[2]), "Registry row count mismatch");
        bool probe = args.Length > 3 && args[3] == "probe";
        var selected = probe ? rows.Select(n => n!.AsObject()).GroupBy(r => (string)r["family"]!).Select(g => g.First()).ToArray() : rows.Select(n => n!.AsObject()).ToArray();
        var evidence = new List<object>();
        int failed = 0, count = 0;
        foreach (var row in selected)
        {
            string id = (string)row["global_instance_id"]!;
            string path = (string)row["canonical_xml_path"]!;
            try
            {
                byte[] bytes = File.ReadAllBytes(path);
                MainGuard(Hash(bytes).Equals((string)row["canonical_xml_sha256"]!, StringComparison.OrdinalIgnoreCase), "Source SHA256 mismatch");
                var instance = Load(bytes);
                string fingerprint = LotSizingInstanceFactory.ComputeSupplyChainFingerprint(instance.SupplyChain);
                bool historicalFingerprint = fingerprint == (string)row["fingerprint"]!;
                byte[] serialized = Save(instance);
                string originalChain = Canonical(Element(bytes, "supplyChain"));
                string newChain = Canonical(Element(serialized, "supplyChain"));
                bool xmlEqual = originalChain == newChain;
                var roundtrip = Load(serialized);
                bool roundtripFingerprint = LotSizingInstanceFactory.ComputeSupplyChainFingerprint(roundtrip.SupplyChain) == fingerprint;
                var originalRoot = XDocument.Load(new MemoryStream(bytes)).Root!;
                var restoredRoot = XDocument.Load(new MemoryStream(serialized)).Root!;
                var originalKnown = originalRoot.Elements().SingleOrDefault(e => e.Name.LocalName == "knownResults");
                var restoredKnown = restoredRoot.Elements().SingleOrDefault(e => e.Name.LocalName == "knownResults");
                bool knownResultsEqual = (originalKnown == null ? "" : Canonical(originalKnown)) == (restoredKnown == null ? "" : Canonical(restoredKnown));
                bool identityEqual = instance.InstanceId == roundtrip.InstanceId && instance.BestKnownResultId == roundtrip.BestKnownResultId;
                var features = LotSizingProblemFeatureExtractor.Extract(instance.SupplyChain);
                var descriptor = LotSizingProblemDescriptor.FromLegacyFeatures(features, instance.SupplyChain);
                var universal = new UniversalNotationGenerator().Generate(descriptor);
                var projection = new Lsi10ScientificProjector().Project(descriptor, universal);
                row["DataModelVersion"] = "1.3.0";
                row["UniversalNotation"] = projection.UniversalNotationText;
                row["Lsi10Notation"] = projection.CanonicalText;
                row["LegacyFamily"] = projection.LegacyProblemFamily;
                row["ProductStructureDeclared"] = instance.ProductStructure.DeclaredType.ToString();
                row["ProductStructureDetected"] = descriptor.Structure.ProductStructureType.ToString();
                row["CapacityProfile"] = JsonSerializer.SerializeToNode(new { Regime = descriptor.ProductionCapacityRegime, Facts = descriptor.Capacity }, Json);
                row["SetupFeatures"] = JsonSerializer.SerializeToNode(descriptor.Setup, Json);
                row["LeadTimeFeatures"] = JsonSerializer.SerializeToNode(new { Production = descriptor.Production.HasLeadTimes, Supplier = descriptor.Procurement.HasSupplierLeadTimes, Transport = descriptor.TransportationDistribution.HasTransportLeadTimes }, Json);
                row["ShortageFeatures"] = JsonSerializer.SerializeToNode(new { descriptor.InventoryService.HasBacklogging, descriptor.InventoryService.HasLostSales }, Json);
                row["SchedulingFeatures"] = JsonSerializer.SerializeToNode(descriptor.Scheduling, Json);
                row["SetupFamilyFeatures"] = JsonSerializer.SerializeToNode(new { descriptor.Setup.HasProductionSetupFamilies, descriptor.Setup.HasProductionSetupFamilyTimes }, Json);
                row["ClassificationConfidence"] = null;
                row["ClassificationWarnings"] = new JsonArray("Classification confidence is not exposed by the Descriptor/LSI projection API.");
                row["DetectedItemCount"] = descriptor.Structure.ItemCount;
                row["DetectedPlanningHorizon"] = descriptor.Time.PlanningHorizon;
                row["DetectedWorkCenterCount"] = descriptor.Structure.WorkCenterCount;
                MainGuard(LotSizingInstanceFactory.ComputeSupplyChainFingerprint(instance.SupplyChain) == fingerprint, "Classification mutated source data");
                bool pass = historicalFingerprint && xmlEqual && roundtripFingerprint && knownResultsEqual && identityEqual;
                if (!pass)
                {
                    failed++;
                    string stem = Hash(Encoding.UTF8.GetBytes(id));
                    File.WriteAllText(Path.Combine(output, stem + "-original-supply-chain.xml"), originalChain);
                    File.WriteAllText(Path.Combine(output, stem + "-roundtrip-supply-chain.xml"), newChain);
                }
                evidence.Add(new { id, path, historicalFingerprint, expectedFingerprint = (string)row["fingerprint"]!, actualFingerprint = fingerprint, xmlEqual, roundtripFingerprint, knownResultsEqual, identityEqual, pass });
            }
            catch (Exception ex) { failed++; evidence.Add(new { id, path, pass = false, error = ex.ToString() }); }
            count++; if (count % 100 == 0) Console.WriteLine($"PROGRESS|{count}|FAILURES|{failed}");
        }
        File.WriteAllText(Path.Combine(output, "preservation-evidence.json"), JsonSerializer.Serialize(evidence, Json));
        File.WriteAllText(Path.Combine(output, "classification-candidate.json"), JsonSerializer.Serialize(selected, Json));
        Console.WriteLine($"ROWS|{count}\nFAILURES|{failed}\nResult: {(failed == 0 ? "PASS" : "BLOCKED")}");
        return failed == 0 ? 0 : 1;
    }
}
