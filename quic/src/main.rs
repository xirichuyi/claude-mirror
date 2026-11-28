//! A QUIC pipe for Tether's file channel: the same agent wire protocol, carried over UDP instead of SSH.
//!   serve --ports 47000-47099 -- COMMAND [ARGS...]
//!       prints {"port":..,"fingerprint":..,"token":..} once, then pipes every authenticated stream into a fresh COMMAND.
//!       Exits when its stdin closes (the agent that started it is gone) or after 10 idle minutes.
//!   connect HOST PORT FINGERPRINT TOKEN
//!       pins the server certificate to FINGERPRINT and pipes stdin/stdout through one stream. Exit code 2: unreachable.
use std::{net::SocketAddr, process::Stdio, sync::Arc, time::Duration};

use quinn::{congestion::BbrConfig, crypto::rustls::{QuicClientConfig, QuicServerConfig}, Endpoint, IdleTimeout, TransportConfig, VarInt};
use rustls::{client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier},
             crypto::{ring, CryptoProvider}, pki_types::{CertificateDer, PrivatePkcs8KeyDer, ServerName, UnixTime},
             DigitallySignedStruct, SignatureScheme};
use sha2::{Digest, Sha256};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt};

const ALPN: &[u8] = b"tether-files/1";
const IDLE: Duration = Duration::from_secs(600);
const AUTH: Duration = Duration::from_secs(5);

fn transport() -> Arc<TransportConfig> {
    let mut config = TransportConfig::default();
    // A 290 ms link at 10 MB/s needs about 3 MB in flight; leave room above that.
    config.stream_receive_window(VarInt::from_u32(32 << 20))
        .receive_window(VarInt::from_u32(64 << 20))
        .send_window(64 << 20)
        .keep_alive_interval(Some(Duration::from_secs(5)))
        .max_idle_timeout(Some(IdleTimeout::try_from(Duration::from_secs(30)).unwrap()))
        .congestion_controller_factory(Arc::new(BbrConfig::default()));
    Arc::new(config)
}

fn provider() -> Arc<CryptoProvider> { Arc::new(ring::default_provider()) }

#[tokio::main]
async fn main() {
    if let Ok(filter) = std::env::var("TETHER_QUIC_LOG") {
        tracing_subscriber::fmt().with_env_filter(filter).with_writer(std::io::stderr).init();
    }
    let args: Vec<String> = std::env::args().skip(1).collect();
    let result = match args.first().map(String::as_str) {
        Some("serve") => serve(&args[1..]).await,
        Some("connect") if args.len() == 4 => connect(&args[1], &args[2], &args[3]).await,
        _ => Err("usage: tether-quic serve --ports A-B -- COMMAND... | connect HOST PORT FINGERPRINT (token on the first stdin line)".into()),
    };
    if let Err(error) = result {
        eprintln!("tether-quic: {error}");
        std::process::exit(2);
    }
    // Exit directly: a blocking stdin read would keep the Tokio runtime from shutting down.
    std::process::exit(0);
}

type Failure = Box<dyn std::error::Error + Send + Sync>;

