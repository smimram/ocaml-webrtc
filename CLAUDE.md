# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

This repository is a set of OCaml libraries for WebRTC — SDP, ICE and STUN,
DTLS with the SRTP key exchange, SRTP, RTP with its payload formats, and the
Ogg/Opus and Matroska muxers that store what arrives — written because none of
it exists in opam: `tls` has no DTLS, and there is no STUN, ICE, SRTP or SDP
package. They install as one opam package, `webrtc`, whose libraries are
`webrtc.sdp`, `webrtc.ice` and so on; inside the repository they are still
referred to by their bare names (`sdp`, `ice`, …).

There are two examples, each a package of its own. `examples/recrtc`, the one
they were written for, is a web server that records what a browser sends over
WebRTC — Opus audio, and VP8, VP9 or H.264 video — as an Ogg/Opus or Matroska
file. `examples/conference` is a conferencing server: one speaker sends
microphone, camera and desktop, everyone else watches, and the server forwards
the packets without decoding them (a selective forwarding unit). It is what
exercises the *sending* half of the stack — `Srtp.protect`, `Rtp.Packet.encode`
and the sender reports — which a recorder never touches.

`README.md` describes the libraries and each example's own `README.md` the
server; this file is about working on them.

`experiments/recws/` is a separate, self-contained predecessor that uploaded
`MediaRecorder` chunks over HTTP. It is kept for reference and is not part of
the build path described here.

## Commands

```sh
make                     # dune build
make test                # dune test  (add --force: dune caches a passing run)
make serve               # dune exec examples/recrtc/src/recrtc.exe
make conference          # dune exec examples/conference/src/conference.exe
make serve IP=<address>  # override the advertised candidates
make serve ARGS=--debug  # extra flags
```

Both take the same options. `--debug` logs every dropped datagram, and the
offer and answer in full, which is usually the fastest way to see why a browser
is not sending something. The pages are served from the example's own `static`
directory, as a path relative to where the server is started from — the root of
the repository, which is what the `make` targets do; `--static` is for anywhere
else. `--ip` is only needed when the
address to advertise is not one the machine can see for itself; see "The
advertised address" below.

Tests live beside the code they cover: each library that has any carries a
`test.ml` next to its modules, run by a `(test)` stanza in the same `dune` file
as the library. `dune test` runs them all; one alone is `dune exec
lib/rtp/test.exe`. They share the harness in `test/testlib.ml`, which is a
library of its own (`test/dune` also holds `dtls_harness.ml`).

Because a library and its test sit in one directory, both stanzas need explicit
`(modules ...)`: the library takes `:standard \ test ...` and the test the
list of its own modules. A new test module must be added to both. `lib/rtp` is
the one with several, `test.ml` being the entry point that calls the payload
format ones.

### Testing against other implementations

The unit tests are mostly published vectors (RFC 5769 for STUN, RFC 3711
appendix B for SRTP), because a homegrown crypto test only proves the code
agrees with itself. Two further checks are worth running after touching
`lib/dtls` or the media path:

```sh
dune exec test/dtls_harness.exe &     # a bare DTLS server on UDP 7001
openssl s_client -dtls1_2 -use_srtp SRTP_AES128_CM_SHA1_80 \
  -keymatexport EXTRACTOR-dtls_srtp -keymatexportlen 60 -connect 127.0.0.1:7001
```

The handshake must complete and OpenSSL's exported sixty bytes must equal the
four values the harness prints, concatenated.

```sh
chromium --headless=new --no-sandbox --use-fake-ui-for-media-stream \
  --use-fake-device-for-media-stream "http://localhost:8080/?autostart"
```

The `?autostart` hook in `examples/recrtc/static/recrtc.js` exists for exactly
this; `&audio` records audio alone, and `&codec=vp9` or `&codec=h264` narrows the offer
through `setCodecPreferences` so the other video paths can be reached, since a
browser otherwise always picks VP8 from what we accept.

Chromium's fake device sounds a steady tone (400 Hz in current builds, not the
440 Hz older notes claim — measure, do not assume) and draws a rolling disc
**with the timecode burnt into the picture**. That last one is the useful part:
seek to five seconds, extract the frame, and if it reads `0:00:05` the two
timelines are right, which no amount of probing the container will tell you.

