using System.Net;
using System.Text;
using PalmierPro.Cloud.Samples;
using PalmierPro.Core;
using Xunit;

namespace PalmierPro.Cloud.Tests;

public class SampleProjectClientTests
{
    [Fact]
    public async Task MaterializeWritesPackageFromResolveResponse()
    {
        var port = FreePort();
        using var listener = new HttpListener();
        listener.Prefixes.Add($"http://127.0.0.1:{port}/");
        listener.Start();

        var serve = Task.Run(async () =>
        {
            while (listener.IsListening)
            {
                HttpListenerContext ctx;
                try { ctx = await listener.GetContextAsync(); }
                catch (HttpListenerException) { break; }
                catch (ObjectDisposedException) { break; }

                var path = ctx.Request.Url!.AbsolutePath;
                byte[] body;
                string type;
                if (path.Contains("resolve", StringComparison.Ordinal))
                {
                    var resolve = $$"""
                    {
                      "title": "Demo Sample",
                      "project": { "name": "Demo", "fps": 30, "tracks": [] },
                      "manifest": { "version": 1, "media": [] },
                      "downloads": [
                        { "relativePath": "media/clip.bin", "url": "http://127.0.0.1:{{port}}/file.bin" }
                      ],
                      "chat": []
                    }
                    """;
                    body = Encoding.UTF8.GetBytes(resolve);
                    type = "application/json";
                }
                else
                {
                    body = [1, 2, 3, 4];
                    type = "application/octet-stream";
                }
                ctx.Response.ContentType = type;
                ctx.Response.ContentLength64 = body.Length;
                await ctx.Response.OutputStream.WriteAsync(body);
                ctx.Response.Close();
            }
        });

        try
        {
            // Temporarily point HTTP base via env for this process.
            var prev = Environment.GetEnvironmentVariable("PALMIER_CONVEX_HTTP_URL");
            Environment.SetEnvironmentVariable("PALMIER_CONVEX_HTTP_URL", $"http://127.0.0.1:{port}/");
            try
            {
                var path = await SampleProjectClient.Shared.MaterializeAsync("demo");
                Assert.True(Directory.Exists(path));
                Assert.EndsWith("." + ProjectConstants.FileExtension, path, StringComparison.OrdinalIgnoreCase);
                Assert.True(File.Exists(Path.Combine(path, ProjectConstants.TimelineFilename)));
                Assert.True(File.Exists(Path.Combine(path, ProjectConstants.ManifestFilename)));
                Assert.Equal([1, 2, 3, 4], File.ReadAllBytes(Path.Combine(path, "media", "clip.bin")));
            }
            finally
            {
                Environment.SetEnvironmentVariable("PALMIER_CONVEX_HTTP_URL", prev);
            }
        }
        finally
        {
            listener.Stop();
            try { await serve.WaitAsync(TimeSpan.FromSeconds(2)); } catch { /* ignore */ }
        }
    }

    private static int FreePort()
    {
        var l = new System.Net.Sockets.TcpListener(IPAddress.Loopback, 0);
        l.Start();
        var port = ((IPEndPoint)l.LocalEndpoint).Port;
        l.Stop();
        return port;
    }
}
