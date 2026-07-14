namespace PalmierPro.Services.Media;

/// Minimal capacity-bounded LRU map: evicts the least-recently-used entry once `Count` would
/// exceed `capacity`. The Mac's `MediaVisualCache` dictionaries never evict (an acceptable
/// tradeoff there); this caps memory growth in a media panel with many/large assets. Not
/// thread-safe on its own — callers (only <see cref="MediaVisualCache"/> today) serialize access.
internal sealed class LruCache<TKey, TValue> where TKey : notnull
{
    private readonly int _capacity;
    private readonly Dictionary<TKey, LinkedListNode<(TKey Key, TValue Value)>> _nodes = [];
    private readonly LinkedList<(TKey Key, TValue Value)> _order = new();

    public LruCache(int capacity)
    {
        if (capacity <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(capacity));
        }
        _capacity = capacity;
    }

    public bool TryGet(TKey key, out TValue value)
    {
        if (_nodes.TryGetValue(key, out var node))
        {
            _order.Remove(node);
            _order.AddFirst(node);
            value = node.Value.Value;
            return true;
        }
        value = default!;
        return false;
    }

    public void Set(TKey key, TValue value)
    {
        if (_nodes.TryGetValue(key, out var existing))
        {
            _order.Remove(existing);
        }
        var node = new LinkedListNode<(TKey, TValue)>((key, value));
        _order.AddFirst(node);
        _nodes[key] = node;

        while (_nodes.Count > _capacity)
        {
            var oldest = _order.Last!;
            _order.RemoveLast();
            _nodes.Remove(oldest.Value.Key);
        }
    }

    public void Remove(TKey key)
    {
        if (_nodes.Remove(key, out var node))
        {
            _order.Remove(node);
        }
    }

    public void Clear()
    {
        _nodes.Clear();
        _order.Clear();
    }
}
