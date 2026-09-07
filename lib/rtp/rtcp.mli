(** The RTCP this stack builds, and the little of it that it reads.

    A receiver has two things to say back. A picture loss indication, because
    after a lost packet every picture predicted from the one it ruined is
    unusable and a browser sends a fresh keyframe only when asked. And a
    receiver report, because a sender that hears nothing about what arrived has
    nothing to size its bitrate against.

    A sender has one: a sender report, which is what ties its stream's clock to
    the wall clock, and so the only thing that lets a peer play two streams of
    ours — a camera and the microphone that goes with it — in step. *)

type t = string

val pli : sender:int32 -> media:int32 -> t
(** A picture loss indication (RFC 4585 §6.3.1): a payload-specific feedback
    packet naming the source whose stream is unreadable. [sender] is our own
    synchronisation source, which a browser does not otherwise know and does
    not check; [media] is the source of the pictures being asked for. *)

val ntp_of_time : float -> int64
(** A Unix time as the fixed-point NTP timestamp a sender report carries (RFC
    3550 §4): seconds since 1900 above the point, and the fraction below. *)

val compact_ntp : int64 -> int32
(** The middle 32 bits of such a timestamp, which is the form a report echoes
    back and {!report}'s [last_sr] holds. *)

val sender_report :
  sender:int32 ->
  ntp:int64 ->
  timestamp:int32 ->
  packets:int32 ->
  octets:int32 ->
  t
(** A sender report (RFC 3550 §6.4.1): what our stream's clock reads at a
    moment of the wall clock, and how much has been sent since it began. The
    pairing of the two timestamps is the point of it — a peer receiving two of
    our streams has nothing else to align them by. No reception blocks are
    included: a forwarder reports on what it receives to the peer it receives
    it from, not to the peers it sends it to.

    [packets] and [octets] count what has been sent under [sender] since it
    started, the octets excluding every header. *)

(** One source's reception statistics (RFC 3550 §6.4.1). [cumulative_lost] is
    signed and occupies three octets; [fraction_lost] is the loss since the
    last report, as a fraction of 256. [last_sr] and [delay_since_last_sr] are
    what let the sender work out the round trip: the middle 32 bits of the NTP
    timestamp of the last sender report we saw, and how long ago we saw it, in
    units of 1/65536 of a second. Both are zero until a sender report has
    arrived. *)
type report = {
  source : int32;
  fraction_lost : int;
  cumulative_lost : int;
  extended_highest : int32;
  jitter : int32;
  last_sr : int32;
  delay_since_last_sr : int32;
}

val receiver_report : sender:int32 -> report list -> t
(** A receiver report (RFC 3550 §6.4.2): one block for each source we are
    receiving, under our own synchronisation source. *)

val source_description : sender:int32 -> cname:string -> t
(** The CNAME chunk (RFC 3550 §6.5) that must accompany a report: the
    persistent name of the endpoint sending it, as against the synchronisation
    source, which may change. *)

val compound : t list -> t
(** Packets sent as one datagram, which is how RTCP travels unless reduced-size
    RTCP was negotiated, which we do not negotiate (RFC 3550 §6.1). *)

(** What a sender report says about its source. *)
type sender_info = {
  sender : int32;
  ntp : int64;  (** the wall clock, when the report was sent *)
  rtp_timestamp : int32;  (** the stream's own clock, at that same moment *)
  packets : int32;
  octets : int32;
}

val sender_reports : string -> sender_info list
(** Every sender report in a compound packet. A receiver echoes the timestamp
    back so that the sender can measure a round trip; a forwarder also keeps
    the pairing of the two clocks, which is what it has to reproduce in reports
    of its own for the streams to stay in step downstream. Anything else in the
    packet is stepped over. *)

val keyframe_requests : string -> int32 list
(** The media sources named by the picture loss indications in a compound
    packet: what a peer we are sending to asks us for when it cannot decode,
    and which a forwarder passes on to the peer it is forwarding from. *)
