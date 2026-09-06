# rtp

RTP packets (RFC 3550), a jitter buffer, the RTCP an endpoint sends and reads,
the payload formats that carry video, and the timeline a container measures
against. No dependencies; nothing here knows about sockets.

## packet.ml

Only the fields an endpoint needs: what identifies a stream, what orders it,
and where the header ends.

That last one is load-bearing. `header_length` is exposed separately from
`parse` because **SRTP must know it before it can decrypt what follows** — the
header, its CSRC list and any extension travel in the clear, and the encrypted
part starts immediately after. Getting the extension length wrong shifts the
keystream and produces noise rather than an error.

`is_rtcp` tells the two apart when they share a port, which they do whenever
`a=rtcp-mux` is negotiated: RTCP's packet types all fall in 64..95 once the
marker bit is masked off (RFC 5761 §4).

`encode` writes a description back out, for a forwarder that parses a packet,
puts its own source and numbering on it and sends it on. The `header_length`
that came out of `parse` is ignored there: it describes the packet the value
came from, and a value that has been altered since describes one of its own.

## rtcp.ml

What an endpoint has to say back, built rather than parsed. The picture loss
indication of RFC 4585 §6.3.1, twelve bytes naming our own source and the one
whose pictures have become unreadable, because a browser sends a fresh keyframe
only when asked and until one arrives every picture is predicted from a broken
one. And the receiver report of RFC 3550 §6.4.2 with the CNAME chunk that must
accompany it, because a sender that hears nothing about what arrived has
nothing to size its bitrate against.

A sender has one thing to say instead: `sender_report`, which pairs its
stream's clock with the wall clock. That pairing is the whole content of it,
and it is the only thing a peer receiving two of our streams can align them
by — without it a forwarded camera and the microphone that goes with it play
on clocks that never meet.

Of what a browser sends us, `sender_reports` reads the same pairing back, plus
the timestamp a receiver report has to echo (`compact_ntp` is its middle 32
bits, which is the form that travels), and `keyframe_requests` reads the
picture loss indications, which a forwarder passes upstream to the peer that
can actually answer them. The walk over a compound packet steps over anything
it does not recognise rather than stopping, since a browser's compound packets
carry a good deal we have no use for.

There is still no negative acknowledgement. A recorder cannot use a packet
twice — by the time it noticed the loss, the picture was already written off —
and a forwarder keeps no copy to send again.

## reception.ml

The counting behind a report block: how many packets arrived, how many were
expected, and the interarrival jitter of RFC 3550 §6.4.1.

Two things are easy to get wrong here. The counting is of what came off the
**wire, before the jitter buffer** — a packet the buffer later gave up on did
arrive, and a report describes the network rather than what we managed to
write. And the sequence number's wrapping is tracked here rather than borrowed
from SRTP's rollover counter, because a packet SRTP refused never reached us
and must not count as received.

`report` is not a pure reading: the loss fraction is over the interval since
the last one, so asking for a report starts a new interval.

## reorder.ml

A network reorders and loses packets; a file may not. The buffer holds packets
back until they are in sequence, and hands them out in order.

The rule that shapes it: **a recorder must never stall waiting for a packet
that is not coming.** So the wait is bounded two ways, and a gap that reaches
either bound is written off, counted, and skipped to the oldest packet the
buffer does hold. The depth — eight packets by default — bounds a busy stream,
where the packets pile up in no time. The deadline — two hundred milliseconds —
bounds a sparse one, where a few packets a second would sit on a gap for
seconds before reaching any depth worth having. A packet that turns up after
its place has passed is dropped, as is a duplicate.

Both bounds are tested when a packet arrives, so a track that goes quiet in the
middle of a gap would hold what it has indefinitely. `expire` is the way to say
that time has passed without anything arriving; the server calls it for both
tracks on every datagram, so each track's silence is covered by the other's
packets.