async fn serve(args: &[String]) -> Result<(), Failure> {
    let split = args.iter().position(|a| a == "--").ok_or("missing -- COMMAND")?;
    let (options, command) = (&args[..split], args[split + 1..].to_vec());
    if command.is_empty() { return Err("missing COMMAND".into()); }
    let range = options.windows(2).find(|w| w[0] == "--ports").map(|w| w[1].clone()).unwrap_or_else(|| "47000-47099".into());
    let (first, last) = range.split_once('-').ok_or("bad --ports")?;
    let (first, last): (u16, u16) = (first.parse()?, last.parse()?);

    let generated = rcgen::generate_simple_self_signed(vec!["tether".into()])?;
    let certificate = generated.cert.der().clone();
    let fingerprint = hex::encode(Sha256::digest(&certificate));
    let mut tls = rustls::ServerConfig::builder_with_provider(provider())
        .with_protocol_versions(&[&rustls::version::TLS13])?
        .with_no_client_auth()
        .with_single_cert(vec![certificate], PrivatePkcs8KeyDer::from(generated.key_pair.serialize_der()).into())?;
    tls.alpn_protocols = vec![ALPN.to_vec()];
    let mut config = quinn::ServerConfig::with_crypto(Arc::new(QuicServerConfig::try_from(tls)?));
    config.transport_config(transport());

    let (endpoint, port) = (first..=last)
        .find_map(|port| {
            let socket = dual_stack(port).or_else(|_| std::net::UdpSocket::bind(SocketAddr::from(([0, 0, 0, 0], port)))).ok()?;
            Endpoint::new(quinn::EndpointConfig::default(), Some(config.clone()), socket, Arc::new(quinn::TokioRuntime)).ok().map(|e| (e, port))
        })
        .ok_or("no free UDP port in range")?;
    let token: String = hex::encode(rand::random::<[u8; 32]>());
    println!("{{\"port\":{port},\"fingerprint\":\"{fingerprint}\",\"token\":\"{token}\"}}");

    let token = Arc::new(token);
    let command = Arc::new(command);
    let mut parent = tokio::io::stdin();
    let mut sink = [0u8; 64];
    let mut tick = tokio::time::interval(Duration::from_secs(15));
    let mut active = tokio::time::Instant::now();
    loop {
        tokio::select! {
            read = parent.read(&mut sink) => if matches!(read, Ok(0) | Err(_)) { return Ok(()) },
            _ = tick.tick() => {
                if endpoint.open_connections() > 0 { active = tokio::time::Instant::now(); }
                else if active.elapsed() >= IDLE { return Ok(()) }
            }
            incoming = endpoint.accept() => {
                let Some(incoming) = incoming else { return Ok(()) };
                active = tokio::time::Instant::now();
                let (token, command) = (token.clone(), command.clone());
                tokio::spawn(async move { if let Err(error) = session(incoming, &token, &command).await { eprintln!("tether-quic: {error}"); } });
            }
        }
    }
}

/// One socket for IPv4 and IPv6 even where `net.ipv6.bindv6only=1`; hosts without IPv6 use IPv4 only.
fn dual_stack(port: u16) -> std::io::Result<std::net::UdpSocket> {
    let socket = socket2::Socket::new(socket2::Domain::IPV6, socket2::Type::DGRAM, Some(socket2::Protocol::UDP))?;
    socket.set_only_v6(false)?;
    socket.bind(&SocketAddr::from(([0u16; 8], port)).into())?;
    Ok(socket.into())
}

async fn session(incoming: quinn::Incoming, token: &str, command: &[String]) -> Result<(), Failure> {
    let connection = tokio::time::timeout(AUTH, incoming).await.map_err(|_| "handshake timeout")??;
    let mut first = true;
    loop {
        let stream = if first { tokio::time::timeout(AUTH, connection.accept_bi()).await.map_err(|_| "no stream")? } else { connection.accept_bi().await };
        first = false;
        let (mut send, mut recv) = stream?;
        let connection = connection.clone();
        let (token, command) = (token.to_owned(), command.to_vec());
        tokio::spawn(async move {
            let mut presented = vec![0u8; token.len() + 1];
            let ok = tokio::time::timeout(AUTH, recv.read_exact(&mut presented)).await.is_ok_and(|r| r.is_ok())
                && presented[..token.len()].iter().zip(token.as_bytes()).fold(0u8, |acc, (a, b)| acc | (a ^ b)) == 0
                && presented[token.len()] == b'\n';
            if !ok { connection.close(VarInt::from_u32(1), b"unauthorized"); return; }
            let Ok(mut child) = tokio::process::Command::new(&command[0]).args(&command[1..])
                .stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn() else { return };
            let (mut input, mut output) = (child.stdin.take().unwrap(), child.stdout.take().unwrap());
            let upstream = async { let _ = tokio::io::copy(&mut recv, &mut input).await; drop(input); };
            let downstream = async {
                if tokio::io::copy(&mut output, &mut send).await.is_ok() { let _ = send.finish(); }
                // Keep draining so a disconnected agent can still finish its cleanup instead of blocking on stdout.
                let _ = tokio::io::copy(&mut output, &mut tokio::io::sink()).await;
            };
            tokio::join!(upstream, downstream);
            let _ = child.wait().await;
        });
    }
}

