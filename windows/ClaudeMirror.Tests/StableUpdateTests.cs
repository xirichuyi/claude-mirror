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
}
