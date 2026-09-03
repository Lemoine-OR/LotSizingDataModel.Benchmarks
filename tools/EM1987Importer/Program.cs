using System.Globalization;
using System.Security.Cryptography;
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
    const int Plant=1, WorkCenter=1, DistributionCenter=1;
    static int Main(string[] args)
    {
        if(args.Length!=3){Console.Error.WriteLine("Usage: EM1987Importer <source-dir> <output-dir> <report-dir>");return 2;}
        var src=Path.GetFullPath(args[0]);var dst=Path.GetFullPath(args[1]);var rep=Path.GetFullPath(args[2]);
        Directory.CreateDirectory(dst);Directory.CreateDirectory(rep);
        var files=Directory.GetFiles(src,"MARTIN*.dat").OrderBy(Number).ToArray();var rows=new List<string>();int ok=0;
        foreach(var file in files) try {
            var d=Read(file);var id=Path.GetFileNameWithoutExtension(file).ToUpperInvariant();
            var name=$"LSDM_EM1987_CLSP_{d.Items}items_{d.Periods}periods_{id}.xml";
            Serialize(Build(d,id,file),Path.Combine(dst,name));ok++;
            rows.Add(Csv(id,file,Sha(file),d.Items.ToString(),d.Periods.ToString(),d.Subfamily,name,"CONVERTED",""));
            Console.WriteLine($"OK|{id}|items={d.Items}|periods={d.Periods}|{name}");
        } catch(Exception e) {rows.Add(Csv(Path.GetFileNameWithoutExtension(file),file,Sha(file),"0","0","","","REJECTED",e.Message));Console.WriteLine($"FAIL|{file}|{e.Message}");}
        File.WriteAllLines(Path.Combine(rep,"EM1987-CONVERSION-MANIFEST.csv"),new[]{"instance_id,source_path,source_sha256,items,periods,subfamily,xml_file,status,diagnostic"}.Concat(rows),new UTF8Encoding(false));
        Console.WriteLine($"SUMMARY|files={files.Length}|converted={ok}|rejected={files.Length-ok}");return files.Length==17&&ok==17?0:4;
    }
    static Data Read(string path)
    {
        var map=new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
        foreach(var raw in File.ReadAllLines(path,Encoding.Latin1)){var p=raw.IndexOf('=');if(p>0)map[raw[..p].Trim()]=raw[(p+1)..].Trim();}
        int periods=Int(map,"NB_PERIODES"),items=Int(map,"NB_PRODUITS");
        var demand=new double[items,periods];var setup=new double[items];var holding=new double[items];var prod=new double[items];var unit=new double[items];var setupTime=new double[items];
        for(int j=0;j<items;j++){var v=Array(map,$"Demande{j+1}",periods);for(int t=0;t<periods;t++)demand[j,t]=v[t];setup[j]=Scalar(map,$"CL_Produit{j+1}");holding[j]=Scalar(map,$"CS_Produit{j+1}");prod[j]=Scalar(map,$"CP_Produit{j+1}");unit[j]=Scalar(map,$"C_t_p_Produit{j+1}");setupTime[j]=Scalar(map,$"C_t_l_Produit{j+1}");}
        var capacity=Array(map,"Capacite_machine",periods);foreach(var x in demand.Cast<double>().Concat(setup).Concat(holding).Concat(prod).Concat(unit).Concat(setupTime).Concat(capacity))if(!double.IsFinite(x)||x<0)throw new InvalidDataException("Negative or non-finite value.");
        return new(items,periods,demand,setup,holding,prod,capacity,unit,setupTime,$"EM-{items}x{periods}");
    }
    static LotSizingInstance Build(Data d,string id,string source)
    {
        var b=new SupplyChainModelBuilder(d.Periods);b.AddPlant(new Plant(Plant,"Eppen-Martin benchmark plant",new PlantWarehouse("Plant warehouse")));
        var wc=new LotSizingDataModel.Core.PhysicalModel.WorkCenter(WorkCenter,"Single capacitated resource"){CapacityConstraint=new CapacityConstraint(d.Periods)};for(int t=1;t<=d.Periods;t++)wc.CapacityConstraint.SetMaximumCapacity(t,d.Capacity[t-1]);b.AddWorkCenter(Plant,wc);b.AddDistributionCenter(new DistributionCenter(DistributionCenter,"External demand"));
        for(int j=1;j<=d.Items;j++){b.AddItem(j,"Item "+j,0);var r=new ProductionRouting(j,j,Plant,0);r.AddWorkCenter(new WorkCenterReference(Plant,WorkCenter));b.AddProductionRouting(r);b.AddProductionCharacteristic(new ProductionCharacteristic{ItemId=j,WorkCenter=new WorkCenterReference(Plant,WorkCenter),UnitCapacityConsumption=new UnitCapacityConsumption(d.Periods,d.UnitTime[j-1]),SetupTime=new SetupTime(d.Periods,d.SetupTime[j-1]),FixedSetupCost=new FixedSetupCost(d.Periods,d.Setup[j-1]),UnitUsageCost=new UnitUsageCost(d.Periods,d.Production[j-1])});var inv=Inventory.ForPlantWarehouse(j,Plant,0);inv.UnitUsageCost=new UnitUsageCost(d.Periods,d.Holding[j-1]);b.AddInventory(inv);var dem=new Demand(j,DistributionCenter,d.Periods);for(int t=1;t<=d.Periods;t++)dem.SetQuantity(t,d.Demand[j-1,t-1]);b.AddDemand(dem);b.AddDistributionCenterSourcing(new DistributionCenterSourcing{DistributionCenterId=DistributionCenter,ItemId=j,Warehouse=WarehouseReference.ForPlantWarehouse(Plant)});}
        var x=LotSizingInstanceFactory.Create(instanceId:"EM1987-"+id,supplyChain:b.Build(true),name:"Eppen-Martin "+id,declaredProductStructureType:ProductStructureType.IndependentItems,analyzeProductStructure:true,classifyProblem:true,createdBy:"LotSizingDataModel.Benchmarks EM1987Importer v0.21.0");x.Description="Eppen-Martin single-level capacitated lot-sizing benchmark imported losslessly from the user-provided archive.";x.SourceInformation=$"Source archive: Eppen Martin.zip; archive SHA256=A2D5C857F446A2441ACF842D4A73DDC35DD4B8B4E00B7D7F5A0701824A646F5D; file={Path.GetFileName(source)}; file SHA256={Sha(source)}; DOI=10.1287/opre.35.6.832.";foreach(var tag in new[]{"Eppen-Martin","Eppen-Martin-1987","CLSP","single-level","capacitated","single-resource",d.Subfamily})x.Tags.Add(tag);return x;
    }
    static void Serialize(LotSizingInstance x,string path){var s=new XmlSerializer(typeof(LotSizingInstance));using var w=XmlWriter.Create(path,new XmlWriterSettings{Indent=true,Encoding=new UTF8Encoding(false)});s.Serialize(w,x);}
    static int Int(Dictionary<string,string> m,string k){var x=Scalar(m,k);if(x<=0||x!=Math.Round(x))throw new InvalidDataException("Invalid integer: "+k);return checked((int)x);}
    static double Scalar(Dictionary<string,string> m,string k)=>Array(m,k,1)[0];
    static double[] Array(Dictionary<string,string> m,string k,int n){if(!m.TryGetValue(k,out var s))throw new InvalidDataException("Missing field: "+k);var a=Regex.Matches(s,@"[+-]?\d+(?:[\.,]\d*)?").Select(z=>double.Parse(z.Value.Replace(',','.'),CultureInfo.InvariantCulture)).ToArray();if(a.Length!=n)throw new InvalidDataException($"Cardinality mismatch for {k}: {a.Length}/{n}");return a;}
    static int Number(string p)=>int.Parse(Regex.Match(Path.GetFileName(p),@"\d+").Value,CultureInfo.InvariantCulture);
    static string Sha(string p){using var f=File.OpenRead(p);return Convert.ToHexString(SHA256.HashData(f));}
    static string Csv(params string[] a)=>string.Join(",",a.Select(x=>"\""+x.Replace("\"","\"\"")+"\""));
    sealed record Data(int Items,int Periods,double[,] Demand,double[] Setup,double[] Holding,double[] Production,double[] Capacity,double[] UnitTime,double[] SetupTime,string Subfamily);
}
