(** The VP9 payload descriptor and the uncompressed header it hides. *)

open Testlib

(* An RTP packet around a VP9 payload, for driving the reassembler. *)
let packet ~sequence ~timestamp ~marker payload =
  let header = Bytes.create 12 in
  Bytes.set_uint8 header 0 0x80;
  Bytes.set_uint8 header 1 (if marker then 0x80 lor 98 else 98);
  Bytes.set_uint16_be header 2 sequence;
  Bytes.set_int32_be header 4 timestamp;
  Bytes.set_int32_be header 8 0x11223344l;
  Rtp.Packet.parse (Bytes.unsafe_to_string header ^ payload)

(* An uncompressed header declaring a 640x480 keyframe: the frame marker and
   profile 0, the sync code, a colour space of BT.709 with the narrow range,
   then the size less one in each direction (VP9 §6.2). *)
let keyframe = hex "824983424027F01DF0"

(* The same, with the frame-type bit set and nothing after it to read. *)
let interframe = hex "86"

let run () =
  suite "vp9";

  check "a descriptor with nothing extended" (Rtp.Vp9.descriptor_length (hex "08") = 1);
  check "a one-byte picture identifier"
    (Rtp.Vp9.descriptor_length (hex "880F") = 2);
  check "a two-byte picture identifier"
    (Rtp.Vp9.descriptor_length (hex "88800F") = 3);
  check "layer indices carry TL0PICIDX in non-flexible mode"
    (Rtp.Vp9.descriptor_length (hex "28000A") = 3);
  check "and not in flexible mode" (Rtp.Vp9.descriptor_length (hex "3800") = 2);
  check "what Chrome sends: a long picture identifier and layer indices"
    (Rtp.Vp9.descriptor_length (hex "A8801F000A") = 5);
  check "reference differences run while the low bit is set"
    (* P and F together, then a difference continuing into a second. *)
    (Rtp.Vp9.descriptor_length (hex "58" ^ hex "03" ^ hex "02") = 3);
  check "a scalability structure with one resolution"
    (* One spatial layer, its width and height, no picture group. *)
    (Rtp.Vp9.descriptor_length (hex "0A" ^ hex "10" ^ hex "028001E0") = 6);
  check "and one with a picture group"
    (Rtp.Vp9.descriptor_length
       (hex "0A" ^ hex "18" ^ hex "028001E0" ^ hex "01" ^ hex "04" ^ hex "01")
     = 9);
  check "a truncated descriptor is rejected"
    (match Rtp.Vp9.descriptor_length (hex "88") with
     | exception Rtp.Vp9.Invalid _ -> true
     | _ -> false);
  check_string "the payload is what follows the descriptor"
    ~expected:(hex "AABBCC")
    (Rtp.Vp9.payload (hex "880F" ^ hex "AABBCC"));

  check "B set starts a frame" (Rtp.Vp9.starts_frame (hex "08"));
  check "a continuation does not" (not (Rtp.Vp9.starts_frame (hex "00")));

  check "a keyframe is recognised" (Rtp.Vp9.keyframe keyframe);
  check "an interframe is not" (not (Rtp.Vp9.keyframe interframe));
  check "the dimensions come out of the keyframe"
    (Rtp.Vp9.dimensions keyframe = Some (640, 480));
  check "an interframe declares none" (Rtp.Vp9.dimensions interframe = None);
  check "so does something that is not VP9 at all"
    (Rtp.Vp9.dimensions (hex "00000000") = None);

  check "a keyframe's first packet is a place to join"
    (Rtp.Frame.starts_keyframe Rtp.Frame.Vp9 (hex "08" ^ keyframe));
  check "its later packets are not"
    (not (Rtp.Frame.starts_keyframe Rtp.Frame.Vp9 (hex "00" ^ keyframe)));
  check "nor is an interframe"
    (not (Rtp.Frame.starts_keyframe Rtp.Frame.Vp9 (hex "08" ^ interframe)));

  suite "vp9 frames";
  let t = Rtp.Frame.create Rtp.Frame.Vp9 in
  let push ~sequence ~timestamp ~marker payload =
    Rtp.Frame.push t (packet ~sequence ~timestamp ~marker payload)
  in
  (* One picture across two packets: the descriptors are dropped and what they
     precede joined. *)
  check "the first half is held back"
    (push ~sequence:1 ~timestamp:0l ~marker:false (hex "08" ^ keyframe) = []);
  (match
     push ~sequence:2 ~timestamp:0l ~marker:true (hex "04" ^ hex "DDEEFF")
   with
  | [ frame ] ->
      check "the marker completes the picture" true;
      check "it is a keyframe" frame.keyframe;
      check_string "the payloads are joined" ~expected:(keyframe ^ hex "DDEEFF")
        frame.data
  | _ -> check "the marker completes the picture" false);
  check "the size is remembered" (Rtp.Frame.dimensions t = Some (640, 480));
  check "VP9 needs no parameter sets" (Rtp.Frame.parameter_sets t = None);

  (* A lost packet makes the picture undecodable, so it is dropped whole. *)
  check "a picture with a hole starts"
    (push ~sequence:3 ~timestamp:3000l ~marker:false (hex "08" ^ interframe) = []);
  check "and is not emitted"
    (push ~sequence:5 ~timestamp:3000l ~marker:true (hex "00" ^ hex "99") = []);
  check "the loss is counted" (Rtp.Frame.dropped t = 1);

  (* Joining a picture partway through is the same kind of loss. *)
  check "a picture joined in the middle is dropped"
    (push ~sequence:6 ~timestamp:6000l ~marker:true (hex "00" ^ hex "99") = []);
  check "and counted too" (Rtp.Frame.dropped t = 2)
