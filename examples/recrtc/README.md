# recrtc

A web server that records what a browser sends it over WebRTC — the
microphone, and the camera if you want it — as an Ogg/Opus or Matroska file.
It is the example the libraries of this repository were written for: it uses
all of them, and nothing else of WebRTC is left out of it.

```
make serve                       # then open http://localhost:8080
make serve IP=203.0.113.7        # only if we cannot see the address ourselves
```

Press *Record*, allow the microphone and the camera, press *Stop*: the server
writes `recording-<date>.webm`, which any player reads. Untick *camera* and it
writes `recording-<date>.opus` instead.

`make serve` starts the server from the root of the repository, which is where
the default `--static examples/recrtc/static` is relative to; run it from
somewhere else and that path has to be given.

## What it does

The browser sends an offer over HTTP; the server answers as an **ICE-lite**,
**DTLS-passive**, receive-only endpoint. Both tracks are bundled onto one
transport, so all media arrives on one UDP port, where STUN, DTLS and SRTP are
demultiplexed by their first byte (RFC 7983) and the two streams are told apart
by payload type.

- The browser's connectivity checks are answered from the socket they arrived
  on, which is what opens the mapping when the browser is behind a NAT. The
  candidates advertised to a browser start with the address its own offer
  reached us on, so that a browser here and a browser on any of this machine's
  networks each find one they can pair with, and end with the loopback. `--ip`
  overrides the list, which is what a server behind a port forwarding needs.
- DTLS exists only to agree on SRTP keys — there is no application data, so
  the handshake is cut to one cipher suite, `ECDHE-ECDSA-AES128-GCM-SHA256`,
  against a self-signed P-256 certificate made at start-up.
- The Opus packets and the video frames are written to the file exactly as they
  arrive, nothing is decoded or re-encoded. For audio the RTP timestamp is the
  granule position Ogg wants, so a lost packet leaves a gap of the right length
  rather than shifting the sound.
- Video is VP8, VP9 or H.264, reassembled from the packets it was cut into. A
  picture missing a packet is dropped whole rather than written short: unlike
  an audio gap, a partial picture corrupts every frame predicted from it.
  Recording starts at the first keyframe, so the file opens on a picture that
  decodes on its own.
- Audio alone goes to Ogg. With video it goes to Matroska — `.webm` for VP8
  and VP9, `.mkv` for H.264, whose codec WebM's `DocType` does not admit.

## Layout

| | |
|---|---|
| `src/recrtc.ml` | the HTTP server, the media socket and the sessions |
| `static` | the page and its script |

## Options

| | |
|---|---|
| `--port`, `--interface` | where the HTTP server listens (default `localhost:8080`) |
| `--media-port` | the UDP port media arrives on (default 7000) |
| `--ip` | an address to advertise as an ICE candidate, repeatable |
| `--bind` | the local address of the media socket, when it differs (behind a NAT) |
| `--output` | the prefix recordings are named with (default `recording`) |
| `--static` | the directory the page is served from |
| `--debug` | log every dropped datagram, and the offer and answer in full |

`getUserMedia` needs a secure context: `http://localhost:8080` qualifies,
reaching the same server over a LAN address does not, and the *Record* button
fails there. Recording from another machine needs HTTPS in front.

## Testing it

End to end, a headless browser will do:

```
chromium --headless=new --use-fake-ui-for-media-stream \
  --use-fake-device-for-media-stream "http://localhost:8080/?autostart"
```

Its fake device draws a rolling disc with the time burnt into the picture and
sounds a steady tone, so seeking to five seconds and reading the frame checks
the timeline as well as the pixels. Add `&audio` for audio alone, or
`&codec=h264` to narrow the offer and exercise the other video path.

## Not there yet

- The client certificate is not requested, so the fingerprint in the offer is
  not checked against the one the browser presents.
- The RTCP sent back is a keyframe request when a picture is lost, and a
  receiver report once a second. There is no negative acknowledgement, so a
  lost packet is never retransmitted, and no transport-wide congestion
  feedback.
- The two tracks are lined up by when their first packets arrived, not by the
  NTP-to-RTP mapping in the browser's sender reports, of which we read only the
  timestamp a receiver report has to echo. Good to a few tens of milliseconds,
  not to the sample.
- One audio and one video stream per session, and one SRTP profile
  (`AES_CM_128_HMAC_SHA1_80`).
