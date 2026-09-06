type t = string

let version = 2
let sr = 200
let rr = 201
let sdes = 202
let psfb = 206
let pli_format = 1

(* A length field counts 32-bit words after the first, which is the header
   itself (RFC 3550 §6.4.1). *)
let header_words length = (length / 4) - 1

let pli ~sender ~media =
  let packet = Bytes.create 12 in
  Bytes.set_uint8 packet 0 ((version lsl 6) lor pli_format);
  Bytes.set_uint8 packet 1 psfb;
  Bytes.set_uint16_be packet 2 (header_words (Bytes.length packet));
  Bytes.set_int32_be packet 4 sender;
  Bytes.set_int32_be packet 8 media;
  Bytes.unsafe_to_string packet

(** The NTP time of a moment, in the fixed-point form RFC 3550 §4 wants: the
    seconds since 1900 in the high 32 bits and the fraction in the low. *)
let ntp_of_time seconds =
  let epoch = 2208988800. (* 1900 to 1970 *) in
  let seconds = seconds +. epoch in
  let whole = Int64.of_float seconds in
  let fraction = Int64.of_float ((seconds -. Int64.to_float whole) *. 4294967296.) in
  Int64.logor (Int64.shift_left whole 32) fraction

(* What a report echoes back is the middle of the timestamp, not the whole of
   it: the low half of the seconds and the high half of the fraction, which
   between them cover the range and the resolution a round trip needs. *)
let compact_ntp ntp =
  Int64.to_int32 (Int64.logand (Int64.shift_right_logical ntp 16) 0xffffffffL)

let sender_report ~sender ~ntp ~timestamp ~packets ~octets =
  let packet = Bytes.create 28 in
  Bytes.set_uint8 packet 0 (version lsl 6 (* no report blocks of our own *));
  Bytes.set_uint8 packet 1 sr;
  Bytes.set_uint16_be packet 2 (header_words (Bytes.length packet));
  Bytes.set_int32_be packet 4 sender;
  Bytes.set_int64_be packet 8 ntp;
  Bytes.set_int32_be packet 16 timestamp;
  Bytes.set_int32_be packet 20 packets;
  Bytes.set_int32_be packet 24 octets;
  Bytes.unsafe_to_string packet

type report = {
  source : int32;
  fraction_lost : int;
  cumulative_lost : int;
  extended_highest : int32;
  jitter : int32;
  last_sr : int32;
  delay_since_last_sr : int32;
}

let report_block report =
  let block = Bytes.create 24 in
  Bytes.set_int32_be block 0 report.source;
  (* The fraction and the cumulative count share a word: one octet and three
     (RFC 3550 §6.4.1). The count is signed, duplicates being able to make more
     packets arrive than were expected. *)
  Bytes.set_uint8 block 4 (report.fraction_lost land 0xff);
  Bytes.set_uint8 block 5 ((report.cumulative_lost lsr 16) land 0xff);
  Bytes.set_uint8 block 6 ((report.cumulative_lost lsr 8) land 0xff);
  Bytes.set_uint8 block 7 (report.cumulative_lost land 0xff);
  Bytes.set_int32_be block 8 report.extended_highest;
  Bytes.set_int32_be block 12 report.jitter;
  Bytes.set_int32_be block 16 report.last_sr;
  Bytes.set_int32_be block 20 report.delay_since_last_sr;
  Bytes.unsafe_to_string block

let receiver_report ~sender reports =
  let blocks = String.concat "" (List.map report_block reports) in
  let header = Bytes.create 8 in
  (* The count occupies five bits, which is more room than the two sources a
     session here ever has. *)
  Bytes.set_uint8 header 0 ((version lsl 6) lor List.length reports);
  Bytes.set_uint8 header 1 rr;
  Bytes.set_uint16_be header 2 (header_words (8 + String.length blocks));
  Bytes.set_int32_be header 4 sender;
  Bytes.unsafe_to_string header ^ blocks

let source_description ~sender ~cname =
  let cname =
    if String.length cname > 255 then String.sub cname 0 255 else cname
  in
  let item = "\001" ^ String.make 1 (Char.chr (String.length cname)) ^ cname in
  (* The item list ends in a null octet, and the chunk is then padded to a
     32-bit boundary with more of them (RFC 3550 §6.5). *)
  let unpadded = 4 + String.length item + 1 in
  let padding = (4 - (unpadded mod 4)) mod 4 in
  let chunk = Bytes.create (unpadded + padding) in
  Bytes.fill chunk 0 (Bytes.length chunk) '\000';
  Bytes.set_int32_be chunk 0 sender;
  Bytes.blit_string item 0 chunk 4 (String.length item);
  let header = Bytes.create 4 in
  Bytes.set_uint8 header 0 ((version lsl 6) lor 1 (* one chunk *));
  Bytes.set_uint8 header 1 sdes;
  Bytes.set_uint16_be header 2 (header_words (4 + Bytes.length chunk));
  Bytes.unsafe_to_string header ^ Bytes.unsafe_to_string chunk

let compound packets = String.concat "" packets

(* Walking a compound packet: each one carries its own length, and anything
   unrecognised is stepped over rather than stopping the walk. *)
let rec fold_packets f acc packet offset =
  if offset + 4 > String.length packet then acc
  else
    let length = 4 * (String.get_uint16_be packet (offset + 2) + 1) in
    if length < 4 || offset + length > String.length packet then acc
    else
      let acc =
        f acc ~payload_type:(Char.code packet.[offset + 1]) ~offset ~length
      in
      fold_packets f acc packet (offset + length)

type sender_info = {
  sender : int32;
  ntp : int64;
  rtp_timestamp : int32;
  packets : int32;
  octets : int32;
}

let sender_reports packet =
  List.rev
    (fold_packets
       (fun acc ~payload_type ~offset ~length ->
         if payload_type = sr && length >= 28 then
           {
             sender = String.get_int32_be packet (offset + 4);
             ntp = String.get_int64_be packet (offset + 8);
             rtp_timestamp = String.get_int32_be packet (offset + 16);
             packets = String.get_int32_be packet (offset + 20);
             octets = String.get_int32_be packet (offset + 24);
           }
           :: acc
         else acc)
       [] packet 0)

(* Of the feedback a peer sends us only the picture loss indication is acted
   on. A full intra request (§4.3.1 of RFC 5104) would mean the same thing, but
   browsers send the first. *)
let keyframe_requests packet =
  List.rev
    (fold_packets
       (fun acc ~payload_type ~offset ~length ->
         if
           payload_type = psfb && length >= 12
           && Char.code packet.[offset] land 0x1f = pli_format
         then String.get_int32_be packet (offset + 8) :: acc
         else acc)
       [] packet 0)
