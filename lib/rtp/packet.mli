(** RTP packets (RFC 3550 §5.1) and the RTP/RTCP distinction. *)

type t = {
  padding : bool;
  marker : bool;
  payload_type : int;
  sequence : int;
  timestamp : int32;
  ssrc : int32;
  csrc : int32 list;
  extension : (int * string) option;  (** profile identifier and its data *)
  payload : string;
  header_length : int;
      (** the header, its CSRC list and any extension: the offset at which the
          payload, and the part SRTP encrypts, begins *)
}

exception Invalid of string

val parse : string -> t
(** @raise Invalid if the packet is truncated or is not RTP version 2. *)

val encode : t -> string
(** The packet a description stands for, which a forwarder builds by parsing
    one and writing it back out under another source or another numbering.
    {!header_length} is ignored: it describes the packet the value came from.

    @raise Invalid
      if the description cannot be written: more than fifteen contributing
      sources, or an extension that is not a whole number of 32-bit words. *)

val header_length : string -> int
(** How many leading bytes of a packet are header. Separate from {!parse}
    because SRTP must know it before it can decrypt what follows.

    @raise Invalid as {!parse} does. *)

val is_rtcp : string -> bool
(** RTP and RTCP share a port when [a=rtcp-mux] is negotiated; they are told
    apart by their payload type (RFC 5761 §4). *)
