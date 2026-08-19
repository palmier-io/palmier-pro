namespace PalmierPro.Core.Models;

public static class VolumeScale
{
    public const double FloorDb = -60;
    public const double CeilingDb = 15;

    public static double DbFromLinear(double linear)
    {
        if (linear <= 0) return FloorDb;
        return Math.Min(CeilingDb, Math.Max(FloorDb, 20 * Math.Log10(linear)));
    }

    public static double LinearFromDb(double db)
    {
        if (db <= FloorDb) return 0;
        return Math.Pow(10, Math.Min(db, CeilingDb) / 20);
    }
}
