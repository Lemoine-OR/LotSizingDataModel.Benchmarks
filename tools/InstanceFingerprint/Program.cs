using System.Xml.Serialization;
using LotSizingDataModel.Instance;
using LotSizingDataModel.Instance.Creation;

internal static class Program
{
    private static int Main(string[] args)
    {
        if (args.Length < 1)
        {
            Console.Error.WriteLine("Usage: InstanceFingerprint <xml-or-directory>");
            return 2;
        }

        string input = Path.GetFullPath(args[0]);
        var files = File.Exists(input)
            ? new[] { input }
            : Directory.EnumerateFiles(input, "*.xml", SearchOption.TopDirectoryOnly)
                .OrderBy(x => x, StringComparer.OrdinalIgnoreCase)
                .ToArray();

        var serializer = new XmlSerializer(typeof(LotSizingInstance));

        foreach (string file in files)
        {
            try
            {
                using var stream = File.OpenRead(file);
                var instance = (LotSizingInstance?)serializer.Deserialize(stream);
                if (instance is null)
                    throw new InvalidDataException("Deserialization returned null.");

                string fingerprint =
                    LotSizingInstanceFactory.ComputeSupplyChainFingerprint(
                        instance.SupplyChain);

                Console.WriteLine(
                    "OK|" +
                    file + "|" +
                    instance.InstanceId + "|" +
                    instance.Name + "|" +
                    fingerprint);
            }
            catch (Exception ex)
            {
                Console.WriteLine(
                    "FAIL|" +
                    file + "|" +
                    ex.GetType().Name + "|" +
                    ex.Message);
            }
        }

        return 0;
    }
}
