using System.Security.Cryptography;
using System.Text;
using ClaudeMirror.Core;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Crypto.Signers;
using Org.BouncyCastle.Security;
using Xunit;

public class StableUpdateTests
{
    [Fact]
    public async Task RejectsChangedInstallerManifestAndReplayedVersion()
    {
        var key=new Ed25519PrivateKeyParameters(new SecureRandom());
        var pub=key.GeneratePublicKey().GetEncoded();
        var contents=Encoding.UTF8.GetBytes("A Windows test package");
        var manifest=System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(new {
            tag="v3.2.1", asset=StableUpdate.Installer, length=contents.Length,
            sha256=Convert.ToHexString(SHA256.HashData(contents))
        });
        var signer=new Ed25519Signer();
        signer.Init(true,key);signer.BlockUpdate(manifest,0,manifest.Length);
        var sig=signer.GenerateSignature();
        var update=StableUpdate.VerifyManifest("v3.2.1",manifest,sig,pub);
        Assert.Throws<InvalidDataException>(()=>StableUpdate.VerifyManifest("v3.2.2",manifest,sig,pub));
        var path=Path.GetTempFileName();
        try {
            await File.WriteAllBytesAsync(path,contents);
            await update.VerifyFileAsync(path,default);
            contents[0]^=1; await File.WriteAllBytesAsync(path,contents);
            await Assert.ThrowsAsync<InvalidDataException>(()=>update.VerifyFileAsync(path,default));
        } finally { File.Delete(path); }
        manifest[^1]^=1;
        Assert.Throws<InvalidDataException>(()=>StableUpdate.VerifyManifest("v3.2.1",manifest,sig,pub));
        Assert.NotNull(StableUpdate.CurrentVersion);
    }

    [Fact]
    public async Task ResumesAnInterruptedDownload()
    {
        var contents=new byte[300_000]; Random.Shared.NextBytes(contents);
        var update=new StableUpdate("v3.2.1",contents.Length,Convert.ToHexString(SHA256.HashData(contents)));
        var port=System.Net.IPEndPoint.Parse("127.0.0.1:0");
        using var socket=new System.Net.Sockets.TcpListener(port); socket.Start();
        var url=$"http://127.0.0.1:{((System.Net.IPEndPoint)socket.LocalEndpoint).Port}/";
        socket.Stop();
        using var listener=new System.Net.HttpListener(); listener.Prefixes.Add(url); listener.Start();
        long? asked=null;
        var serving=Task.Run(async()=>{
            var context=await listener.GetContextAsync();
            var range=context.Request.Headers["Range"];
            asked=range is null ? 0 : long.Parse(range["bytes=".Length..].TrimEnd('-'));
            context.Response.StatusCode=asked>0 ? 206 : 200;
            await context.Response.OutputStream.WriteAsync(contents.AsMemory((int)asked.Value));
            context.Response.Close();
        });
        var directory=Path.Combine(Path.GetTempPath(),Guid.NewGuid().ToString());
        try {
            Directory.CreateDirectory(directory);
            await File.WriteAllBytesAsync(Path.Combine(directory,"Tether-v3.2.1-Setup.exe.part"),contents[..100_000]);
            await File.WriteAllBytesAsync(Path.Combine(directory,"Tether-v3.2.0-Setup.exe.part"),[1]);
            var path=await update.StageAsync(directory,new Uri(url),default);
            await serving;
            Assert.Equal(100_000,asked);
            Assert.Equal(contents,await File.ReadAllBytesAsync(path));
            Assert.Equal([path],Directory.GetFiles(directory));
        } finally { Directory.Delete(directory,true); }
    }
}
