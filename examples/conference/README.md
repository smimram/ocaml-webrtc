# conference

A conferencing server: one speaker sends microphone, camera and desktop, and
everyone else watches. It is a **selective forwarding unit** — the speaker's
packets are decrypted, renumbered and encrypted again for each attendee, and
no codec is ever run, so what an attendee sees is the bitstream the speaker's
encoder produced.

```
make conference                  # then open http://localhost:8080
make conference IP=203.0.113.7   # only if we cannot see the address ourselves
```

A conference is a name, and the name is the address. `/bla` watches the
conference called `bla`; `/bla/speaker` talks in it. A conference comes into
being when someone first asks for it and vanishes when the last person leaves,
so there is nothing to create and nothing to clean up.

The speaker presses *Connect* to send the microphone and camera, and *Share
desktop* to add the screen. Attendees press *Join*: they see the desktop
large, the camera beside it, and hear the microphone. Whoever is speaking
first keeps the conference — a second offer for `/bla/speaker` is refused for
as long as the first is alive.

## Why forwarding

The alternatives are worse for this. A **mesh** — each attendee connected
straight to the speaker — puts one full copy of the desktop on the speaker's
uplink per attendee, which is over at about five of them, and uses none of
this repository. An **MCU**, which decodes everything and re-encodes one
composite picture, needs libvpx and libopus and would re-encode what the
browser already encoded, which is exactly what the rest of this repository is
written to avoid. Forwarding costs one AES-CTR pass and one HMAC per packet
per attendee, and nothing else.

What it does not do is choose. A real SFU reads the congestion feedback and
drops a simulcast layer or a temporal layer for the attendee whose link cannot
keep up; this one forwards everything to everyone.

## What it does

Every session — the speaker's and each attendee's — is an **ICE-lite**,
**DTLS-passive** endpoint on one shared UDP port, where STUN, DTLS and SRTP
are demultiplexed by their first byte (RFC 7983), exactly as in
[`recrtc`](../recrtc). What is new here is everything about *sending*.

- **Three tracks on one transport.** The speaker's page opens a transceiver
  for the microphone, the camera and the desktop at once, the last without a
  track on it, so sharing the desktop later replaces a track on a sender that
  already exists and no renegotiation is needed. All three are bundled, and
  the two video ones use the same codec and so the same payload type: their
  packets are told apart by synchronisation source, taken from the `a=ssrc`
  lines of the offer.

- **One codec for everyone.** Nothing here can transcode, so the speaker
  settles what the conference speaks — VP8, VP9 or H.264, and Opus — and each
  attendee is answered with the format of its own offer that matches it. An
  attendee that offers no equivalent is answered with that section rejected.

- **Rewriting.** A forwarded packet keeps its payload untouched and its marker
  bit and timestamp spacing intact; what changes is the payload type, to the
  attendee's own numbering, the source, to one signalled to that attendee
  alone, and the sequence number and timestamp, which are offset so that the
  stream an attendee sees is continuous from the moment it joined. Contributing
  sources and header extensions are dropped: neither is ours to pass on.

- **Joining.** An attendee that started mid-picture would decode rubbish, so a
  video track stays shut until a packet arrives that a receiver can join at —
  a keyframe, or for H.264 the parameter sets that precede one. A browser
  sends a fresh keyframe only when asked, so joining, an attendee's own
  request, and a gap in the speaker's numbering each ask for one, at most one
  every half second. Audio needs none and starts at once.

- **Lip sync.** A receiver has nothing to align two streams by except the
  sender reports that tie each stream's clock to the wall clock, so we send
  them: the speaker's own pairing of the two clocks, advanced by however long
  ago it reached us and moved by the offset that attendee's stream was rebased
  on. The microphone and the camera are given the same `a=msid` stream, which
  is what asks a browser to play them in step.

## Layout

| | |
|---|---|
| `src/conference.ml` | the HTTP server, the media socket, the sessions and the forwarding |
| `static` | the three pages and their scripts |

## Options

| | |
|---|---|
| `--port`, `--interface` | where the HTTP server listens (default `localhost:8080`) |
| `--media-port` | the UDP port media arrives on (default 7000) |
| `--ip` | an address to advertise as an ICE candidate, repeatable |
| `--bind` | the local address of the media socket, when it differs (behind a NAT) |
| `--static` | the directory the pages are served from |
| `--debug` | log every dropped datagram, and every offer and answer in full |

`getUserMedia` and `getDisplayMedia` need a secure context:
`http://localhost:8080` qualifies, reaching the same server over a LAN address
does not. Speaking from another machine needs HTTPS in front; watching does
not, since an attendee opens no device of its own.

## Testing it

Two headless browsers, one speaking and one watching:

```
chromium --headless=new --use-fake-ui-for-media-stream \
  --use-fake-device-for-media-stream "http://localhost:8080/bla/speaker?autostart"
chromium --headless=new "http://localhost:8080/bla?autostart"
```

`getStats()` on the attendee is what says whether it worked: `inbound-rtp`
should show `framesDecoded` climbing on the camera and `packetsLost` at zero.
Add `&autoshare` to the speaker's address, and
`--auto-accept-this-tab-capture` to its browser, to exercise the desktop track
as well — headless has no desktop to pick from, but it can be told to hand
over the tab it is already showing. `&codec=vp9` or `&codec=h264` narrows the
speaker's offer, since a browser otherwise always settles on VP8.

## Not there yet

- No congestion control of any kind: the receiver reports we send the speaker
  let it size its own bitrate, but nothing is read of what attendees report,
  so one attendee on a poor link is sent the same stream as everyone else.
  Simulcast and temporal-layer selection, which is what a real SFU does about
  that, are not implemented — nor is retransmission, so we answer `nack pli`
  and never plain `nack`.
- Attendees watch and never speak: there is no path for a question from the
  floor, which would mean forwarding an attendee's track to the speaker and to
  everyone else, and renegotiating each of their sessions when it appeared.
- One speaker per conference, and the first one wins; a conference held by a
  browser that crashed is free again a few seconds later, when its consent
  checks have stopped coming.
- Conferences live in memory and vanish with the process, and nothing is
  recorded — `recrtc` is the example that writes what it receives to a file.
- As in `recrtc`, the browser's certificate fingerprint from the offer is not
  checked against the one the handshake presents.