```sh
ffprobe -hide_banner recording-*.webm          # VP8 640x480 + Opus 48000 mono
ffmpeg -i recording-*.webm -f null -           # decodes clean, exit 0
ffmpeg -ss 5 -i recording-*.webm -frames:v 1 frame.png
```

The conference needs two browsers, one on `/<name>/speaker?autostart` and one
on `/<name>?autostart`, and is checked from the attendee's `getStats()`:
`inbound-rtp` with `framesDecoded` climbing and `packetsLost` at zero is the
whole claim. `&autoshare` on the speaker, with
`--auto-accept-this-tab-capture` on its browser, exercises the desktop track —
headless has no desktop to pick from but can hand over its own tab.
Chromedriver is the least painful way to drive two of them and read the
statistics out; a plain `--headless` invocation cannot.

A conference is held by its speaker for five seconds after that speaker stops
sending consent checks, so two test runs in quick succession over the same
conference name will see the second speaker refused. Use a fresh name, or
wait.

## Architecture

Signalling is one HTTP exchange; all media arrives on a **single UDP socket
shared by every session**, where STUN, DTLS and SRTP are demultiplexed by the
first byte of the datagram (RFC 7983). Each example's own `.ml` holds that loop
and the session table; the libraries under `lib/` are transport pieces that know
nothing about sockets or Dream. The two servers share that shape almost line
for line, deliberately: what differs is what they do with a packet once it is
decrypted.

A session is found two ways, and both must stay in step: by the local ICE
fragment inside a STUN check's USERNAME, and by source address
(`sessions_by_peer`) for DTLS and media, which identify themselves no other
way. `track_peer` updates the second when the agent latches or re-latches.

In `recrtc`, both tracks share that one transport under BUNDLE and are told
apart **by payload type**, which `lib/sdp` fixes at one per kind when it
answers. That does not scale to the conference, whose speaker sends two video
tracks with the same codec and so the same payload type: there they are told
apart **by synchronisation source**, taken from the `a=ssrc` lines of the
offer, with the payload type narrowing an unknown source to a kind.

Layering: `sdp` and `ice` are independent; `dtls` produces the SRTP keying
material that `srtp` consumes; `srtp` depends on `rtp` for the header length,
which is also where encryption starts, and on the sending side protects both
the packets a forwarder passes on and the reports and requests `rtp` builds;
`rtp` also holds the VP8, VP9 and H.264
payload formats and the timeline both containers measure against; `oggopus`
takes the Opus packets out the far end, and `matroska` takes both, borrowing
the Opus header from `oggopus`. `lib/ice/stun.ml` deliberately has no `Unix`
dependency so the RFC vectors can drive it. `rtp` does depend on `unix`, for
the jitter buffer's deadline and the reception statistics' timings; every
function of it that reads the clock takes an optional `?now`, so the tests stay
deterministic.

`Dtls.Server` is a pure state machine — `handle : t -> datagram -> datagram
list * event` — which is what lets `test/dtls_harness.exe` and
`examples/recrtc/src/recrtc.ml` drive the same code. Keep it that way.

Deliberate scope limits, all load-bearing: ICE-lite (we never send checks),
`a=setup:passive` (so only the DTLS *server* side exists), one cipher suite,
one SRTP profile, no application data over DTLS. The RTCP we send a peer we
receive from is a picture loss indication and a receiver report with its CNAME
once a second; the RTCP we send a peer we send to is a sender report with its
CNAME. Of what a browser sends us, only the sender report's clock pairing and
its picture loss indications are read.

`examples/conference` adds its own: one speaker per conference, first one
wins; attendees watch and never speak; one codec per conference, since nothing
here transcodes; no congestion control, no simulcast, no retransmission.

## Things that will bite you

**The advertised address.** Two constraints pull against each other here.
A peer discards a check response arriving from an address other than the one it
wrote to (RFC 8445 §7.2.5.2.1), which argues for binding the media socket to
the single address we advertise. But a browser only pairs its own candidates
with ones it can route to, and it gathers no loopback candidate when a real
interface exists — so advertising `127.0.0.1` alone strands a browser on this
very machine, in a way that looks like silence: ICE latches on our side while
the browser sits in `checking` and then `failed`.

