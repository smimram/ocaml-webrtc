(** The H.264 payload format, and the picture size buried in a parameter set. *)

open Testlib

(* Parameter sets as x264 writes them. The first is baseline, 640x360, whose
   height needs cropping to a multiple of a macroblock; the second is high,
   1280x714, which carries the chroma syntax as well. Both contain the
   emulation-prevention bytes that have to come out before the bits are read. *)
let baseline_sps = hex "6742c016d900a02ff97011000003000100000300140f162e48"
let baseline_pps = hex "68cb83cb20"
let high_sps = hex "6764001facd9405005bf93011000000300100000030140f1831960"

let packet ~sequence ~timestamp ~marker payload =
  let header = Bytes.create 12 in
  Bytes.set_uint8 header 0 0x80;
  Bytes.set_uint8 header 1 (if marker then 0x80 lor 102 else 102);
  Bytes.set_uint16_be header 2 sequence;
  Bytes.set_int32_be header 4 timestamp;
  Bytes.set_int32_be header 8 0x11223344l;
  Rtp.Packet.parse (Bytes.unsafe_to_string header ^ payload)

let uint16 n = String.init 2 (fun i -> Char.chr ((n lsr (8 * (1 - i))) land 0xff))

let run () =
  suite "h264 parameter sets";

  check "the baseline picture size, cropped to 640x360"
    (Rtp.H264.dimensions baseline_sps = Some (640, 360));
  check "the high-profile picture size, cropped to 1280x714"
    (Rtp.H264.dimensions high_sps = Some (1280, 714));
  check "rubbish is refused" (Rtp.H264.dimensions (hex "6700") = None);

  let avcc = Rtp.H264.avcc ~sps:baseline_sps ~pps:baseline_pps in
  check "the record opens with its version" (avcc.[0] = '\x01');
  check_string "then the profile, its flags and the level"
    ~expected:(String.sub baseline_sps 1 3)
    (String.sub avcc 1 3);
  check "lengths are four bytes" (avcc.[4] = '\xff');
  check "one sequence parameter set" (avcc.[5] = '\xe1');
  check_string "which follows its length"
    ~expected:(uint16 (String.length baseline_sps) ^ baseline_sps)
    (String.sub avcc 6 (2 + String.length baseline_sps));
  let after = 6 + 2 + String.length baseline_sps in
  check "one picture parameter set" (avcc.[after] = '\x01');
  check_string "which follows its length too"
    ~expected:(uint16 (String.length baseline_pps) ^ baseline_pps)
    (String.sub avcc (after + 1) (2 + String.length baseline_pps));

  suite "h264 depacketising";

  let t = Rtp.H264.create () in
  (* A unit small enough for a datagram is the packet, whole. *)
  check "a single unit passes through"
    (Rtp.H264.push t baseline_pps = [ baseline_pps ]);
  (* An aggregation packet is the indicator, then each unit behind its
     length (RFC 6184 §5.7.1); 24 is its type, and the indicator's reference
     bits are the highest of what it carries. *)
  let stap_a =
    hex "78"
    ^ uint16 (String.length baseline_sps)
    ^ baseline_sps
    ^ uint16 (String.length baseline_pps)
    ^ baseline_pps
  in
  check "an aggregation packet is split"
    (Rtp.H264.push t stap_a = [ baseline_sps; baseline_pps ]);

  (* A unit too large for a datagram arrives in fragments, whose first and
     last are flagged; the unit's own header is rebuilt from the two bytes the
     format puts in its place (RFC 6184 §5.8). *)
  let body = String.sub baseline_sps 1 (String.length baseline_sps - 1) in
  let third = String.length body / 3 in
  let fragment flags data = hex "7c" ^ String.make 1 (Char.chr flags) ^ data in
  check "a fragment on its own completes nothing"
    (Rtp.H264.push t (fragment 0x87 (String.sub body 0 third)) = []);
  check "nor does the middle"
    (Rtp.H264.push t
       (fragment 0x07 (String.sub body third (String.length body - third - 1)))
     = []);
  check "the last one rebuilds the unit"
    (Rtp.H264.push t
       (fragment 0x47 (String.sub body (String.length body - 1) 1))
     = [ baseline_sps ]);
  (* A fragment joined after its start cannot be completed. *)
  Rtp.H264.reset t;
  check "a fragment joined in the middle is refused"
    (Rtp.H264.push t (fragment 0x07 body) = []);
  check "and so is its end" (Rtp.H264.push t (fragment 0x47 body) = []);

  check "a unit knows its type" (Rtp.H264.nal_type baseline_sps = 7);
  check "and so does a picture parameter set"
    (Rtp.H264.nal_type baseline_pps = 8);
  check "a fragmented unit starts where it says"
    (Rtp.H264.starts_unit (fragment 0x87 body));
  check "and continues where it says"
    (not (Rtp.H264.starts_unit (fragment 0x07 body)));
  check "an aggregation packet always starts one"
    (Rtp.H264.starts_unit stap_a);

  check "a single unit is the type it carries"
    (Rtp.H264.payload_nal_types baseline_pps = [ 8 ]);
  check "an aggregation packet is all of them"
    (Rtp.H264.payload_nal_types stap_a = [ 7; 8 ]);
  check "a fragment says what it starts"
    (Rtp.H264.payload_nal_types (fragment 0x87 body) = [ 7 ]);
  check "and one joined in the middle says nothing"
    (Rtp.H264.payload_nal_types (fragment 0x07 body) = []);

  (* A decoder joining at an IDR without the parameter sets has nothing to
     configure itself from, so the place to join is where they are. *)
  check "the parameter sets are where a newcomer joins"
    (Rtp.Frame.starts_keyframe Rtp.Frame.H264 stap_a);
  check "and a picture on its own is not"
    (not (Rtp.Frame.starts_keyframe Rtp.Frame.H264 (hex "65AABBCC")));

  suite "h264 frames";

  let t = Rtp.Frame.create Rtp.Frame.H264 in
  (* A browser sends the parameter sets and the picture that needs them
     together, under one timestamp. *)
  let idr = hex "65" ^ hex "88840021" in
  (* Bound in order: OCaml evaluates the operands of [@] right to left, and
     these two must reach the reassembler the way they reached the wire. *)
  let first =
    Rtp.Frame.push t (packet ~sequence:1 ~timestamp:0l ~marker:false stap_a)
  in
  let second =
    Rtp.Frame.push t (packet ~sequence:2 ~timestamp:0l ~marker:true idr)
  in
  let frames = first @ second in
  (match frames with
  | [ frame ] ->
      check "the picture is emitted whole" true;
      check "it is a keyframe" frame.keyframe;
      check_string "with every unit behind its length"
        ~expected:
          (Rtp.H264.length_prefixed baseline_sps
          ^ Rtp.H264.length_prefixed baseline_pps
          ^ Rtp.H264.length_prefixed idr)
        frame.data
  | _ -> check "the picture is emitted whole" false);
  check "the parameter sets were kept"
    (Rtp.Frame.parameter_sets t = Some (baseline_sps, baseline_pps));
  check "and the size read out of them"
    (Rtp.Frame.dimensions t = Some (640, 360))
