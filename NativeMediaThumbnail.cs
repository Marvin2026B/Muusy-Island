using System;
using System.IO;
using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Storage.Streams;

public static class NativeMediaThumbnail
{
    public static byte[] Read(IRandomAccessStreamReference reference)
    {
        if (reference == null) return null;

        using (var random = reference.OpenReadAsync().AsTask().GetAwaiter().GetResult())
        using (var input = random.AsStreamForRead())
        using (var memory = new MemoryStream())
        {
            input.CopyTo(memory);
            return memory.ToArray();
        }
    }
}