So the default is per peer: the answer to an offer carries the address that
peer's own signalling arrived on — a route lookup against the client address
Dream reports, which is the one thing that knows which of several interfaces a
peer is on — then the address of the default route, then loopback. A machine
with a wired and a wireless interface has no single right answer, and offering
only the default route's address strands anyone on the other one exactly as
above. The media socket binds the wildcard, and the routing table then picks a
source that agrees with the destination for every pair a peer can actually
reach us on. Passing a single `--ip` overrides the list and goes back to
binding that address exactly. `--bind` sets the local address independently,
for a server behind a 1:1 NAT.

Loopback stays last even for a peer that signalled over it: that peer is on
this machine and can reach every address we have, so putting loopback first
only adds a pair for the two sides to change their minds between.

**Evaluation order in flight construction.** `handshake_records` takes the next
handshake sequence number and appends to the transcript as a side effect.
OCaml evaluates the operands of `@` right to left, so building a flight as
`records a @ records b` numbers them backwards — which cost an afternoon once,
appearing as an `unexpected_message` alert from OpenSSL. Bind each message with
`let` in order. The same applies anywhere else a sequence counter is bumped
inside an expression.

**A stale server holds the port.** `dune exec` fails with `EADDRINUSE` and
exits, leaving the *old* binary answering requests, so your changes seem to
have no effect. Kill it first — but `pkill -f` matches the shell running the
command as readily as the server, and killing your own shell mid-script is a
confusing way to find that out. The bracket trick (`pkill -f '[r]ecrtc\.exe'`)
only helps when that pattern is the line's *only* mention of the binary; if the
same command also runs `./_build/.../recrtc.exe`, the shell matches anyway.
Kill by PID, or give the `pkill` a line of its own.

**Codec names are echoed, not normalised.** Encoding names in `a=rtpmap` are
case-insensitive (RFC 4566 §6) and browsers are inconsistent: Chrome writes
`opus` but `VP8`. `lib/sdp` used to lowercase the name it parsed, which was
invisible for audio and fatal for video — answering `vp8` where Chrome offered
`VP8` makes it negotiate the section, report the sender *active*, and then
never start its encoder. No error, no warning, `framesEncoded` stuck at zero
and `targetBitrate` undefined. Match case-insensitively; echo the offer's own
spelling.

When video is silently absent like that, the fastest diagnosis is
`connection.getStats()` from the page against `--enable-logging=stderr`:
`media-source` tells you whether the camera is producing frames at all, and
`outbound-rtp` whether the encoder ever ran. It separates "the browser is not
sending" from "we are not receiving" in one step.

**An incomplete picture is dropped, not written short.** This is where the
video path stops resembling the audio one. A lost audio packet leaves a gap of
the right length and everything after it is still fine. A lost video packet
does not shorten a picture, it corrupts it, and every frame predicted from it
afterwards. `Rtp.Frame` therefore discards a frame with a sequence gap in it,
and the recording does not start until the first keyframe.

That is also why loss is answered with a keyframe request: a browser sends a
fresh keyframe only when asked, so without one the corruption runs to the end
of the recording. `request_keyframe` in `examples/recrtc/src/recrtc.ml` sends
the PLI, at most one every `pli_interval`, and video stops being written until the keyframe
arrives — or until `keyframe_timeout` passes, since a peer that ignores the
request must not leave us recording nothing at all. Chromium's `outbound-rtp`
statistics are where to look if this seems not to work: `pliCount` says whether
our packets are arriving and being understood, and `keyFramesEncoded` whether
they are being acted on.

**A forwarder must not spend a keyframe on a peer that cannot be sent to
yet.** Video to an attendee is held shut until a packet arrives that a receiver
can join at, and opened on the first one — so if `forward` runs before that
attendee's DTLS handshake has finished, the packet is dropped for want of a
sender and the gate is left open on a picture nobody got. The guard is at the
top of the per-attendee loop, not inside `forward_packet`, for exactly that
reason. It shows up as an attendee that stays black until the next keyframe
comes round on its own, which with no further loss is never.