#[derive(Debug)]
struct Pinned { fingerprint: String, provider: Arc<CryptoProvider> }

impl ServerCertVerifier for Pinned {
    fn verify_server_cert(&self, end_entity: &CertificateDer<'_>, _: &[CertificateDer<'_>], _: &ServerName<'_>, _: &[u8], _: UnixTime)
        -> Result<ServerCertVerified, rustls::Error> {
        if hex::encode(Sha256::digest(end_entity)) == self.fingerprint { Ok(ServerCertVerified::assertion()) }
        else { Err(rustls::Error::General("certificate fingerprint mismatch".into())) }
    }
    fn verify_tls12_signature(&self, _: &[u8], _: &CertificateDer<'_>, _: &DigitallySignedStruct) -> Result<HandshakeSignatureValid, rustls::Error> {
        Err(rustls::Error::General("TLS 1.2 is not used".into()))
    }
    fn verify_tls13_signature(&self, message: &[u8], cert: &CertificateDer<'_>, dss: &DigitallySignedStruct) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(message, cert, dss, &self.provider.signature_verification_algorithms)
    }
    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> { self.provider.signature_verification_algorithms.supported_schemes() }
}

async fn connect(host: &str, port: &str, fingerprint: &str) -> Result<(), Failure> {
    let mut input = tokio::io::BufReader::new(tokio::io::stdin());
    let mut token = String::new();
    input.read_line(&mut token).await?;
    let token = token.trim_end();
    let address = tokio::net::lookup_host((host, port.parse::<u16>()?)).await?.next().ok_or("host not found")?;
    let provider = provider();
    let mut tls = rustls::ClientConfig::builder_with_provider(provider.clone())
        .with_protocol_versions(&[&rustls::version::TLS13])?
        .dangerous().with_custom_certificate_verifier(Arc::new(Pinned { fingerprint: fingerprint.to_lowercase(), provider }))
        .with_no_client_auth();
    tls.alpn_protocols = vec![ALPN.to_vec()];
    let mut config = quinn::ClientConfig::new(Arc::new(QuicClientConfig::try_from(tls)?));
    config.transport_config(transport());
    let bind = if address.is_ipv6() { SocketAddr::from(([0u16; 8], 0)) } else { SocketAddr::from(([0, 0, 0, 0], 0)) };
    let mut endpoint = Endpoint::client(bind)?;
    endpoint.set_default_client_config(config);
    let connection = tokio::time::timeout(Duration::from_secs(3), endpoint.connect(address, "tether")?).await.map_err(|_| "UDP unreachable")??;
    let (mut send, mut recv) = connection.open_bi().await?;
    send.write_all(format!("{token}\n").as_bytes()).await?;
    let upstream = async move {
        let _ = tokio::io::copy(&mut input, &mut send).await;
        let _ = send.finish();
    };
    let downstream = async move {
        let mut stdout = tokio::io::stdout();
        let _ = tokio::io::copy(&mut recv, &mut stdout).await;
        let _ = stdout.flush().await;
    };
    tokio::select! { _ = downstream => {}, _ = async { upstream.await; std::future::pending::<()>().await } => {} }
    connection.close(VarInt::from_u32(0), b"");
    endpoint.wait_idle().await;
    Ok(())
}
