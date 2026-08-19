using System.Buffers.Binary;
using System.Text;

namespace PalmierPro.Core.Search;

public sealed record EmbeddingHit(string MediaRef, double Seconds, float Score);

/// <summary>PALMEMB1-compatible scaffold store (little-endian binary).</summary>
public sealed class EmbeddingStore
{
    public const uint Magic = 0x314D454D; // 'MEM1' little-endian as PALMEMB1 spirit
    public const int Dims = 64;

    private readonly List<(string MediaRef, double Seconds, float[] Vector)> _rows = [];

    public int Count => _rows.Count;

    public void Add(string mediaRef, double seconds, float[] vector)
    {
        if (vector.Length != Dims)
            throw new ArgumentException($"Expected {Dims}-d vector.", nameof(vector));
        _rows.Add((mediaRef, seconds, vector));
    }

    public IReadOnlyList<EmbeddingHit> Search(float[] query, int limit, string? mediaRef = null)
    {
        var scored = _rows
            .Where(r => mediaRef is null || r.MediaRef == mediaRef)
            .Select(r => new EmbeddingHit(r.MediaRef, r.Seconds, EmbeddingMath.Cosine(query, r.Vector)))
            .OrderByDescending(h => h.Score)
            .Take(Math.Max(1, limit));
        // Best per mediaRef
        return scored
            .GroupBy(h => h.MediaRef)
            .Select(g => g.First())
            .OrderByDescending(h => h.Score)
            .Take(Math.Max(1, limit))
            .ToList();
    }

    public void Save(string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        using var fs = File.Create(path);
        Span<byte> hdr = stackalloc byte[12];
        BinaryPrimitives.WriteUInt32LittleEndian(hdr, Magic);
        BinaryPrimitives.WriteInt32LittleEndian(hdr[4..], Dims);
        BinaryPrimitives.WriteInt32LittleEndian(hdr[8..], _rows.Count);
        fs.Write(hdr);
        Span<byte> meta = stackalloc byte[12];
        Span<byte> fb = stackalloc byte[4];
        foreach (var (mediaRef, seconds, vector) in _rows)
        {
            var nameBytes = Encoding.UTF8.GetBytes(mediaRef);
            BinaryPrimitives.WriteInt32LittleEndian(meta, nameBytes.Length);
            BinaryPrimitives.WriteInt64LittleEndian(meta[4..], BitConverter.DoubleToInt64Bits(seconds));
            fs.Write(meta);
            fs.Write(nameBytes);
            foreach (var f in vector)
            {
                BinaryPrimitives.WriteSingleLittleEndian(fb, f);
                fs.Write(fb);
            }
        }
    }

    public static EmbeddingStore Load(string path)
    {
        var store = new EmbeddingStore();
        using var fs = File.OpenRead(path);
        Span<byte> hdr = stackalloc byte[12];
        fs.ReadExactly(hdr);
        if (BinaryPrimitives.ReadUInt32LittleEndian(hdr) != Magic)
            throw new InvalidDataException("Not a PALMEMB1 embedding store.");
        var dims = BinaryPrimitives.ReadInt32LittleEndian(hdr[4..]);
        var count = BinaryPrimitives.ReadInt32LittleEndian(hdr[8..]);
        if (dims != Dims) throw new InvalidDataException($"Unexpected dims {dims}.");
        Span<byte> meta = stackalloc byte[12];
        Span<byte> fb = stackalloc byte[4];
        for (var i = 0; i < count; i++)
        {
            fs.ReadExactly(meta);
            var nameLen = BinaryPrimitives.ReadInt32LittleEndian(meta);
            var seconds = BitConverter.Int64BitsToDouble(BinaryPrimitives.ReadInt64LittleEndian(meta[4..]));
            var nameBytes = new byte[nameLen];
            fs.ReadExactly(nameBytes);
            var vector = new float[dims];
            for (var d = 0; d < dims; d++)
            {
                fs.ReadExactly(fb);
                vector[d] = BinaryPrimitives.ReadSingleLittleEndian(fb);
            }
            store._rows.Add((Encoding.UTF8.GetString(nameBytes), seconds, vector));
        }
        return store;
    }
}
