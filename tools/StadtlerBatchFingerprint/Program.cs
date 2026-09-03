
using System.Text;
using System.Xml.Serialization;
using LotSizingDataModel.Instance;
using LotSizingDataModel.Instance.Creation;

internal static class Program
{
    private static int Main(string[] args)
    {
        if (args.Length != 3)
        {
            Console.Error.WriteLine(
                "Usage: StadtlerBatchFingerprint <family> <manifest.txt> <output.csv>");
            return 2;
        }

        string family = args[0];
        string manifest = Path.GetFullPath(args[1]);
        string output = Path.GetFullPath(args[2]);

        if (!File.Exists(manifest))
        {
            Console.Error.WriteLine("Manifest not found: " + manifest);
            return 3;
        }

        var files = File.ReadAllLines(manifest)
            .Select(x => x.Trim())
            .Where(x => x.Length > 0)
            .Select(Path.GetFullPath)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(x => x, StringComparer.OrdinalIgnoreCase)
            .ToArray();

        Directory.CreateDirectory(Path.GetDirectoryName(output)!);

        var serializer = new XmlSerializer(typeof(LotSizingInstance));
        var rows = new List<Row>(files.Length);
        int failures = 0;

        for (int i = 0; i < files.Length; i++)
        {
            string file = files[i];

            try
            {
                using var stream = File.OpenRead(file);
                var instance = serializer.Deserialize(stream) as LotSizingInstance;

                if (instance is null)
                    throw new InvalidDataException("Deserialization returned null.");

                string fingerprint =
                    LotSizingInstanceFactory.ComputeSupplyChainFingerprint(instance.SupplyChain);

                rows.Add(new Row(
                    family,
                    file,
                    Path.GetFileName(file),
                    instance.InstanceId ?? "",
                    instance.Name ?? "",
                    fingerprint));
            }
            catch (Exception ex)
            {
                failures++;
                Console.WriteLine(
                    $"FAIL|{family}|{file}|{ex.GetType().Name}|{ex.Message}");
            }

            int done = i + 1;
            if (done % 250 == 0 || done == files.Length)
                Console.WriteLine($"PROGRESS|{family}|{done}/{files.Length}");
        }

        using var writer = new StreamWriter(
            output,
            false,
            new UTF8Encoding(false));

        writer.WriteLine("family,path,filename,instance_id,name,fingerprint");

        foreach (var row in rows)
            writer.WriteLine(Csv(
                row.Family,
                row.Path,
                row.Filename,
                row.InstanceId,
                row.Name,
                row.Fingerprint));

        Console.WriteLine(
            $"SUMMARY|{family}|files={files.Length}|fingerprinted={rows.Count}|failures={failures}");

        return failures == 0 ? 0 : 4;
    }

    private static string Csv(params string[] values) =>
        string.Join(",", values.Select(v =>
            "\"" + (v ?? "").Replace("\"", "\"\"") + "\""));

    private sealed record Row(
        string Family,
        string Path,
        string Filename,
        string InstanceId,
        string Name,
        string Fingerprint);
}
