(** Whole video frames, out of the packets they were cut into.

    A frame is the run of packets sharing an RTP timestamp, ended by the marker
    bit (RFC 3550 §5.1). What each packet contributes depends on the payload
    format, which is why the codec is fixed when the reassembler is created.

    A frame missing a packet is dropped rather than written out: unlike an
    audio gap, a partial picture is not a shorter picture but a corrupt one,
    and it would corrupt every frame predicted from it as well. *)

type codec = Vp8 | Vp9 | H264

type frame = {
  timestamp : int32;
  keyframe : bool;  (** decodable without any frame before it *)
  data : string;
      (** ready for a container: the VP8 or VP9 payloads concatenated, or the
          H.264 units each behind its four-byte length *)
}

type t

val starts_keyframe : codec -> string -> bool
(** Whether a payload is a point at which a receiver joining now can begin: the
    first packet of a picture that depends on nothing before it. What a
    forwarder holds a newcomer back until, and what a recorder's first frame
    is.

    For H.264 the point is the sequence parameter set a browser sends
    immediately before such a picture, not the picture itself, which without
    the parameter sets a decoder cannot configure itself for. *)

val create : codec -> t

val push : t -> Packet.t -> frame list
(** The frames a packet completes: none, or the one it ends. Packets must be
    given in sequence order, as {!Reorder} hands them out; a gap in the
    numbering discards the frame it falls in. *)

val flush : t -> frame list
(** For the end of a stream. Empty in practice, since a frame is only ever
    emitted complete, but it keeps the shape of the other buffers. *)

val dimensions : t -> (int * int) option
(** The picture size, once a keyframe or a parameter set has declared it. *)

val parameter_sets : t -> (string * string) option
(** For H.264, the first sequence and picture parameter sets seen, which a
    container stores out of band. Always [None] for VP8 and VP9, which need
    none. *)

val dropped : t -> int
(** How many frames were discarded for arriving incomplete. *)
