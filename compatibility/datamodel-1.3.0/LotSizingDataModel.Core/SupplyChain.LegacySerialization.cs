namespace LotSizingDataModel.Core;

public sealed partial class SupplyChain
{
    /// <summary>Keep an absent optional sales collection absent in historical XML.</summary>
    public bool ShouldSerializeSalesOptions() => SalesOptions.Count > 0;
}
