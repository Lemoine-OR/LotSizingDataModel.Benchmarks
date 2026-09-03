
using System.Text.Json;

internal static class Program
{
    private static int Main(string[] args)
    {
        if (args.Length != 2)
        {
            Console.Error.WriteLine(
                "Usage: GlobalRegistryValidator <registry-json> <expected-count>");
            return 2;
        }

        string path = Path.GetFullPath(args[0]);

        if (!int.TryParse(
            args[1],
            out int expected) ||
            expected <= 0)
        {
            Console.Error.WriteLine(
                "Invalid expected count.");
            return 3;
        }

        using JsonDocument doc =
            JsonDocument.Parse(
                File.ReadAllText(path));

        if (doc.RootElement.ValueKind !=
            JsonValueKind.Array)
        {
            Console.Error.WriteLine(
                "Registry JSON root must be an array.");
            return 4;
        }

        int count =
            doc.RootElement.GetArrayLength();

        if (count != expected)
        {
            Console.Error.WriteLine(
                $"Registry count mismatch: {count} != {expected}");
            return 5;
        }

        var globalIds =
            new HashSet<string>(
                StringComparer.OrdinalIgnoreCase);

        var paths =
            new HashSet<string>(
                StringComparer.OrdinalIgnoreCase);

        var familyCounts =
            new Dictionary<string,int>(
                StringComparer.OrdinalIgnoreCase);

        foreach (JsonElement row in
            doc.RootElement.EnumerateArray())
        {
            string globalId =
                RequiredString(
                    row,
                    "global_instance_id");

            string family =
                RequiredString(
                    row,
                    "family");

            string xmlPath =
                RequiredString(
                    row,
                    "canonical_xml_path");

            string fingerprint =
                RequiredString(
                    row,
                    "fingerprint");

            if (!globalIds.Add(globalId))
            {
                Console.Error.WriteLine(
                    "Duplicate global_instance_id: " +
                    globalId);
                return 6;
            }

            if (!paths.Add(xmlPath))
            {
                Console.Error.WriteLine(
                    "Duplicate canonical_xml_path: " +
                    xmlPath);
                return 7;
            }

            if (fingerprint.Length < 8)
            {
                Console.Error.WriteLine(
                    "Missing/invalid fingerprint for " +
                    globalId);
                return 8;
            }

            if (!familyCounts.TryAdd(
                family,
                1))
            {
                familyCounts[family]++;
            }
        }

        string[] requiredFamilies =
        {
            "DJ2000",
            "STADTLER2003",
            "SUERIE_CLSPL",
            "TRIGEIRO1989",
            "TD1996",
            "CATTRYSSE1990"
        };

        foreach (string family in requiredFamilies)
        {
            if (!familyCounts.ContainsKey(family))
            {
                Console.Error.WriteLine(
                    "Missing family: " +
                    family);
                return 9;
            }
        }

        Console.WriteLine(
            "GLOBAL_REGISTRY_VALID");

        Console.WriteLine(
            "ROWS|" +
            count);

        foreach (var pair in
            familyCounts
                .OrderBy(
                    x => x.Key,
                    StringComparer.OrdinalIgnoreCase))
        {
            Console.WriteLine(
                $"FAMILY|{pair.Key}|{pair.Value}");
        }

        return 0;
    }

    private static string RequiredString(
        JsonElement row,
        string property)
    {
        if (!row.TryGetProperty(
            property,
            out JsonElement value) ||
            value.ValueKind !=
                JsonValueKind.String)
        {
            throw new InvalidDataException(
                "Missing property: " +
                property);
        }

        string? text =
            value.GetString();

        if (string.IsNullOrWhiteSpace(text))
        {
            throw new InvalidDataException(
                "Empty property: " +
                property);
        }

        return text;
    }
}
