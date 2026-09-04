namespace LotSizingDataModel.Core.Relationships;

public sealed partial class Inventory
{
    /// <summary>Omit the historical default; explicit alternative modes remain serialized.</summary>
    public bool ShouldSerializeInitialInventoryDecisionMode() =>
        InitialInventoryDecisionMode != InitialInventoryDecisionMode.FixedParameter;

    /// <summary>Omit the default zero coefficient, retaining every nonzero value.</summary>
    public bool ShouldSerializeInitialInventoryDecisionUnitCost() =>
        InitialInventoryDecisionUnitCost != 0.0;
}
