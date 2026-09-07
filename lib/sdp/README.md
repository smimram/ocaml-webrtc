# sdp

Parsing the offer a browser sends and generating the answer to it
(RFC 4566, RFC 8866, with the WebRTC attributes of RFC 8829).

Deliberately partial. There are few shapes of session a browser ever produces
here, so the parser looks for the attributes it needs and ignores the rest,
rather than modelling SDP. It does not round-trip: what comes back out is an
answer built from scratch, not the offer amended.

## The offer

Everything the rest of the server needs comes back in one record: a list of
media sections, and the transport parameters they share — the peer's ICE
credentials, the fingerprint of the certificate it will present, and whether it
asked for `a=rtcp-mux`. Those are read from the first section that carries
them, because under BUNDLE every section agrees on them.

Session-level attributes are folded into each media description, media level
winning, so a browser that puts `a=ice-ufrag` in either place is read the same
way. An offer proposing nothing we can receive is rejected with `Invalid`
rather than half-understood.

Each section also keeps **every** format it offered, not only the one chosen,
and the sources of its `a=ssrc` lines. Both are there for a forwarder: the
first is what it searches when it has to answer with a codec someone else
settled on, through `matching`, and the second is the only thing that tells
two tracks of one kind apart, since under BUNDLE they share a transport and,
with one codec per kind, a payload type as well.

## Choosing a codec

A section lists far more than the stream itself. Retransmission, redundancy and
forward error correction each take a payload type of their own, and a browser
offers every video codec it has. **One codec is chosen per section**, and that
is what lets the media loop filter on the payload type alone.

Audio is Opus. Video is VP8 by preference, then VP9, else H.264 — and for
H.264 only the payload type whose `a=fmtp` says `packetization-mode=1`, since
mode 0 cannot fragment a picture across datagrams and would silently drop every
frame larger than an MTU (RFC 6184 §6.2). A browser offers all three and always
puts VP8 first, so reaching either of the others means narrowing the offer with
`setCodecPreferences`.

**Encoding names are matched case-insensitively and echoed back exactly as the
offer spelled them** (RFC 4566 §6). A browser writes `opus` but `VP8`, and
answering `vp8` where it offered `VP8` is enough to make Chrome negotiate the
section, report it active, and then never start its encoder — no error
anywhere, just a video track that sends nothing. It cost an afternoon.

## The answer

```
a=ice-lite            we answer checks and never send any
a=group:BUNDLE 0 1    every accepted section on one transport
a=setup:passive       the browser is the DTLS client
a=recvonly            we receive; the offer said sendonly
a=rtcp-mux            RTCP shares the media port
a=candidate:…         one per address, most preferred first
```

A section is `a=recvonly` unless `sending` says what we send on it, in which
case it is `a=sendonly` and carries the source its packets will bear and the
`a=msid` stream and track they belong to — signalled so that a peer can bind
the packets to a track before they arrive, and so that two tracks it should
play in step can be given one stream. `media` replaces the sections the offer
was parsed into, which is how an answer names a codec other than the one this
library would have chosen for itself.

**The answer has one section per section of the offer, in the same order.**
That correspondence is how the two sides agree on what each section is about
(RFC 3264 §6), so a section we cannot use is not left out but echoed back with
a port of zero and `a=inactive`. Only the sections we accepted are named in the
`BUNDLE` group.

The candidate list is the part worth explaining. A peer pairs its own
candidates with ours by route, and a browser gathers no loopback candidate of
its own while a real interface exists — so a lone `127.0.0.1` candidate leaves
a browser on the very same machine with nothing it can check against. Hence a
list, ordered, with the loopback last: `host_priority` gives each a local
preference counting down from the address we would rather be reached on
(RFC 8445 §5.1.2.1).

The `a=fmtp` line is echoed back unchanged. Those are the parameters the
browser chose for its own encoder, and we are in no position to argue with
them. Of the `a=rtcp-fb` lines only `nack pli` is answered, and only where the
offer proposed it: an answer may use no feedback the offer did not list, and
asking for what we will never act on would only be a lie.

## Testing

`test.ml` parses an offer of the shape Chrome writes — three sections on one
bundled transport, the two video ones identical but for their sources — and
reads the answers made to it back through the same parser, which is the
cheapest way to check that what is written says what it means.

Beyond that the browser is the test, and a harsh one. It rejects an answer
that is wrong in the smallest way — a missing `a=mid`, a `BUNDLE` group naming
a section that is not there — and it does so silently, leaving ICE to time out
with no clue as to why. That is the reason the answer is built in one place,
in one function, and kept boring.

To see one: post an offer and read what comes back.

```sh
curl -s -X POST -H 'Content-Type: application/sdp' \
  --data-binary @offer.sdp http://localhost:8080/webrtc/offer
```