**Lip sync is signalled, not computed.** A browser plays two of our streams in
step only if it can tie both to one clock, which takes two things: the
microphone and the camera answered with the same `a=msid` stream, and a sender
report on each carrying the *speaker's* own pairing of RTP timestamp with NTP
time — advanced by how long ago it reached us, and moved by the offset that
attendee's stream was rebased on. Dating the report from our own clock instead
would put the two streams on clocks that agree with nothing. `getStats()` on
the attendee tells you it worked: `estimatedPlayoutTimestamp` appears on an
`inbound-rtp` only once a `remote-outbound-rtp` has arrived for it.

**A jitter buffer only thinks when pushed to.** `Rtp.Reorder` bounds a gap two
ways, by depth and by a deadline, because a stream of a few packets a second
never reaches the depth and a stream of hundreds reaches it having buffered far
more than it needs. But both are tested inside `push`, so a track that falls
silent mid-gap holds what it has for as long as the silence lasts. `expire` is
what covers that, and `examples/recrtc/src/recrtc.ml` calls it for both tracks
on every datagram of the session (the conference has no jitter buffer at all:
a forwarder preserves the ordering it was given, offset, and leaves the
reordering to the attendee, which has to do it anyway) — video's gaps are therefore also aired by audio's
packets.

**Matroska lengths of all ones are reserved.** A variable-width integer whose
value bits are all ones means "unknown", so each width holds one less than it
looks: 126 fits in one byte and 127 needs two. Getting this wrong writes a file
that parses right up until it doesn't.

**Log levels.** `Dream.sub_log` keeps the threshold in force when it was
created, and the `log` value here is created at module initialisation, before
`main` runs. `Dream.initialize_log ~level` alone will not make its `debug`
calls appear; ``Dream.set_log_level "recrtc" `Debug`` is also needed.

**Secure context.** `getUserMedia` needs one. `http://localhost:8080` qualifies;
reaching the same server over a LAN address does not, and the Record button
fails there. Recording from another machine needs HTTPS in front.

**Muxing is ours on purpose, in both containers.** `ocaml-ogg` cannot do it —
`Ogg.Stream.packet` is abstract with no constructor — and `ocaml-opus` only
encodes from PCM. Routing through them, or through anything that wants raw
samples, would mean decoding and re-encoding what the browser already encoded.
`lib/oggopus` and `lib/matroska` write bytes directly so packets and frames are
stored bit-exact. Do not reintroduce those dependencies for this.

**Granule positions come from RTP timestamps**, not from accumulating packet
durations: both count 48 kHz samples, so a lost packet leaves a gap of the
right length instead of pulling everything after it earlier. `Rtp.Timeline`
holds the wrap handling both containers need.

**A Matroska recording that is killed still plays.** Lengths not known when an
element opens — the segment, each cluster — are written as the eight-byte
"unknown" form and patched in place on close. Keep it that way: it is why a
`kill -9` mid-recording leaves a file that decodes to its last cluster, missing
only its duration. Worth re-checking after touching `lib/matroska/writer.ml`.

## Conventions

- Formatted in ocamlformat's default style, but there is no `.ocamlformat`, so
  `dune build @fmt` touches only `dune` files. Match the surrounding style by
  hand; do not add a `.ocamlformat` unless asked.
- Comments explain *why*, and are worth spending words on where a protocol
  requires something non-obvious; cite the RFC and section when doing so.
- Every module under `lib/` has an `.mli`, which is where its documentation
  lives; the `.ml` keeps only the comments about how something is done.
  `srtp.mli` ends with a "Primitives" section exposed for the published test
  vectors — the rest of that library's internals, the rollover counter and
  replay window among them, are reached through `unprotect` alone.
- A library whose name matches one of its modules makes that module the only
  entry point, which is why `lib/ice` has `agent.ml` and `stun.ml` and no
  `ice.ml`.
- Every library under `lib/` is public, `(public_name webrtc.<name>)`, so a new
  one needs that line too and its modules are part of the installed API: an
  `.mli` there is documentation that ships.
- Commit messages: a short capitalized sentence ending with a period, then a
  body explaining the reasoning, wrapped at 72 columns.
- Untracked `*~` files are Emacs backups — leave them alone.
