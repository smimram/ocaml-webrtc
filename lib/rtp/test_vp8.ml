(** The VP8 payload descriptor and the keyframe header it hides. *)

open Testlib

(* An RTP packet around a VP8 payload, for driving the reassembler. *)
let packet ~sequence ~timestamp ~marker payload =
  let header = Bytes.create 12 in
  Bytes.set_uint8 header 0 0x80;
  Bytes.set_uint8 header 1 (if marker then 0x80 lor 96 else 96);
  Bytes.set_uint16_be header 2 sequence;
  Bytes.set_int32_be header 4 timestamp;
  Bytes.set_int32_be header 8 0x11223344l;
  Rtp.Packet.parse (Bytes.unsafe_to_string header ^ payload)

(* A keyframe's uncompressed header: the three-byte tag with the frame-type bit
   clear, the start code, then 640x480 (RFC 6386 §9.1). *)
let keyframe_header = hex "9d012a"
let keyframe = hex "1002009d012a8002e001010203"
let interframe = hex "3102000405"

let run () =
  suite "vp8";

  check "a descriptor with nothing extended" (Rtp.Vp8.descriptor_length (hex "10") = 1);
  (* X set, then a byte saying which fields follow. *)
  check "a one-byte picture identifier"
    (Rtp.Vp8.descriptor_length (hex "90800F") = 3);
  check "a two-byte picture identifier"
    (Rtp.Vp8.descriptor_length (hex "9080800F") = 4);
  check "a temporal-layer index alone"
    (Rtp.Vp8.descriptor_length (hex "902001") = 3);
  check "every optional field at once"
    (* picture identifier (two bytes), TL0PICIDX, then TID and KEYIDX sharing
       a byte. *)
    (Rtp.Vp8.descriptor_length (hex "90F08001" ^ hex "07" ^ hex "41") = 6);
  check "a truncated descriptor is rejected"
    (match Rtp.Vp8.descriptor_length (hex "90F080") with
     | exception Rtp.Vp8.Invalid _ -> true
     | _ -> false);
  check_string "the partition is what follows the descriptor"
    ~expected:(hex "AABBCC")
    (Rtp.Vp8.partition (hex "90800F" ^ hex "AABBCC"));

  check "S set with partition 0 starts a frame" (Rtp.Vp8.starts_frame (hex "10"));
  check "S set on a later partition does not"
    (not (Rtp.Vp8.starts_frame (hex "11")));
  check "a continuation does not" (not (Rtp.Vp8.starts_frame (hex "00")));

  check "a keyframe is recognised" (Rtp.Vp8.keyframe keyframe);
  check "an interframe is not" (not (Rtp.Vp8.keyframe interframe));
  check "the start code is where it should be"
    (String.sub keyframe 3 3 = keyframe_header);
  check "the dimensions come out of the keyframe"
    (Rtp.Vp8.dimensions keyframe = Some (640, 480));
  check "an interframe declares none" (Rtp.Vp8.dimensions interframe = None);

  (* Where a forwarder may let a newcomer in: the first packet of a keyframe,
     and nothing else. *)
  check "a keyframe's first packet is a place to join"
    (Rtp.Frame.starts_keyframe Rtp.Frame.Vp8 (hex "10" ^ keyframe));
  check "its later packets are not"
    (not (Rtp.Frame.starts_keyframe Rtp.Frame.Vp8 (hex "00" ^ keyframe)));
  check "nor is an interframe"
    (not (Rtp.Frame.starts_keyframe Rtp.Frame.Vp8 (hex "10" ^ interframe)));
  check "nor is a payload cut short inside its descriptor"
    (not (Rtp.Frame.starts_keyframe Rtp.Frame.Vp8 (hex "90")));

  suite "vp8 frames";
  let t = Rtp.Frame.create Rtp.Frame.Vp8 in
  let push ~sequence ~timestamp ~marker payload =
    Rtp.Frame.push t (packet ~sequence ~timestamp ~marker payload)
  in
  (* One picture across two packets: the descriptors are dropped and the
     partitions joined. *)
  check "the first half is held back"
    (push ~sequence:1 ~timestamp:0l ~marker:false (hex "10" ^ keyframe) = []);
  (match
     push ~sequence:2 ~timestamp:0l ~marker:true (hex "00" ^ hex "DDEEFF")
   with
  | [ frame ] ->
      check "the marker completes the picture" true;
      check "it is a keyframe" frame.keyframe;
      check_string "the partitions are joined"
        ~expected:(keyframe ^ hex "DDEEFF") frame.data
  | _ -> check "the marker completes the picture" false);
  check "the size is remembered" (Rtp.Frame.dimensions t = Some (640, 480));
  check "VP8 needs no parameter sets" (Rtp.Frame.parameter_sets t = None);

  (* A lost packet makes the picture undecodable, so it is dropped whole. *)
  check "a picture with a hole starts"
    (push ~sequence:3 ~timestamp:3000l ~marker:false (hex "10" ^ interframe) = []);
  check "and is not emitted"
    (push ~sequence:5 ~timestamp:3000l ~marker:true (hex "00" ^ hex "99") = []);
  check "the loss is counted" (Rtp.Frame.dropped t = 1);

  (* Joining a picture partway through is the same kind of loss. *)
  check "a picture joined in the middle is dropped"
    (push ~sequence:6 ~timestamp:6000l ~marker:true (hex "00" ^ hex "99") = []);
  check "and counted too" (Rtp.Frame.dropped t = 2)