Sequence numbers are sixteen bits and wrap, so every comparison is modular:
ordering is only meaningful within half the space (RFC 3550 §A.1).

Losing a packet leaves a hole in the recording, and the hole is the right
length, because the granule position downstream comes from RTP timestamps
rather than from counting packets.

## timeline.ml

An RTP timestamp starts at a random offset and is thirty-two bits wide, so it
wraps — every thirteen hours at 90 kHz, every day at 48 kHz. A container wants
neither: it wants a count from the start of the stream that keeps growing.

The rule for telling the two apart: a *small* step backwards is a packet out of
order, a *large* one is the clock wrapping. Both `oggopus` and `matroska`
measure against this, which is why it lives here rather than in either.

## vp8.ml, vp9.ml and h264.ml

The three payload formats (RFC 7741, draft-ietf-payload-vp9-16 and RFC 6184).
All exist to undo what the transport did to a picture and hand back exactly the
bytes the encoder produced.

VP8 puts a descriptor of one to six bytes in front of every payload; it is a
transport artefact and does not belong in a file, so it is stripped and the
partitions concatenated. A keyframe then declares its own size in the
uncompressed header behind the `9d 01 2a` start code (RFC 6386 §9.1).

VP9 is the same idea with a descriptor that varies far more: the picture
identifier, the layer indices, the reference differences of flexible mode and a
whole scalability structure are each optional, and the structure's own length
depends on how many spatial layers and picture-group entries it describes.
Nothing in it is read beyond `B`, which says where a frame begins, and its
total length. The size comes from the frame instead, out of the uncompressed
header behind the `49 83 42` sync code — reached by reading past a colour
section whose length depends on the profile and on the colour space (VP9
bitstream specification §6.2). A keyframe is exactly the frame whose header
parses that far, so the same code answers both questions.

H.264 is more work. A unit small enough for a datagram is the packet; several
small ones arrive aggregated behind their lengths; one too large arrives in
fragments whose first and last are flagged, and whose own header has to be
**rebuilt from the two bytes the format puts in its place** — the reference
bits from one, the type from the other (§5.8). The units are then stored each
behind a four-byte length, as a container expects them.

The picture size is the awkward part: Matroska demands it in the header and
H.264 buries it in the sequence parameter set, behind exponential-Golomb codes
and an optional scaling matrix that has to be read only to be skipped. The
emulation-prevention bytes come out first, cropping comes off at the end, and
the amount cropped depends on the chroma subsampling.

## frame.ml

A frame is the run of packets sharing a timestamp, ended by the marker bit.

The rule that shapes it, and the one place it differs from the audio path:
**an incomplete picture is dropped, not written short.** A missing audio packet
leaves a gap of the right length and the recording carries on. A missing video
packet does not shorten the picture, it corrupts it — and every picture
predicted from it after that. So a gap in the sequence numbering, or joining a
picture partway through, discards the whole frame and counts it.

`starts_keyframe` is the same rule from the other side: where a receiver
joining now may begin. For VP8 and VP9 it is the first packet of a keyframe;
for H.264 it is the parameter sets a browser sends immediately before an IDR,
not the IDR itself, which without them a decoder cannot configure itself for.

## Testing

`test_vp8.ml`, `test_vp9.ml` and `test_h264.ml` cover the
descriptors — including the ones a browser actually sends, and the scalability
structure — the fragmenting, the picture size read back out of a keyframe
and out of two real parameter sets — one baseline and one high profile, both cropped, both
carrying emulation-prevention bytes — and, for each format, which packet a
receiver may join at.

`test.ml`: a packet with two CSRCs and a header extension, so the
payload offset depends on both, written back out and read again with the
fields a forwarder rewrites rewritten; then the buffer, through reordering, a
duplicate, a late arrival, a gap that fills, a gap that never does, and a gap
outlasting the deadline on a stream too sparse to reach the depth; then the
bytes of a picture loss indication, a receiver report and a sender report,
each held against a packet spelled out by hand.
