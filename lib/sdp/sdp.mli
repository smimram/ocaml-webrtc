(** Minimal SDP support for a WebRTC endpoint.

    We only ever deal with the shape of session a browser produces, so the
    parser is deliberately partial: it looks for the attributes we need and
    ignores everything else. *)

type direction = Sendrecv | Sendonly | Recvonly | Inactive

val string_of_direction : direction -> string

(** A codec as described by [a=rtpmap] and its optional [a=fmtp]. The name is
    kept as the offer spelled it — encoding names are case-insensitive, and an
    answer that respells one is asking for trouble. *)
type codec = {
  payload_type : int;
  name : string;
  clock_rate : int;
  channels : int;
  fmtp : string option;
  pli : bool;  (** whether [a=rtcp-fb] offered picture loss indication *)
}

(** One media section of the offer. [codec] is what we chose to receive on it,
    or [None] for a section we have nothing to offer — a second camera, a data
    channel, a codec we do not implement. The answer must still contain a
    matching section, so the [m=] line is kept to be echoed back with a port of
    zero. *)
type media = {
  mid : string;
  kind : string;  (** ["audio"], ["video"], or whatever else was offered *)
  line : string;  (** the [m=] line's value, as it was written *)
  codec : codec option;
  codecs : codec list;
      (** every format the section offered that we could read, which is what a
          forwarder searches when it has to answer with a codec of someone
          else's choosing rather than one of its own *)
  ssrcs : int32 list;
      (** the sources of [a=ssrc], in the order they were declared. Two tracks
          of one kind share a transport and a payload type under BUNDLE, and
          this is the only thing in the offer that tells their packets
          apart. *)
  direction : direction;
}

(** Everything we need out of an offer. Session-level [a=ice-ufrag] and friends
    are folded into the media descriptions, media level winning, and taken from
    the first section: under BUNDLE every section agrees on them. *)
type offer = {
  media : media list;  (** in the offer's own order, which the answer keeps *)
  ice_ufrag : string;
  ice_pwd : string;
  fingerprint : string * string;  (** algorithm, colon-separated hex *)
  setup : string;
  rtcp_mux : bool;
}

val matching : codec -> codec list -> codec option
(** The description among [codecs] that names the same stream as the given
    one: the encoding and the clock, compared case-insensitively because
    browsers write ["opus"] but ["VP8"], and for H.264 the packetization mode
    and the profile as well. It is how a forwarder makes one peer send what
    another peer can decode, since it cannot change either. *)

val codec : offer -> string -> codec option
(** What we chose to receive for a kind of media, ["audio"] or ["video"]. *)

exception Invalid of string

val parse_offer : string -> offer
(** @raise Invalid
      if the offer is malformed, or proposes nothing we can receive: Opus for
      audio, VP8, VP9 or H.264 for video. *)

(** What we send on a section: the source its packets carry, the name that
    stays put when the source does not, and the stream and track of [a=msid].
    Two tracks given the same [stream] are ones a peer should play in step. *)
type sending = { ssrc : int32; cname : string; stream : string; track : string }

val answer :
  offer:offer ->
  ?media:media list ->
  ?sending:(media -> sending option) ->
  addresses:string list ->
  port:int ->
  ice_ufrag:string ->
  ice_pwd:string ->
  fingerprint:string * string ->
  unit ->
  string
(** The answer to an offer: an ICE-lite, DTLS-passive endpoint reachable at
    [port] on each of [addresses], most preferred first, with one section per
    section of the offer and every accepted one bundled onto the same
    transport.

    [media] replaces the sections the offer was parsed into, which is how a
    codec other than the one {!parse_offer} would have chosen is answered
    with; it must describe the same sections, in the same order. [sending]
    says what we send on a section, if anything: one it answers for is
    [a=sendonly], and one it does not is [a=recvonly], which is the default
    for every section.

    Several addresses are worth offering because a peer pairs its own
    candidates with ours by route: a browser on the same machine as the server
    has no loopback candidate of its own to pair with a loopback one of ours.

    @raise Invalid_argument if [addresses] is empty. *)
