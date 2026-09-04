using System.Xml.Linq;
using System.Xml.Serialization;
using LotSizingDataModel.Core;
using LotSizingDataModel.Core.Relationships;
using Xunit;

namespace LotSizingDataModel.Core.Tests;

public sealed class LegacySerializationCompatibilityTests
{
    static string Serialize<T>(T value)
    {
        using var writer = new StringWriter();
        new XmlSerializer(typeof(T)).Serialize(writer, value);
        return writer.ToString();
    }
    static T Deserialize<T>(string xml)
    {
        using var reader = new StringReader(xml);
        return (T)new XmlSerializer(typeof(T)).Deserialize(reader)!;
    }

    [Fact]
    public void HistoricalInventoryOmitsNewDefaultAttributes()
    {
        var inventory = new Inventory();
        var xml = Serialize(inventory);
        Assert.DoesNotContain("initialInventoryDecisionMode=", xml);
        Assert.DoesNotContain("initialInventoryDecisionUnitCost=", xml);
        var restored = Deserialize<Inventory>(xml);
        Assert.Equal(InitialInventoryDecisionMode.FixedParameter, restored.InitialInventoryDecisionMode);
        Assert.Equal(0.0, restored.InitialInventoryDecisionUnitCost);
    }

    [Theory]
    [InlineData(InitialInventoryDecisionMode.VariableDecision, 0.0)]
    [InlineData(InitialInventoryDecisionMode.VariableDecision, 12.25)]
    [InlineData(InitialInventoryDecisionMode.AbsentFixedZero, 0.0)]
    [InlineData(InitialInventoryDecisionMode.FixedParameter, 5.5)]
    public void NondefaultInventorySemanticsRoundtrip(InitialInventoryDecisionMode mode, double cost)
    {
        var inventory = new Inventory { InitialInventoryDecisionMode = mode, InitialInventoryDecisionUnitCost = cost };
        var restored = Deserialize<Inventory>(Serialize(inventory));
        Assert.Equal(mode, restored.InitialInventoryDecisionMode);
        Assert.Equal(cost, restored.InitialInventoryDecisionUnitCost);
    }

    [Fact]
    public void EmptySalesCollectionRemainsAbsent()
    {
        var chain = new SupplyChain();
        Assert.DoesNotContain("salesOptions", Serialize(chain));
        Assert.Empty(Deserialize<SupplyChain>(Serialize(chain)).SalesOptions);
    }

    [Fact]
    public void NonemptySalesCollectionIsRetained()
    {
        var chain = new SupplyChain();
        chain.SalesOptions.Add(new SalesOption());
        var xml = Serialize(chain);
        Assert.NotNull(XDocument.Parse(xml).Root!.Element("salesOptions"));
        Assert.Single(Deserialize<SupplyChain>(xml).SalesOptions);
    }
}
