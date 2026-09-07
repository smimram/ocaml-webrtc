# ocaml-webrtc

The pieces a WebRTC endpoint is made of, in OCaml: SDP, ICE and STUN, DTLS
with the SRTP key exchange, SRTP itself, RTP with the VP8, VP9 and H.264
payload formats, and Ogg/Opus and Matroska muxers to store what arrives. They
are written here because none of it exists in opam — `tls` has no DTLS, and
there is no STUN, ICE, SRTP or SDP package.

Everything installs as one opam package, `webrtc`, whose libraries are used
separately:

```
(libraries webrtc.sdp webrtc.ice webrtc.dtls webrtc.srtp webrtc.rtp)
```

## The libraries

| | |
|---|---|
| `webrtc.sdp` | parsing an offer, generating the answer |
| `webrtc.ice` | STUN codec (RFC 5389) and an ICE-lite agent (RFC 8445) |
| `webrtc.dtls` | a DTLS 1.2 server (RFC 6347) exporting SRTP keys (RFC 5764) |
| `webrtc.srtp` | protecting and unprotecting SRTP and SRTCP (RFC 3711) |
| `webrtc.rtp` | RTP packets, a jitter buffer, RTCP, VP8, VP9 and H.264 payload formats |
| `webrtc.oggopus` | writing Ogg pages and an Opus stream (RFC 7845) |
| `webrtc.matroska` | writing EBML and a Matroska file (RFC 9559) |

They are layered but independent: `sdp` and `ice` stand alone, `dtls` produces
the keying material `srtp` consumes, `srtp` and the containers build on `rtp`.
None of them knows about sockets, or about any particular event loop; the code
that owns the socket decides what to do with the bytes.

Each library has a README of its own, covering what it implements, what it
deliberately does not, and how it is checked. The interfaces are documented in
the `.mli` files, from which the [online
documentation](https://smimram.github.io/ocaml-webrtc/) is built.

## The examples

[`examples/recrtc`](examples/recrtc) is a web server that records what a
browser sends it over WebRTC — the microphone, and the camera if you want it —
as an Ogg/Opus or Matroska file, bit-exact, nothing decoded or re-encoded. It
uses all of the libraries above and is the reason they exist.

```
make serve                       # then open http://localhost:8080
```

[`examples/conference`](examples/conference) is the other direction: a
conferencing server, where one speaker sends microphone, camera and desktop
and everyone else watches. It is a selective forwarding unit — each packet is
decrypted, renumbered and encrypted again for every attendee, and no codec is
run — so it is what exercises the sending half of `webrtc.srtp` and the
sender's half of `webrtc.rtp`.

```
make conference                  # then open http://localhost:8080
```

## Testing

`make test` runs the published vectors the delicate parts stand on: RFC 5769
for STUN, RFC 3711 appendix B for the SRTP key derivation and keystream, plus
the RTP, jitter-buffer, Opus framing, VP8, VP9, H.264 and EBML logic. Tests sit
beside the code they cover, one `test.ml` per library.

The DTLS server can be exercised on its own against another implementation:

```
dune exec test/dtls_harness.exe &
openssl s_client -dtls1_2 -use_srtp SRTP_AES128_CM_SHA1_80 \
  -keymatexport EXTRACTOR-dtls_srtp -keymatexportlen 60 -connect 127.0.0.1:7001
```

The handshake completes and the sixty exported bytes agree with the ones the
harness prints.

## Scope

The libraries were written to serve one endpoint, and they carry its
assumptions: ICE-lite (checks are answered, never sent), the DTLS *server* side
only, one cipher suite, one SRTP profile (`AES_CM_128_HMAC_SHA1_80`), no
application data over DTLS. Nothing here encodes or decodes media: what a
browser sent is what is stored, and what is forwarded. Each README says where
its own line is drawn.
